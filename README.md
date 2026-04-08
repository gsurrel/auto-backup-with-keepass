# auto-backup-with-keypass

Automated SSH backup with KeePassXC integration, supporting both rsync and
lftp-based transfers, designed to run unattended via systemd or launchd.

## Features

- **KeePassXC** — retrieves SSH key passwords from your `.kdbx` database;
  master password asked once interactively, or via a GUI dialog when running
  headless
- **Per-target config files** — one `.conf` per server/directory pair
- **rsync** (when available on remote) — archive mode, checksum-based,
  removes deleted files
- **lftp mirror** fallback — for servers without rsync; transfers only
  changed/new files, removes deleted ones locally
- **sshfs + rsync** last-resort fallback — when lftp is also unavailable
- **systemd timer** (Linux) and **launchd agent** (macOS) integration
- Structured log files with timestamps

## Directory layout

```
~/.local/bin/backup.sh          Main script
~/.config/backup/
├── main.conf                   Global settings (chmod 600)
└── targets/
    ├── webserver.conf          One file per backup target
    └── nas.conf
~/.local/share/backup/logs/     Daily log files
```

## Quick start

```bash
# 1 — Install
bash install.sh

# 2 — Edit main config
nano ~/.config/backup/main.conf

# 3 — Create a target
cp ~/.config/backup/targets/webserver.conf.example \
   ~/.config/backup/targets/myserver.conf
nano ~/.config/backup/targets/myserver.conf

# 4 — Test
backup.sh --list
backup.sh --dry-run --target myserver

# 5 — Enable automatic schedule
# Linux:
systemctl --user enable --now backup.timer
# macOS:
launchctl load ~/Library/LaunchAgents/org.surrel.g.backup.plist
```

## Dependencies

| Tool | Required | Purpose |
|------|----------|---------|
| `keepassxc-cli` | Yes | Retrieve SSH key passwords from .kdbx |
| `ssh`, `ssh-agent`, `ssh-add` | Yes | Remote connectivity |
| `rsync` | Recommended | Fast sync for servers that have it |
| `lftp` | Recommended | Mirror for servers without rsync |
| `sshfs` | Optional | Last-resort fallback if lftp unavailable |
| `zenity` / `kdialog` | Linux headless | GUI password prompt for systemd |

Install on Debian/Ubuntu:
```bash
sudo apt install keepassxc rsync lftp sshfs zenity
```

Install on macOS (Homebrew):
```bash
brew install keepassxc rsync lftp
brew install --cask macfuse  # for sshfs fallback
brew install gromgit/fuse/sshfs-mac
```

## Target config options

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | — | SSH hostname or IP (required) |
| `PORT` | `22` | SSH port |
| `USER` | current user | SSH username |
| `REMOTE_DIR` | — | Directory to back up (required) |
| `LOCAL_DIR` | `$LOCAL_BACKUP_ROOT/$TARGET_NAME` | Local destination |
| `SSH_KEY` | `SSH_KEY_DEFAULT` | Path to SSH private key |
| `KEEPASS_ENTRY` | — | KeePass entry path (required) |
| `HAS_RSYNC` | auto-detect | `"true"` / `"false"` / `""` |
| `RSYNC_EXTRA_OPTS` | `""` | Extra rsync flags |
| `LFTP_EXTRA_OPTS` | `""` | Extra lftp settings |
| `BANDWIDTH_LIMIT` | `0` | KB/s cap (0 = unlimited) |
| `ENABLED` | `true` | Set `false` to skip without deleting |

## Security notes

- Config files should be `chmod 600` — `install.sh` sets this automatically
- The master password is stored only in a bash variable; the script
  overwrites it with random bytes on exit
- Temporary askpass helper scripts are created in `/tmp` with mode 700 and
  deleted immediately after `ssh-add`
- The SSH agent is torn down after the script exits (if the script started it)
