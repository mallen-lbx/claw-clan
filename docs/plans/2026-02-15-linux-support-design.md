# Linux Support Design — Claw-Clan

**Date:** 2026-02-15
**Status:** Approved
**Scope:** Full first-class Linux support — Linux instances can be leader, run discovery, broadcast mDNS, identical capabilities to macOS.

## Summary

Add Linux support to claw-clan by adding OS-detection branching (`uname -s`) to the three platform-specific subsystems: mDNS registration, mDNS discovery, and LAN IP detection. All other scripts (SSH, cron, JSON storage, peer management, leader election, monitoring) are already cross-platform.

## Changes Required

### 1. `scripts/lib/common.sh` — Platform constants + IP detection

- Add `CLAW_OS="$(uname -s)"` constant at load time
- Add OS-aware persistence path: LaunchAgent plist (macOS) vs systemd user service (Linux)
- Fix `get_lan_ip()`: try `hostname -I` on Linux, `ipconfig getifaddr` on macOS

### 2. `scripts/claw-register.sh` — mDNS registration (biggest change)

Branch on `$CLAW_OS` for all four actions (start/stop/status/restart):

| Action | macOS | Linux |
|--------|-------|-------|
| start | Write LaunchAgent plist, `launchctl bootstrap` | Write systemd user unit, `systemctl --user enable --now` |
| stop | `launchctl bootout`, delete plist | `systemctl --user disable --now`, delete unit |
| status | `launchctl print` | `systemctl --user is-active` |
| restart | bootout + bootstrap | `systemctl --user restart` |

macOS uses `dns-sd -R`, Linux uses `avahi-publish -s`. Both block in foreground, both need a service manager for persistence.

Systemd unit location: `~/.config/systemd/user/claw-clan-mdns.service`

### 3. `scripts/claw-discover.sh` — mDNS discovery

Branch on `$CLAW_OS` for browse/resolve:

| Step | macOS | Linux |
|------|-------|-------|
| Browse | `dns-sd -B _openclaw._tcp local` | `avahi-browse _openclaw._tcp --terminate --parsable` |
| Resolve | `dns-sd -L` + `dns-sd -G` | `avahi-browse _openclaw._tcp --resolve --terminate --parsable` |

The `--parsable` flag on avahi gives semicolon-delimited output that's easier to parse than dns-sd's freeform text. Avahi resolve returns IP directly (no separate `-G` step needed).

### 4. `scripts/claw-monitor.sh` — Two fixes

- Line 40: mDNS check uses `dns-sd -B` — branch to `avahi-browse` on Linux
- Line 59: `date -j -f` is macOS-only — use `date -d` on Linux for downtime calculation

### 5. `scripts/claw-remote-install.sh` — Minor update

- Line 210: Currently says "mDNS requires macOS dns-sd" for non-Darwin — update to actually register mDNS on Linux remotes using avahi

### 6. `install.sh` — Already has Linux case

- Currently warns about avahi-browse. Change from warning to proper check (matching the macOS dns-sd check pattern).

### 7. Documentation & metadata updates

- SKILL.md files: `os: darwin` → `os: [darwin, linux]`
- README: Add Linux badge, Linux prerequisites, Linux SSH setup instructions
- Reference docs: Already have avahi mapping — polish and fill in systemd stub
- setup-guide.md: Remove "Linux is not supported as a primary host" statement
- ssh-troubleshooting.md: Add Linux SSH enablement alongside macOS

### No changes needed

These scripts are already cross-platform:
- `claw-ping.sh` — SSH + cron only
- `claw-setup-ssh.sh` — SSH only
- `claw-sync-skills.sh` — SSH + git only
- `storage.sh`, `storage-json.sh`, `storage-postgres.sh` — jq/psql only

## Linux Dependencies

Required packages:
- `avahi-utils` — provides `avahi-publish`, `avahi-browse`, `avahi-resolve`
- `avahi-daemon` — the mDNS responder service (usually installed with avahi-utils)
- `jq` — JSON processor
- `ssh`, `ssh-keygen` — OpenSSH (usually pre-installed)
- `crontab` — cron (usually pre-installed)
- Bash 4+ (usually pre-installed on modern Linux)

Install command: `sudo apt install avahi-utils jq` (Debian/Ubuntu) or `sudo dnf install avahi-tools jq` (Fedora/RHEL)

## Implementation Order

1. `common.sh` — platform constants (everything else depends on this)
2. `claw-register.sh` — Linux mDNS registration with systemd
3. `claw-discover.sh` — Linux mDNS discovery with avahi
4. `claw-monitor.sh` — mDNS check + date fix
5. `claw-remote-install.sh` — enable Linux remote mDNS registration
6. `install.sh` — upgrade Linux prereq check
7. SKILL.md files — os metadata
8. README + reference docs — Linux instructions
9. Sync to `claw-clan/` subfolder + push to GitHub
