#!/usr/bin/env bash
# =============================================================================
# backup.sh — Automated SSH backup with KeePassXC integration
#
# Supports:
#   - systemd timers (Linux) and launchd (macOS)
#   - Per-target config files (host + directory pairs)
#   - KeePassXC for SSH key password retrieval
#   - rsync (when available on remote) or lftp/sshfs fallback
#   - Deletion of locally removed files
#
# Dependencies: keepassxc-cli, ssh, ssh-agent, rsync or (lftp | sshfs)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── Paths ────────────────────────────────────────────────────────────────────

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONFIG_DIR="${BACKUP_CONFIG_DIR:-$HOME/.config/backup}"
MAIN_CONFIG="$CONFIG_DIR/main.conf"
TARGETS_DIR="$CONFIG_DIR/targets"
LOG_DIR="${BACKUP_LOG_DIR:-$HOME/.local/share/backup/logs}"
LOG_FILE="$LOG_DIR/backup-$(date +%Y-%m-%d).log"

# ─── Runtime state ────────────────────────────────────────────────────────────

MASTER_PASSWORD=""
SSH_AGENT_PID_STARTED=""   # PID of agent we launched (empty = we reused existing)
TEMP_FILES=()              # Temp files to clean up on exit
EXIT_CODE=0

# ─── Colour output (disabled when not a TTY) ──────────────────────────────────

if [ -t 1 ]; then
    C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''
fi

# ─── Logging ──────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"

