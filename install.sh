#!/usr/bin/env bash
# =============================================================================
# install.sh — One-shot setup / update for auto-backup-with-keypass
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/backup"
TARGETS_DIR="$CONFIG_DIR/targets"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}  ✓${RESET} $*"; }
warn() { echo -e "${YELLOW}  !${RESET} $*"; }
err()  { echo -e "${RED}  ✗${RESET} $*" >&2; }

echo
echo "  auto-backup-with-keypass installer"
echo "  ──────────────────────────────────"
echo

# 1. Install the script
mkdir -p "$BIN_DIR"
cp "$SCRIPT_DIR/backup.sh" "$BIN_DIR/backup.sh"
chmod 750 "$BIN_DIR/backup.sh"
ok "Installed backup.sh → $BIN_DIR/backup.sh"

# 2. Create config skeleton
mkdir -p "$TARGETS_DIR"
chmod 700 "$CONFIG_DIR" "$TARGETS_DIR"

if [[ ! -f "$CONFIG_DIR/main.conf" ]]; then
    cp "$SCRIPT_DIR/config/main.conf.example" "$CONFIG_DIR/main.conf"
    chmod 600 "$CONFIG_DIR/main.conf"
    ok "Created $CONFIG_DIR/main.conf — please edit it"
else
    warn "$CONFIG_DIR/main.conf already exists — not overwritten"
fi

# Copy example target configs (as .example, not active)
for f in "$SCRIPT_DIR"/config/targets/*.example; do
    dest="$TARGETS_DIR/$(basename "$f")"
    [[ -f "$dest" ]] || cp "$f" "$dest"
done
ok "Example target configs in $TARGETS_DIR"

# 3. Check dependencies
echo
echo "  Dependency check:"
check() {
    if command -v "$1" &>/dev/null; then
        ok "$1 found: $(command -v "$1")"
    else
        warn "$1 NOT found — install it: $2"
    fi
}
check keepassxc-cli  "https://keepassxc.org / brew install keepassxc"
check rsync          "sudo apt install rsync  / brew install rsync"
check restic         "sudo apt install restic / brew install restic"
check lftp           "sudo apt install lftp   / brew install lftp  (for non-rsync targets)"

if [[ "$OSTYPE" == darwin* ]]; then
    check sshfs "brew install --cask macfuse && brew install gromgit/fuse/sshfs-mac  (fallback)"
else
    check sshfs "sudo apt install sshfs  (fallback)"
fi

# 4. Platform-specific scheduler
echo
if [[ "$OSTYPE" == darwin* ]]; then
    # ── macOS launchd ──────────────────────────────────────────────────────────

    PLIST_LABEL="org.surrel.g.backup"
    PLIST_DST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
    LOG_DIR="$HOME/Library/Logs/backup"

    mkdir -p "$LOG_DIR"

    # Unload existing agent before overwriting the file.
    # `launchctl unload` is idempotent — safe to call even if not loaded.
    # Suppress output: on first install there is nothing to unload.
    if launchctl list "$PLIST_LABEL" &>/dev/null; then
        launchctl unload "$PLIST_DST" 2>/dev/null || true
        ok "Unloaded existing launchd agent"
    fi

    # Generate the plist directly from shell variables rather than using sed
    # on a placeholder — avoids any mismatch between $(whoami) and $HOME on
    # managed Macs where the two can differ.
    mkdir -p "$(dirname "$PLIST_DST")"
    cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  ${PLIST_LABEL}.plist — macOS launchd agent
  ============================================

  Install / update:
    bash install.sh

  Check status:
    launchctl list ${PLIST_LABEL}

  View logs:
    tail -f ${LOG_DIR}/stdout.log
    tail -f ${LOG_DIR}/stderr.log

  Run manually:
    launchctl start ${PLIST_LABEL}

  Disable:
    launchctl unload ${PLIST_DST}

  Note: the script uses osascript to prompt for the KeePass password,
  which requires a GUI session — this will NOT work if launched from
  a headless/SSH session.
-->
<plist version="1.0">
<dict>

    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${BIN_DIR}/backup.sh</string>
    </array>

    <!-- Poll every 30 minutes. The script itself checks a stamp file and
         exits immediately if a successful backup has already run today.
         Polling rather than a fixed calendar time ensures the backup
         eventually runs on a machine that was asleep at the scheduled hour. -->
    <key>StartInterval</key>
    <integer>1800</integer>

    <!-- Also run once shortly after the agent is loaded (i.e. after login),
         so a machine that was off overnight backs up promptly on next wake
         rather than waiting up to 30 minutes for the first poll. -->
    <key>RunAtLoad</key>
    <true/>

    <!-- Environment variables passed to the script.
         HOME is set explicitly because launchd agents do not inherit the
         interactive shell environment. PATH includes Homebrew prefixes for
         both Apple Silicon (/opt/homebrew) and Intel (/usr/local) Macs. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>

    <!-- Require a network connection before launching.
         Prevents the job from firing immediately after boot while the
         network interface is still coming up. -->
    <key>NetworkState</key>
    <true/>

    <!-- Redirect stdout and stderr to rotating log files.
         The script also writes its own timestamped log under
         ~/.local/share/backup/logs/, but these files capture anything
         printed before the script's logging is initialised. -->
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/stderr.log</string>

</dict>
</plist>
PLIST

    # Plist must not be world-writable or launchd will refuse to load it
    chmod 644 "$PLIST_DST"
    ok "Wrote launchd plist → $PLIST_DST"

    launchctl load "$PLIST_DST"
    ok "Loaded launchd agent (runs daily at 02:00)"

    echo
    echo "  Useful commands:"
    echo "    launchctl list $PLIST_LABEL          # check status"
    echo "    launchctl start $PLIST_LABEL         # run now"
    echo "    launchctl unload $PLIST_DST  # disable"
    echo "    tail -f $LOG_DIR/stdout.log"

else
    # ── Linux systemd ──────────────────────────────────────────────────────────

    SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"

    # Stop the timer before replacing unit files so systemd doesn't read a
    # half-written file; restart it afterwards.
    TIMER_ACTIVE=false
    if systemctl --user is-active --quiet backup.timer 2>/dev/null; then
        systemctl --user stop backup.timer
        TIMER_ACTIVE=true
        ok "Stopped running backup.timer"
    fi

    cp "$SCRIPT_DIR/systemd/backup.service" "$SYSTEMD_DIR/"
    cp "$SCRIPT_DIR/systemd/backup.timer"   "$SYSTEMD_DIR/"
    ok "Installed systemd units → $SYSTEMD_DIR"

    systemctl --user daemon-reload
    ok "Reloaded systemd daemon"

    # Enable the timer unconditionally (idempotent), then restore previous
    # running state.
    systemctl --user enable backup.timer
    if $TIMER_ACTIVE; then
        systemctl --user start backup.timer
        ok "Restarted backup.timer"
    else
        ok "Enabled backup.timer (not yet started — run 'systemctl --user start backup.timer' or wait for next boot)"
    fi

    echo
    echo "  Useful commands:"
    echo "    systemctl --user start backup.timer      # start now"
    echo "    systemctl --user list-timers             # check next trigger"
    echo "    journalctl --user -u backup.service -f   # follow logs"
fi

# 5. Next steps

echo
echo "  Next steps:"
echo "    1. Edit  $CONFIG_DIR/main.conf"
echo "    2. Create target configs in $TARGETS_DIR (copy from *.example)"
echo "    3. Run a test:  backup.sh --list"
echo "    4. Run manually:  backup.sh"
echo
