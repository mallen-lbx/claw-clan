# Claw-Clan

Multi-instance OpenClaw coordination for local area networks.

![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)
![Bash](https://img.shields.io/badge/language-bash-green)
![OpenClaw](https://img.shields.io/badge/OpenClaw-skill--based-blue)

---

## Overview

Claw-Clan enables multiple OpenClaw instances running on the same LAN to discover each other, monitor health, coordinate recovery, and share skills. It solves a fundamental problem: when you have two or more OpenClaw agents on separate machines, none of them knows the others exist. There is no built-in mechanism for inter-instance awareness, health monitoring, or coordinated recovery.

Claw-Clan provides this through zero-configuration LAN discovery (mDNS/Bonjour), SSH-based communication between peers, cron-driven health checks, and leader-elected recovery coordination. Everything runs as bash scripts orchestrated by two OpenClaw skills, with no additional infrastructure required beyond what macOS already provides.

---

## Architecture

```
+-------------------------------------------------------------+
|                        claw-clan                             |
+-----------------------------+-------------------------------+
|   Skills (2)                |   Scripts (6)                  |
|                             |                                |
|   claw-clan                 |   claw-register.sh   (mDNS)   |
|   - Interactive setup       |   claw-discover.sh   (mDNS)   |
|   - SSH key management      |   claw-ping.sh       (cron)   |
|   - Peer discovery          |   claw-monitor.sh    (leader)  |
|   - Fleet status            |   claw-setup-ssh.sh  (keys)   |
|                             |   claw-sync-skills.sh (git)   |
|   claw-afterlife            |                                |
|   - Leader election         |   Library (4)                  |
|   - Health monitoring       |   lib/common.sh      (shared)  |
|   - Offline detection       |   lib/storage.sh     (dispatch)|
|   - Recovery coordination   |   lib/storage-json.sh (default)|
|   - Skill reinstallation    |   lib/storage-postgres.sh (opt)|
+-----------------------------+-------------------------------+
|   Storage Backend (pluggable)                                |
|   [JSON files] <-- default, zero dependencies               |
|   [PostgreSQL] <-- optional, for historical data & auditing  |
+-------------------------------------------------------------+
|   External Dependencies                                      |
|   mDNS/Bonjour -- zero-config LAN service discovery          |
|   SSH          -- secure inter-instance communication        |
|   cron         -- scheduled keep-alive pings                 |
|   LaunchAgent  -- persistent mDNS registration               |
|   GitHub repo  -- fleet manifest + shared skills (optional)  |
+-------------------------------------------------------------+
```

### Flow

```
 discover (mDNS)     connect (SSH)      health (cron)      recover (leader)
  +-----------+      +----------+      +------------+      +-----------+
  | dns-sd -B | ---> | SSH test | ---> | claw-ping  | ---> | claw-     |
  | browse    |      | handshake|      | every 15m  |      | monitor   |
  | resolve   |      | exchange |      | update     |      | detect    |
  | save peer |      | keys     |      | peer state |      | recovery  |
  +-----------+      +----------+      +------------+      | reinstall |
                                                           +-----------+
```

---

## Prerequisites

- **macOS** (primary). Linux is possible with Avahi but not the primary target.
- **OpenClaw** installed and running on each machine.
- **SSH enabled.** On macOS: System Settings > General > Sharing > Remote Login.
- **jq** for JSON processing. Install via `brew install jq` if not present.
- **git** for cloning the repo and optional skill sync.
- **Optional:** Docker (for PostgreSQL deployment).

---

## Installation

```bash
git clone git@github.com:<your-user>/claw-clan.git
cd claw-clan
bash install.sh
```

The `install.sh` script copies scripts and skills into `~/.openclaw/claw-clan/`. It does not run interactive setup, does not modify your crontab, and does not start any services. It is safe to re-run at any time to update scripts without affecting your existing configuration.

After installation, open your OpenClaw agent and say:

```
Set up claw-clan
```

The agent uses the `claw-clan` skill to walk you through interactive setup.

---

## Setup (Interactive)

Setup is driven conversationally by the OpenClaw agent using the `claw-clan` skill. The agent will ask you for five pieces of information:

| Prompt | Default | Purpose |
|--------|---------|---------|
| Gateway ID | `$(hostname)` | Unique machine identifier across the fleet |
| Friendly name | (required) | Human-readable label for logs and display |
| Lead number | (required) | Leader election priority (1 = highest) |
| SSH user | `$(whoami)` | Username for SSH connections from peers |
| GitHub repo URL | (optional) | Private repo for shared skills distribution |

After collecting your answers, the agent creates the following:

- `~/.openclaw/claw-clan/state.json` -- this instance's identity
- `~/.openclaw/claw-clan/config.json` -- operational settings with defaults
- A macOS LaunchAgent for persistent mDNS registration
- A cron entry for 15-minute keep-alive pings
- Peer files for any discovered instances on the LAN

The agent also runs mDNS discovery to find existing fleet members and tests SSH connectivity to each one. If SSH fails, it provides step-by-step key exchange instructions.

---

## Usage

### Fleet Status

```bash
# View this instance's identity
cat ~/.openclaw/claw-clan/state.json | jq .

# View all peers with status summary
for f in ~/.openclaw/claw-clan/peers/*.json; do
  jq -r '[.name, .gatewayId, .status, .lastSeen] | @tsv' "$f"
done | column -t

# View detailed peer info
for f in ~/.openclaw/claw-clan/peers/*.json; do
  jq '{gatewayId, name, status, lastSeen, missedPings, sshConnectivity}' "$f"
done
```

### Manual Peer Discovery

```bash
~/.openclaw/claw-clan/scripts/claw-discover.sh
```

Browses the LAN for `_openclaw._tcp` services for 5 seconds (configurable as first argument), resolves each to an IP, extracts TXT records, and saves peer files.

### Manual Ping

```bash
~/.openclaw/claw-clan/scripts/claw-ping.sh
```

Pings all known peers via SSH and updates their status, last-seen timestamp, and missed ping count.

### SSH Connectivity Check

```bash
~/.openclaw/claw-clan/scripts/claw-setup-ssh.sh check
```

Tests SSH to all peers. Generates a local SSH key if missing. Prints key exchange instructions for any peer that fails.

### Skill Sync from GitHub

```bash
# Sync to all online peers
~/.openclaw/claw-clan/scripts/claw-sync-skills.sh all

# Sync to a specific peer
~/.openclaw/claw-clan/scripts/claw-sync-skills.sh <gateway-id>
```

Pulls the latest shared skills from the configured GitHub repo locally, then SSHes into each target peer to pull the same repo.

### mDNS Registration Management

```bash
~/.openclaw/claw-clan/scripts/claw-register.sh start    # Install and start LaunchAgent
~/.openclaw/claw-clan/scripts/claw-register.sh stop     # Remove LaunchAgent
~/.openclaw/claw-clan/scripts/claw-register.sh status   # Check if running
~/.openclaw/claw-clan/scripts/claw-register.sh restart   # Stop and re-start
```

---

## How It Works

### mDNS Discovery

Each instance registers a Bonjour service of type `_openclaw._tcp` on port 22 using `dns-sd -R`. TXT records carry the gateway ID, friendly name, lead number, and version. Since `dns-sd -R` blocks in the foreground and the service disappears when the process exits, a macOS LaunchAgent with `KeepAlive: true` and `RunAtLoad: true` ensures the registration persists across reboots and survives crashes.

Discovery uses `dns-sd -B` (browse), `dns-sd -L` (lookup), and `dns-sd -G` (resolve hostname to IP) in sequence for each discovered service.

### Keep-Alive Protocol

A cron job runs `claw-ping.sh` every 15 minutes. For each known peer, it SSHes in and runs:

```
echo "are-you-on-claw-clan $(hostname) $(date +%s)"
```

The peer responds with `claw-clan-ack <gateway-id> <timestamp>`. On success, the peer's status is set to `online` and its missed ping count resets to zero. On timeout (30 seconds), the missed ping count increments.

### Leader Election

Leadership is static and deterministic. Each instance is assigned a unique integer lead number during setup. The instance with the lowest lead number among all currently online peers is the leader. If the leader goes offline, the next-lowest number becomes the acting leader. When the original leader recovers, it automatically reclaims leadership.

There is no consensus protocol, no voting, and no quorum requirement. Each instance independently evaluates the same peer data and arrives at the same conclusion.

### Offline Detection

After a configurable threshold of consecutive missed pings (default: 2, meaning 30 minutes), a peer is marked `offline`. The leader is responsible for acting on offline detection by offering the user two options: start continuous monitoring (5-minute cron job) or ignore.

### Recovery

When `claw-monitor.sh` detects that an offline peer is responding again via SSH, it:

1. Updates the peer status to `online`
2. Removes its own monitoring cron job (self-cleanup)
3. Checks whether `state.json`, mDNS registration, and cron jobs are intact on the recovered peer
4. Writes a recovery report to `~/.openclaw/claw-clan/logs/recovery-<gateway-id>.json`

The `claw-afterlife` skill presents the recovery report and offers options: reinstall claw-clan on the recovered peer or ignore.

### Skill Distribution

When a GitHub repo is configured, `claw-sync-skills.sh` pulls the latest skills locally and then SSHes into each online peer to trigger a pull on the remote. This ensures all fleet members share the same skill set. Sync can be triggered manually or as part of recovery.

---

## Configuration

### state.json

This instance's identity. Created during setup. Located at `~/.openclaw/claw-clan/state.json`.

```json
{
  "gatewayId": "macbook-pro-01",
  "name": "Dev Station",
  "leadNumber": 1,
  "ip": "192.168.1.100",
  "sshUser": "mallen",
  "version": "1.0.0",
  "registeredAt": "2026-02-14T10:00:00Z",
  "githubRepo": "git@github.com:user/openclaw-shared-skills.git"
}
```

### config.json

Operational settings. Located at `~/.openclaw/claw-clan/config.json`.

```json
{
  "backend": "json",
  "pingIntervalMinutes": 15,
  "offlineThresholdPings": 2,
  "monitorIntervalMinutes": 5,
  "postgres": {
    "host": null,
    "port": 5432,
    "database": "claw_clan",
    "user": null,
    "password": null,
    "deployed": false,
    "deployMethod": null
  }
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `backend` | `"json"` | Storage backend: `"json"` for local files, `"postgres"` for database |
| `pingIntervalMinutes` | `15` | Cron interval for keep-alive pings |
| `offlineThresholdPings` | `2` | Missed pings before marking a peer offline |
| `monitorIntervalMinutes` | `5` | Cron interval for continuous monitoring of a specific offline peer |

### Peer Data

Each peer is stored at `~/.openclaw/claw-clan/peers/<gateway-id>.json`.

```json
{
  "gatewayId": "linux-server-01",
  "name": "Build Box",
  "leadNumber": 2,
  "ip": "192.168.1.101",
  "sshUser": "mallen",
  "status": "online",
  "lastSeen": "2026-02-14T10:15:00Z",
  "lastPingAttempt": "2026-02-14T10:15:00Z",
  "missedPings": 0,
  "sshConnectivity": true,
  "clawClanInstalled": true,
  "mdnsBroadcasting": true
}
```

---

## PostgreSQL (Optional)

The default JSON file backend is sufficient for small fleets. Switch to PostgreSQL when you want:

- **Historical ping data** with timestamps and response times
- **Incident logs** tracking offline/online/recovery events
- **Skill audit trail** recording installs, updates, and removals
- **Leader election history**

### Switching to PostgreSQL

**Option A: Use an existing PostgreSQL instance**

```bash
# Update config.json with connection details
jq '.backend = "postgres" |
  .postgres.host = "<host>" |
  .postgres.port = <port> |
  .postgres.database = "<db>" |
  .postgres.user = "<user>" |
  .postgres.password = "<pass>"' \
  ~/.openclaw/claw-clan/config.json > /tmp/config.json \
  && mv /tmp/config.json ~/.openclaw/claw-clan/config.json

# Run the migration
psql -h <host> -p <port> -U <user> -d <db> \
  -f ~/.openclaw/claw-clan/migrations/001-initial-schema.sql
```

**Option B: Deploy a new instance via Docker**

```bash
docker run -d \
  --name claw-clan-postgres \
  --restart unless-stopped \
  -e POSTGRES_DB=claw_clan \
  -e POSTGRES_USER=claw \
  -e POSTGRES_PASSWORD="$(openssl rand -base64 32)" \
  -p 5432:5432 \
  -v claw-clan-pgdata:/var/lib/postgresql/data \
  postgres:17-alpine
```

Then update `config.json` with the connection details and run the migration.

### What PostgreSQL Stores vs JSON

| Data | JSON Backend | PostgreSQL Backend |
|------|-------------|-------------------|
| Instance identity | `state.json` | `state.json` (unchanged) |
| Peer status | `peers/<id>.json` | `peer_status` table + local JSON fallback |
| Fleet registry | `fleet.json` | `fleet_instances` table + local JSON fallback |
| Ping history | Not stored | `ping_history` table (timestamped) |
| Incident log | `logs/events.log` (append-only) | `incident_log` table (queryable) |
| Skill audit | Not stored | `skill_audit` table |

---

## Project Structure

```
claw-clan/
+-- skills/
|   +-- claw-clan/
|   |   +-- SKILL.md                     # OpenClaw skill: setup, discovery, SSH, fleet
|   |   +-- references/
|   |       +-- setup-guide.md           # Step-by-step first-time setup walkthrough
|   |       +-- ssh-troubleshooting.md   # SSH failure diagnosis and resolution
|   |       +-- mdns-reference.md        # dns-sd commands, LaunchAgent, firewall notes
|   +-- claw-afterlife/
|       +-- SKILL.md                     # OpenClaw skill: health, leader, recovery
|       +-- references/
|           +-- leader-election.md       # Leader determination, failover, edge cases
|           +-- recovery-procedures.md   # Recovery workflow, reports, reinstallation
|           +-- postgres-setup.md        # Docker/Portainer deploy, migration, credentials
+-- scripts/
|   +-- claw-register.sh                # mDNS service registration via LaunchAgent
|   +-- claw-discover.sh                # mDNS browse, lookup, resolve peers
|   +-- claw-ping.sh                    # Cron-driven keep-alive ping to all peers
|   +-- claw-monitor.sh                 # Leader-only continuous monitoring of offline peer
|   +-- claw-setup-ssh.sh               # SSH key generation and connectivity testing
|   +-- claw-sync-skills.sh             # GitHub repo skill distribution to peers
|   +-- lib/
|       +-- common.sh                   # Shared constants, logging, validation helpers
|       +-- storage.sh                  # Pluggable storage backend dispatcher
|       +-- storage-json.sh             # JSON file storage implementation
|       +-- storage-postgres.sh         # PostgreSQL storage implementation
+-- migrations/
|   +-- 001-initial-schema.sql          # PostgreSQL tables, indexes, constraints
+-- docs/
    +-- plans/
        +-- 2026-02-14-claw-clan-design.md          # Architecture and design decisions
        +-- 2026-02-14-claw-clan-implementation.md   # Task-by-task implementation plan
```

### Runtime Data (not in repo)

```
~/.openclaw/claw-clan/
+-- state.json            # This instance's identity
+-- config.json           # Operational settings
+-- fleet.json            # Fleet manifest (all known instances)
+-- peers/
|   +-- <gateway-id>.json # Per-peer status and ping history
+-- logs/
|   +-- ping.log          # Keep-alive ping output
|   +-- monitor.log       # Continuous monitoring output
|   +-- mdns-register.log # LaunchAgent stdout
|   +-- events.log        # Event log (JSON backend)
|   +-- recovery-<id>.json# Recovery reports
+-- scripts/              # Installed scripts (copied from repo)
```

---

## Recovery Install

If claw-clan scripts need to be updated or restored on a machine that was already set up:

```bash
bash install.sh
```

This re-copies all scripts and skills into `~/.openclaw/claw-clan/` without touching `state.json`, `config.json`, or peer data. It does NOT re-trigger interactive setup. Your identity, configuration, and peer state are preserved.

To update scripts on a remote peer after recovery, use the `claw-afterlife` skill or manually:

```bash
scp -r ~/.openclaw/claw-clan/scripts/ <user>@<peer-ip>:~/.openclaw/claw-clan/scripts/
ssh <user>@<peer-ip> "~/.openclaw/claw-clan/scripts/claw-register.sh restart"
```

---

## Troubleshooting

### SSH key exchange fails

**Symptom:** `claw-setup-ssh.sh check` reports failures for a peer.

**Fix:** SSH keys must be exchanged bidirectionally. On this machine:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
ssh-copy-id -i ~/.ssh/id_ed25519.pub <peer-user>@<peer-ip>
```

Then on the peer machine, do the same in reverse pointing back to this machine.

### mDNS not finding peers

**Symptom:** `claw-discover.sh` returns zero peers even though other instances are running.

**Possible causes:**
- Machines are on different subnets or VLANs. mDNS is link-local only and does not cross routers.
- The peer's LaunchAgent is not running. Check with `claw-register.sh status` on the peer.
- DNS cache is stale (common after sleep/wake on macOS Sequoia). Flush it:
  ```bash
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder
  ```
- Firewall is blocking mDNS. This is rare on macOS since mDNSResponder is exempt, but check if a third-party firewall is interfering.

### Cron not running

**Symptom:** Peer status is not updating. `ping.log` has no recent entries.

**Fix:** Verify the cron entry exists:

```bash
crontab -l 2>/dev/null | grep 'claw-clan'
```

If missing, reinstall it:

```bash
(crontab -l 2>/dev/null | grep -v 'claw-ping.sh'; \
  echo "*/15 * * * * ${HOME}/.openclaw/claw-clan/scripts/claw-ping.sh >> ${HOME}/.openclaw/claw-clan/logs/ping.log 2>&1 # claw-clan") | crontab -
```

Also verify that cron has Full Disk Access in System Settings > Privacy & Security > Full Disk Access. On modern macOS, cron may be restricted without this.

### LaunchAgent not starting

**Symptom:** `claw-register.sh status` reports the LaunchAgent is not running.

**Fix:** Check for plist errors:

```bash
plutil -lint ~/Library/LaunchAgents/com.openclaw.claw-clan-mdns.plist
```

If the plist is valid, try reloading:

```bash
launchctl bootout gui/$(id -u)/com.openclaw.claw-clan-mdns 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.claw-clan-mdns.plist
```

Check LaunchAgent logs for errors:

```bash
cat ~/.openclaw/claw-clan/logs/mdns-register-err.log
```

### Peer shows as offline but machine is running

**Symptom:** A peer is marked `offline` in its JSON file but the machine is online and responsive.

**Possible causes:**
- SSH connectivity lost (password changed, key removed, firewall rule added). Test directly:
  ```bash
  ssh -o ConnectTimeout=5 -o BatchMode=yes <user>@<ip> "echo test"
  ```
- The peer's IP address changed (DHCP). Run `claw-discover.sh` to get the updated IP from mDNS.
- The ping timeout (30 seconds) is too short for the network. Adjust `CLAW_PING_TIMEOUT` in `lib/common.sh`.

### Removing all claw-clan cron entries

```bash
crontab -l 2>/dev/null | grep -v 'claw-clan' | crontab -
```

---

## License

TBD
