#!/usr/bin/env bash
# =============================================================================
# install.sh — One-shot setup for auto-backup-with-keypass
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/backup"
TARGETS_DIR="$CONFIG_DIR/targets"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}  ✓${RESET} $*"; }
warn() { echo -e "${YELLOW}  !${RESET} $*"; }

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
check lftp           "sudo apt install lftp   / brew install lftp  (for non-rsync targets)"

if [[ "$OSTYPE" == darwin* ]]; then
    check sshfs "brew install --cask macfuse && brew install gromgit/fuse/sshfs-mac  (fallback)"
else
    check sshfs "sudo apt install sshfs  (fallback)"
fi

# 4. Platform-specific scheduler
echo
if [[ "$OSTYPE" == darwin* ]]; then
    PLIST_SRC="$SCRIPT_DIR/launchd/org.surrel.g.backup.plist"
    PLIST_DST="$HOME/Library/LaunchAgents/org.surrel.g.backup.plist"
    sed "s|YOUR_USERNAME|$(whoami)|g" "$PLIST_SRC" > "$PLIST_DST"
    ok "Installed launchd plist → $PLIST_DST"
    echo
    echo "  To activate the launchd timer:"
    echo "    launchctl load ~/Library/LaunchAgents/org.surrel.g.backup.plist"
else
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"
    cp "$SCRIPT_DIR/systemd/backup.service" "$SYSTEMD_DIR/"
    cp "$SCRIPT_DIR/systemd/backup.timer"   "$SYSTEMD_DIR/"
    ok "Installed systemd units → $SYSTEMD_DIR"
    echo
    echo "  To activate the systemd timer:"
    echo "    systemctl --user daemon-reload"
    echo "    systemctl --user enable --now backup.timer"
fi

echo
echo "  Next steps:"
echo "    1. Edit  $CONFIG_DIR/main.conf"
echo "    2. Create target configs in $TARGETS_DIR (copy from *.example)"
echo "    3. Run a test:  backup.sh --list"
echo "    4. Run manually:  backup.sh"
echo "    5. Enable the timer (see above)"
echo
