# auto-backup-with-keypass

Automated backup script with [KeePassXC](https://keepassxc.org/) integration.
Pulls remote server directories to local storage via SSH, then snapshots the
local machine to a remote archive via restic. Designed to run unattended on a
schedule via systemd (Linux) or launchd (macOS).

At the end of the backup, support for [restic](https://restic.net/) exists
to save the local machine with the backups to a remove solution.

---

## How it works

Each run performs two phases in order:

**Phase 1 — SSH targets.** For each enabled target config, the script
connects to the remote host, detects the available transfer method, and
syncs the configured remote directory to a local destination. Deleted files
on the remote are also deleted locally.

**Phase 2 — Restic snapshot.** After all SSH targets complete, a restic
snapshot of the local machine is pushed to the configured remote repository.
This phase runs regardless of whether any SSH targets failed.

All credentials (SSH key passphrases, KeePass master password, restic
repository password) are retrieved from a single KeePass database. The
master password is asked once — interactively at the terminal, or via a GUI
dialog when launched headlessly by the scheduler.

---

## Transfer strategy

The script picks the best available method per target, in order:

| Condition | Method | Notes |
|-----------|--------|-------|
| Remote has `rsync` | `rsync` over SSH | Checksum-based, `--delete-after` |
| No remote rsync, `lftp` available | `lftp mirror` over SFTP | `--only-newer --delete --parallel=4` |
| Neither, `sshfs` available | Mount + local `rsync` | Last resort |

Set `HAS_RSYNC="true"` or `"false"` in a target config to skip detection.
Leave it empty (the default) for auto-detection on each run.

---

## Directory layout

```
~/.local/bin/backup.sh          Main script
~/.config/backup/
├── main.conf                   Global settings — chmod 600
└── targets/
    ├── webserver.conf          One file per SSH target — chmod 600
    └── nas.conf
~/.local/share/backup/logs/     Daily log files (backup-YYYY-MM-DD.log)

# macOS scheduler
~/Library/LaunchAgents/org.surrel.g.backup.plist

# Linux scheduler
~/.config/systemd/user/backup.service
~/.config/systemd/user/backup.timer
```

---

## Quick start

```bash
# 1 — Run the installer
bash install.sh

# 2 — Edit the main config (KeePass path, backup root, restic settings)
nano ~/.config/backup/main.conf

# 3 — Create at least one SSH target
cp ~/.config/backup/targets/webserver.conf.example \
   ~/.config/backup/targets/myserver.conf
chmod 600 ~/.config/backup/targets/myserver.conf
nano ~/.config/backup/targets/myserver.conf

# 4 — Verify targets are recognised
backup.sh --list

# 5 — Dry run a specific target (rsync/lftp will report without transferring;
#     restic is skipped entirely — it has no dry-run mode)
backup.sh --dry-run --target myserver

# 6 — Enable the scheduler
# macOS:
launchctl load ~/Library/LaunchAgents/org.surrel.g.backup.plist
# Linux:
systemctl --user daemon-reload
systemctl --user enable --now backup.timer
```

---

## Dependencies

| Tool | Required | Purpose |
|------|----------|---------|
| `keepassxc-cli` | Yes | Retrieve all required credentials from `.kdbx` |
| `ssh`, `ssh-agent`, `ssh-add` | Yes | Remote connectivity |
| `rsync` | Recommended | Fast sync for targets that have it |
| `lftp` | Recommended | Mirror fallback for targets without rsync |
| `sshfs` | Optional | Last-resort fallback if lftp unavailable |
| `restic` | If using phase 2 | Local → remote archive snapshots |
| `rclone` | If restic repo uses it | e.g. `rclone:gdrive:backup` |
| `zenity` or `kdialog` | Linux headless only | GUI password prompt for systemd |

**macOS (Homebrew):**
```bash
brew install keepassxc rsync lftp restic rclone
# sshfs fallback (requires kernel extension — approve in System Settings):
brew install --cask macfuse
brew install gromgit/fuse/sshfs-mac
```

**Debian / Ubuntu:**
```bash
sudo apt install keepassxc rsync lftp sshfs restic rclone zenity
```

---

## Main config (`main.conf`)

Lives at `~/.config/backup/main.conf`. Must be `chmod 600` — the script
refuses to run if permissions are looser, unless
`BACKUP_ALLOW_INSECURE_CONFIG=1` is exported.

### SSH / global settings

| Variable | Required | Description |
|----------|----------|-------------|
| `KEEPASS_DB` | Yes | Path to your `.kdbx` database |
| `LOCAL_BACKUP_ROOT` | Yes | Parent directory for all SSH target backups |
| `SSH_KEY_DEFAULT` | Yes | Default SSH private key path |
| `BANDWIDTH_LIMIT` | No | Global KB/s cap for all targets (0 = unlimited) |

### Restic settings

| Variable | Default | Description |
|----------|---------|-------------|
| `RESTIC_ENABLED` | `"false"` | Set to `"true"` to enable phase 2 |
| `RESTIC_REPO` | — | Repository URI, e.g. `rclone:pCloud:restic` |
| `RESTIC_KEEPASS_ENTRY` | — | KeePass entry path for the repo password |
| `RESTIC_BACKUP_PATHS` | — | Bash array of paths to snapshot |
| `RESTIC_EXCLUDES` | `()` | Bash array of `--exclude` patterns |
| `RESTIC_EXCLUDE_IF_PRESENT` | `()` | Bash array of `--exclude-if-present` markers |
| `RESTIC_FORGET_OPTS` | `""` | If set, runs `restic forget --prune` after backup |
| `RESTIC_EXTRA_OPTS` | `""` | Extra flags appended to `restic backup` |

`RESTIC_EXCLUDES` and `RESTIC_EXCLUDE_IF_PRESENT` are bash arrays — each
element maps directly to one flag, with no quoting or escaping required:

```bash
RESTIC_EXCLUDES=(
    "**/.cache/"
    "**/target/"
)
RESTIC_EXCLUDE_IF_PRESENT=(".nobackup")
```

Restic has no dry-run mode. When `backup.sh --dry-run` is passed, the restic
phase is skipped and a notice is logged.

---

## SSH target config

Each file in `~/.config/backup/targets/` ending in `.conf` is one target.
Files must be `chmod 600`.

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | — | SSH hostname or IP **(required)** |
| `PORT` | `22` | SSH port |
| `USER` | current user | SSH login username |
| `REMOTE_DIR` | — | Remote path to back up **(required)** |
| `LOCAL_DIR` | `$LOCAL_BACKUP_ROOT/$TARGET_NAME` | Local destination |
| `SSH_KEY` | `$SSH_KEY_DEFAULT` | Path to SSH private key |
| `KEEPASS_ENTRY` | — | KeePass entry for the key passphrase **(required)** |
| `HAS_RSYNC` | `""` (auto) | `"true"` / `"false"` / `""` |
| `RSYNC_EXTRA_OPTS` | `""` | Extra rsync flags (word-split into array) |
| `LFTP_EXTRA_OPTS` | `""` | Extra lftp `set` commands |
| `BANDWIDTH_LIMIT` | `0` | KB/s cap for this target (overrides global) |
| `ENABLED` | `"true"` | Set `"false"` to skip without removing the file |

Inline comments in target configs are handled correctly — `HOST="1.2.3.4" #
comment` will not be misread as disabled by `--list`.

---

## CLI reference

```
backup.sh [OPTIONS] [TARGET ...]

  -c, --config DIR     Config directory (default: ~/.config/backup)
  -t, --target NAME    Run only this target; may be repeated
  -l, --list           List configured targets and exit
  -n, --dry-run        Dry run (rsync: --dry-run; lftp: --dry-run;
                       restic: skipped with notice)
  -v, --verbose        Trace execution (set -x)
  -h, --help           Show help
```

---

## Scheduler

### macOS (launchd)

The agent runs daily at 02:00. Missed runs (machine was asleep) are
automatically replayed. Yet, a manual trigger can be done using `launchctl kickstart` if needed.

```bash
# Load (enable)
launchctl load ~/Library/LaunchAgents/org.surrel.g.backup.plist

# Force-start immediately (kills any lingering instance first)
launchctl kickstart -k gui/$(id -u)/org.surrel.g.backup

# Check last exit status
launchctl list org.surrel.g.backup

# View logs
tail -f ~/Library/Logs/backup/stdout.log
tail -f ~/Library/Logs/backup/stderr.log

# Unload (disable)
launchctl unload ~/Library/LaunchAgents/org.surrel.g.backup.plist
```

The GUI password prompt (osascript) retries for up to 60 seconds if the
display is not ready yet — this handles the common case of the script firing
shortly after wake from sleep.

After a cancelled or failed run, use `launchctl kickstart -k` rather than
`launchctl start` — the `-k` flag kills any lingering process first,
ensuring a clean start.

### Linux (systemd)

```bash
systemctl --user enable --now backup.timer   # enable and start timer
systemctl --user list-timers                 # check next trigger time
systemctl --user start backup.service        # run immediately
journalctl --user -u backup.service -f       # follow logs
```

`Persistent=true` is set in the timer, so a run missed while the machine
was off will fire within 15 minutes of the next login.

---

## Security

**Credentials never touch disk.** SSH key passphrases and the restic
repository password are passed via FIFO (named pipe) — the secret exists
only in the kernel pipe buffer and is never written to a file.

**KeePass master password** is held in a bash variable for the duration of
the run, then overwritten with random bytes before the variable is unset.
This is best-effort in bash (no locked memory pages), but core dumps are
disabled at startup (`ulimit -c 0`) to reduce exposure.

**Config file permissions are enforced.** `main.conf` and target configs
must be `chmod 600`. The script dies on startup if permissions are looser,
unless `BACKUP_ALLOW_INSECURE_CONFIG=1` is exported explicitly.

**Concurrent runs are prevented** by a PID lockfile at
`$TMPDIR/backup.lock`. Stale locks from hard crashes are detected via
`kill -0` and removed automatically.

**SSH agent lifecycle.** If no agent is running, the script starts one,
loads the required keys, and kills it on exit. If an agent is already
running (e.g. your desktop session's agent), it is reused and left running.

This script is intended for single-user machines. On shared systems,
consider whether `$TMPDIR` is private and whether swap encryption is
enabled.