log()  { local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"; echo -e "${C_CYAN}[${ts}]${C_RESET} $*" | tee -a "$LOG_FILE"; }
info() { log "${C_GREEN}INFO${C_RESET}  $*"; }
warn() { log "${C_YELLOW}WARN${C_RESET}  $*"; }
err()  { log "${C_RED}ERROR${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# ─── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
    local exit_status=$?

    # Remove temp files (e.g. askpass helpers)
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done

    # Kill ssh-agent only if WE started it
    if [[ -n "$SSH_AGENT_PID_STARTED" ]]; then
        ssh-agent -k &>/dev/null || true
    fi

    # Scrub sensitive variable from memory (best-effort in bash)
    MASTER_PASSWORD="$(head -c 256 /dev/urandom | base64)"
    unset MASTER_PASSWORD

    [[ $exit_status -ne 0 ]] && err "Backup exited with status $exit_status"
}
trap cleanup EXIT
trap 'err "Interrupted"; exit 130' INT TERM

# ─── Dependency checks ────────────────────────────────────────────────────────

require_cmd() {
    command -v "$1" &>/dev/null || die "Required command not found: $1"
}

check_dependencies() {
    require_cmd keepassxc-cli
    require_cmd ssh
    require_cmd ssh-agent
    require_cmd ssh-add
    # rsync/lftp/sshfs checked per-target
}

# ─── Config loading ───────────────────────────────────────────────────────────

load_main_config() {
    [[ -f "$MAIN_CONFIG" ]] || die "Main config not found: $MAIN_CONFIG
Run: cp $CONFIG_DIR/main.conf.example $MAIN_CONFIG  and edit it."

    # Validate permissions — config contains sensitive paths
    local perms
    perms="$(stat -c '%a' "$MAIN_CONFIG" 2>/dev/null || stat -f '%p' "$MAIN_CONFIG" 2>/dev/null | tail -c 4)"
    if [[ "$perms" != "600" && "$perms" != "0600" ]]; then
        warn "Config file $MAIN_CONFIG should have permissions 600 (currently $perms)"
    fi

    # shellcheck source=/dev/null
    source "$MAIN_CONFIG"

    # Validate mandatory variables
    [[ -n "${KEEPASS_DB:-}" ]]         || die "KEEPASS_DB not set in $MAIN_CONFIG"
    [[ -f "${KEEPASS_DB}" ]]           || die "KEEPASS_DB file not found: $KEEPASS_DB"
    [[ -n "${LOCAL_BACKUP_ROOT:-}" ]]  || die "LOCAL_BACKUP_ROOT not set in $MAIN_CONFIG"
}

load_target_config() {
    local target_file="$1"

    # Reset per-target variables to defaults
    TARGET_NAME=""
    HOST=""
    PORT="22"
    USER="$(whoami)"
    REMOTE_DIR=""
    LOCAL_DIR=""
    SSH_KEY="${SSH_KEY_DEFAULT:-$HOME/.ssh/id_ed25519}"
    KEEPASS_ENTRY=""
    HAS_RSYNC=""        # "true" | "false" | "" (auto-detect)
    RSYNC_EXTRA_OPTS=""
    LFTP_EXTRA_OPTS=""
    ENABLED="true"
    BANDWIDTH_LIMIT=""  # KB/s, 0 = unlimited

    # shellcheck source=/dev/null
    source "$target_file"

    [[ -n "$TARGET_NAME" ]] || TARGET_NAME="$(basename "$target_file" .conf)"
    [[ -n "$HOST" ]]        || die "[$target_file] HOST is not set"
    [[ -n "$REMOTE_DIR" ]]  || die "[$target_file] REMOTE_DIR is not set"
    [[ -n "$KEEPASS_ENTRY" ]] || die "[$target_file] KEEPASS_ENTRY is not set"

    # Default local dir: $LOCAL_BACKUP_ROOT/<target_name>
    if [[ -z "$LOCAL_DIR" ]]; then
        LOCAL_DIR="$LOCAL_BACKUP_ROOT/$TARGET_NAME"
    fi

    mkdir -p "$LOCAL_DIR"
}

# ─── Master password prompt ───────────────────────────────────────────────────

prompt_master_password() {
    if [[ -n "$MASTER_PASSWORD" ]]; then
        return 0  # Already have it
    fi

    if [[ -t 0 ]]; then
        # Interactive terminal
        printf "${C_BOLD}KeePass master password:${C_RESET} " >&2
        read -rsp "" MASTER_PASSWORD
        printf '\n' >&2
    else
        # Non-interactive (launched by systemd/launchd) → GUI dialog
        info "Non-interactive session detected — opening GUI password prompt"
        if [[ "$OSTYPE" == darwin* ]]; then
            MASTER_PASSWORD="$(osascript \
                -e 'Tell application "System Events"' \
                -e '  activate' \
                -e '  set pw to text returned of (display dialog "Backup — Enter KeePass master password:" with hidden answer default answer "" buttons {"Cancel","OK"} default button "OK" with title "Backup Tool")' \
                -e 'end tell' \
                -e 'return pw')" || die "Password prompt cancelled"
        elif command -v zenity &>/dev/null; then
            MASTER_PASSWORD="$(zenity --password \
                --title="Backup Tool — KeePass" \
                --text="Enter KeePass master password:")" \
                || die "Password prompt cancelled"
        elif command -v kdialog &>/dev/null; then
            MASTER_PASSWORD="$(kdialog \
                --password "Enter KeePass master password:" \
                --title "Backup Tool")" \
                || die "Password prompt cancelled"
        elif command -v ssh-askpass &>/dev/null; then
            MASTER_PASSWORD="$(DISPLAY="${DISPLAY:-:0}" ssh-askpass \
                "Backup: Enter KeePass master password:")" \
                || die "Password prompt cancelled"
        else
            die "No GUI prompt available (zenity/kdialog/ssh-askpass) and stdin is not a TTY.
On Linux install zenity: sudo apt install zenity
Or set MASTER_PASSWORD env variable before launch (less secure)."
        fi
    fi

    [[ -n "$MASTER_PASSWORD" ]] || die "Master password cannot be empty"
}

# ─── KeePassXC integration ────────────────────────────────────────────────────

keepass_get() {
    local entry="$1"
    local attribute="${2:-Password}"
    local value

    value="$(printf '%s\n' "$MASTER_PASSWORD" \
        | keepassxc-cli show -q -a "$attribute" "$KEEPASS_DB" "$entry" 2>/dev/null)" \
        || die "KeePass: could not retrieve '$attribute' for entry '$entry'.
Check that:
  • The master password is correct
  • The entry path is correct: $entry
  • The database path is correct: $KEEPASS_DB"

    [[ -n "$value" ]] || die "KeePass: empty '$attribute' for entry '$entry'"
    printf '%s' "$value"
}

# ─── SSH Agent ────────────────────────────────────────────────────────────────

setup_ssh_agent() {
    # Reuse existing agent if available
    if [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh-add -l &>/dev/null; then
        info "Reusing existing SSH agent ($(ssh-add -l | wc -l | tr -d ' ') key(s) loaded)"
        return 0
    fi

    info "Starting new SSH agent"
    eval "$(ssh-agent -s)" > /dev/null
    SSH_AGENT_PID_STARTED="$SSH_AGENT_PID"
}

add_ssh_key() {
    local key_path="$1"
    local key_password="$2"
    local key_name
    key_name="$(basename "$key_path")"

    # Check if key is already loaded
    if ssh-add -l 2>/dev/null | grep -qF "$key_path"; then
        info "SSH key already in agent: $key_name"
        return 0
    fi

    info "Adding SSH key to agent: $key_name"

    # Create a minimal askpass helper that echoes the key password
    local askpass
    askpass="$(mktemp /tmp/.ssh-askpass.XXXXXX)"
    TEMP_FILES+=("$askpass")
    chmod 700 "$askpass"
    # Write password via printf to avoid shell quoting issues
    printf '#!/bin/sh\nprintf "%%s" "%s"\n' \
        "$(printf '%s' "$key_password" | sed "s/'/'\\\\''/g")" > "$askpass"

    SSH_ASKPASS="$askpass" \
    SSH_ASKPASS_REQUIRE="force" \
    DISPLAY="${DISPLAY:-:0}" \
        ssh-add "$key_path" </dev/null 2>/tmp/ssh-add-err \
        || {
            warn "ssh-add failed for $key_name: $(cat /tmp/ssh-add-err)"
            return 1
        }

    rm -f /tmp/ssh-add-err
    info "Key added: $key_name"
}

# ─── Remote rsync detection ───────────────────────────────────────────────────

remote_has_rsync() {
    local user="$1" host="$2" port="$3"
    ssh -q -o BatchMode=yes -o ConnectTimeout=10 -p "$port" \
        "${user}@${host}" "command -v rsync" &>/dev/null
}

# ─── Backup strategies ────────────────────────────────────────────────────────

build_ssh_opts() {
    local port="$1"
    local opts="-p $port -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=60"
    printf '%s' "$opts"
}

backup_rsync() {
    local user="$1" host="$2" port="$3" remote_dir="$4" local_dir="$5"

    info "[$TARGET_NAME] Using rsync"

    local ssh_opts
    ssh_opts="$(build_ssh_opts "$port")"

    local bwlimit_opt=""
    [[ -n "$BANDWIDTH_LIMIT" && "$BANDWIDTH_LIMIT" != "0" ]] \
        && bwlimit_opt="--bwlimit=$BANDWIDTH_LIMIT"

    # Trailing slash on remote ensures we sync *contents* of dir
    rsync \
        --archive \
        --verbose \
        --compress \
        --human-readable \
        --partial \
        --delete \
        --delete-after \
        --checksum \
        --stats \
        ${bwlimit_opt:+"$bwlimit_opt"} \
        ${RSYNC_EXTRA_OPTS:+$RSYNC_EXTRA_OPTS} \
        -e "ssh $ssh_opts" \
        "${user}@${host}:${remote_dir}/" \
        "${local_dir}/" \
        2>&1 | tee -a "$LOG_FILE"
}

backup_lftp() {
    local user="$1" host="$2" port="$3" remote_dir="$4" local_dir="$5"

    require_cmd lftp
    info "[$TARGET_NAME] Using lftp mirror (no rsync on remote)"

    local bwlimit_cmd=""
    [[ -n "$BANDWIDTH_LIMIT" && "$BANDWIDTH_LIMIT" != "0" ]] \
        && bwlimit_cmd="set net:limit-total-rate $((BANDWIDTH_LIMIT * 1024));"

    # lftp does not forward environment variables to the ssh subprocess it
    # spawns for SFTP, so SSH_AUTH_SOCK is lost and ssh falls back to
    # prompting for the key passphrase. -o IdentityAgent= is also unreliable
    # due to lftp's command-string splitting.
    # Solution: write a minimal wrapper that hard-codes the socket path, so
    # the child ssh process always finds the agent regardless of environment.
    local ssh_wrapper
    ssh_wrapper="$(mktemp /tmp/.lftp-ssh-wrap.XXXXXX)"
    TEMP_FILES+=("$ssh_wrapper")
    chmod 700 "$ssh_wrapper"
    cat > "$ssh_wrapper" <<WRAPPER
#!/bin/sh
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK}"
exec ssh -a -x -p ${port} -o BatchMode=yes -o StrictHostKeyChecking=accept-new "\$@"
WRAPPER
    local sftp_cmd="${ssh_wrapper}"

    local dry_run_flag=""
    $DRY_RUN && dry_run_flag="--dry-run"

    lftp -c "
set sftp:auto-confirm yes;
set sftp:connect-program \"${sftp_cmd}\";
set cmd:interactive no;
set net:max-retries 3;
set net:reconnect-interval-base 5;
set mirror:set-permissions off;
${bwlimit_cmd}
${LFTP_EXTRA_OPTS:+${LFTP_EXTRA_OPTS};}
open sftp://${user}:@${host};
mirror \\
    --only-newer \\
    --delete \\
    --verbose=1 \\
    --parallel=4 \\
    --use-pget-n=4 \\
    ${dry_run_flag} \\
    ${remote_dir} ${local_dir};
quit
" 2>&1 | tee -a "$LOG_FILE"
}

backup_sshfs_rsync() {
    local user="$1" host="$2" port="$3" remote_dir="$4" local_dir="$5"

    require_cmd sshfs
    require_cmd rsync
    info "[$TARGET_NAME] Using sshfs + local rsync (lftp not available)"

    local mount_point
    mount_point="$(mktemp -d /tmp/.backup-mount.XXXXXX)"
    TEMP_FILES+=("$mount_point")

    # Unmount helper (handles both Linux and macOS)
    _umount() {
        if command -v fusermount &>/dev/null; then
            fusermount -uz "$mount_point" 2>/dev/null || true
        else
            umount "$mount_point" 2>/dev/null || true
        fi
        rmdir "$mount_point" 2>/dev/null || true
    }
    trap "_umount; cleanup" EXIT

    local ssh_opts
    ssh_opts="$(build_ssh_opts "$port")"

    sshfs \
        -o BatchMode=yes,reconnect,ServerAliveInterval=60,${ssh_opts// /,} \
        "${user}@${host}:${remote_dir}" "$mount_point"

    rsync \
        --archive \
        --verbose \
        --human-readable \
        --delete \
        --delete-after \
        --checksum \
        --stats \
        "${mount_point}/" \
        "${local_dir}/" \
        2>&1 | tee -a "$LOG_FILE"

    _umount
}

# ─── Run a single target ──────────────────────────────────────────────────────

run_target() {
    local target_file="$1"

    load_target_config "$target_file"

    if [[ "$ENABLED" != "true" ]]; then
        info "[$TARGET_NAME] Skipped (ENABLED=false)"
        return 0
    fi

    info "[$TARGET_NAME] ──── Starting backup ────────────────────────────────"
    info "[$TARGET_NAME] Remote: ${USER}@${HOST}:${PORT}${REMOTE_DIR}"
    info "[$TARGET_NAME] Local:  ${LOCAL_DIR}"

    # Retrieve SSH key password from KeePass
    local key_password
    key_password="$(keepass_get "$KEEPASS_ENTRY")"

    # Load key into agent
    add_ssh_key "$SSH_KEY" "$key_password"
    unset key_password

    # Verify connectivity
    if ! ssh -q -o BatchMode=yes -o ConnectTimeout=15 -p "$PORT" \
             "${USER}@${HOST}" "echo ok" &>/dev/null; then
        err "[$TARGET_NAME] Cannot connect to ${HOST}:${PORT} — skipping"
        EXIT_CODE=1
        return 1
    fi

    # Determine backup strategy
    local use_rsync="$HAS_RSYNC"
    if [[ -z "$use_rsync" ]]; then
        if remote_has_rsync "$USER" "$HOST" "$PORT"; then
            use_rsync="true"
        else
            use_rsync="false"
            warn "[$TARGET_NAME] rsync not found on remote, using fallback"
        fi
    fi

    local start_ts end_ts elapsed
    start_ts=$(date +%s)

    if [[ "$use_rsync" == "true" ]]; then
        backup_rsync "$USER" "$HOST" "$PORT" "$REMOTE_DIR" "$LOCAL_DIR"
    elif command -v lftp &>/dev/null; then
        backup_lftp "$USER" "$HOST" "$PORT" "$REMOTE_DIR" "$LOCAL_DIR"
    else
        backup_sshfs_rsync "$USER" "$HOST" "$PORT" "$REMOTE_DIR" "$LOCAL_DIR"
    fi

    end_ts=$(date +%s)
    elapsed=$(( end_ts - start_ts ))
    info "[$TARGET_NAME] ✓ Done in ${elapsed}s — local: ${LOCAL_DIR}"
}

# ─── CLI argument parsing ─────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [TARGET ...]

Options:
  -c, --config DIR     Config directory (default: ~/.config/backup)
  -t, --target NAME    Run only the named target(s); may be repeated
  -l, --list           List configured targets and exit
  -n, --dry-run        Pass --dry-run to rsync / --dry-run to lftp
  -v, --verbose        Increase verbosity
  -h, --help           Show this help

If no TARGET is given, all enabled targets are run.

Examples:
  $SCRIPT_NAME                        # back up all targets
  $SCRIPT_NAME -t webserver           # back up only 'webserver'
  $SCRIPT_NAME -t webserver -t nas    # back up two specific targets
  $SCRIPT_NAME --list                 # list targets
EOF
    exit 0
}

ONLY_TARGETS=()
DRY_RUN=false
LIST_ONLY=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)    CONFIG_DIR="$2"; shift 2;;
            -t|--target)    ONLY_TARGETS+=("$2"); shift 2;;
            -l|--list)      LIST_ONLY=true; shift;;
            -n|--dry-run)   DRY_RUN=true; RSYNC_EXTRA_OPTS="--dry-run"; shift;;
            -v|--verbose)   set -x; shift;;
            -h|--help)      usage;;
            *)              die "Unknown option: $1";;
        esac
    done

    MAIN_CONFIG="$CONFIG_DIR/main.conf"
    TARGETS_DIR="$CONFIG_DIR/targets"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    info "═══════════════════════════════════════════════════════════"
    info "  backup.sh  —  $(date '+%A %d %B %Y  %H:%M:%S %Z')"
    info "═══════════════════════════════════════════════════════════"

    check_dependencies
    load_main_config

    # Build list of target files to process
    local all_targets=()
    while IFS= read -r -d '' f; do
        all_targets+=("$f")
    done < <(find "$TARGETS_DIR" -maxdepth 1 -name "*.conf" -print0 | sort -z)

    [[ ${#all_targets[@]} -gt 0 ]] || die "No target configs found in $TARGETS_DIR"

    if $LIST_ONLY; then
        echo -e "\n${C_BOLD}Configured targets:${C_RESET}"
        for f in "${all_targets[@]}"; do
            # Quick parse for display
            local tname thost tenabled
            # strip quotes and anything after a # comment from each value
            _conf_val() { grep "^$1=" "$2" | head -1 | cut -d= -f2- \
                            | sed "s/#.*//" | tr -d '"'"'"' ' | xargs; }
            tname="$(basename "$f" .conf)"
            thost="$(_conf_val HOST "$f")"
            tenabled="$(_conf_val ENABLED "$f")"
            tenabled="${tenabled:-true}"
            local status="${C_GREEN}enabled${C_RESET}"
            [[ "$tenabled" != "true" ]] && status="${C_YELLOW}disabled${C_RESET}"
            printf "  %-20s  %-30s  %b\n" "$tname" "$thost" "$status"
        done
        echo
        exit 0
    fi

    # Filter by --target flags if given
    local targets_to_run=()
    if [[ ${#ONLY_TARGETS[@]} -gt 0 ]]; then
        for name in "${ONLY_TARGETS[@]}"; do
            local found=false
            for f in "${all_targets[@]}"; do
                if [[ "$(basename "$f" .conf)" == "$name" ]]; then
                    targets_to_run+=("$f")
                    found=true
                    break
                fi
            done
            $found || die "Target not found: $name"
        done
    else
        targets_to_run=("${all_targets[@]}")
    fi

    # Prompt for KeePass master password ONCE before starting
    prompt_master_password

    # Validate password against KeePass DB early
    info "Verifying KeePass database..."
    printf '%s\n' "$MASTER_PASSWORD" \
        | keepassxc-cli ls -q "$KEEPASS_DB" &>/dev/null \
        || die "Failed to open KeePass database — wrong master password?"
    info "KeePass database unlocked ✓"

    setup_ssh_agent

    local success=0 failed=0
    for target_file in "${targets_to_run[@]}"; do
        if run_target "$target_file"; then
            (( success++ )) || true
        else
            (( failed++ )) || true
            EXIT_CODE=1
        fi
    done

    info "═══════════════════════════════════════════════════════════"
    info "  Summary: ${success} succeeded, ${failed} failed"
    info "═══════════════════════════════════════════════════════════"

    exit $EXIT_CODE
}

main "$@"