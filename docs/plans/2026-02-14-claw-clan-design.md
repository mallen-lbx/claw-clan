# Claw-Clan Design Document

**Date**: 2026-02-14
**Status**: Approved
**Approach**: Skill-Based Architecture (OpenClaw skills + bash scripts)

## Problem Statement

Multiple OpenClaw instances running on a LAN need to discover each other, monitor health, coordinate recovery, and share skills/plugins. There is no existing mechanism for inter-instance awareness or coordination.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | OpenClaw skills + bash scripts | Native to OpenClaw's extension model, no extra infrastructure |
| Discovery | mDNS/Bonjour (`_openclaw._tcp`) | Zero-config LAN discovery, native on macOS |
| Communication | SSH | Already available, secure, reliable on LAN |
| Default storage | JSON files | Sufficient for small fleet, no dependencies |
| Optional storage | PostgreSQL | For historical data, switchable at any time |
| Fleet manifest | GitHub private repo | Durable record, also distributes shared skills |
| Health checks | Cron-driven (not sub-agents) | Free, persistent, no API token cost |
| Network scope | LAN only | No tunneling, port forwarding, or public infrastructure |
| Sub-agent model | Background processes only | Persistent across sessions, relevant to coordination |

## System Overview

```
┌─────────────────────────────────────────────────────┐
│                   claw-clan                       │
├─────────────────────┬───────────────────────────────┤
│   Skills (2)        │   Scripts (4+)                 │
│                     │                                │
│  claw-clan       │  claw-register.sh   (mDNS)    │
│  - Setup/config     │  claw-discover.sh   (mDNS)    │
│  - SSH key mgmt     │  claw-ping.sh       (cron)    │
│  - Fleet manifest   │  claw-monitor.sh    (leader)  │
│  - Peer discovery   │  claw-setup-ssh.sh  (keys)    │
│                     │  claw-sync-skills.sh (git)    │
│  claw-afterlife         │                                │
│  - Health monitor   │   State                        │
│  - Leader election  │  ~/.openclaw/claw-clan/     │
│  - Offline alerts   │    state.json     (runtime)    │
│  - Cron management  │    fleet.json     (manifest)   │
│  - Plugin reinstall │    config.json    (settings)   │
│                     │    peers/         (per-peer)   │
├─────────────────────┴───────────────────────────────┤
│   Storage Backend (pluggable)                        │
│   [JSON files] <-- default                           │
│   [PostgreSQL] <-- optional, for historical data     │
├──────────────────────────────────────────────────────┤
│   External                                           │
│   GitHub repo  -- fleet manifest + shared skills     │
│   mDNS/Bonjour -- LAN service discovery              │
│   SSH          -- inter-instance communication       │
│   cron         -- scheduled keep-alive pings         │
└──────────────────────────────────────────────────────┘
```

## Instance Identity

Each OpenClaw instance is identified by:

- **Gateway ID**: Machine identifier (hostname or user-assigned, e.g., `macbook-pro-01`)
- **Name**: Human-friendly name (e.g., `"Dev Station"`)
- **Lead Number**: Priority for leader election (1 = highest priority, assigned during setup)
- **LAN IP**: Auto-detected or manually configured
- **SSH User**: Username for SSH connections

## Component Design

### Skill: claw-clan

**Purpose**: Discovery, setup, SSH management, fleet coordination.

**Frontmatter**:
```yaml
---
name: claw-clan
description: OpenClaw peer discovery and coordination. Setup claw-clan, discover peers on LAN, manage fleet, configure SSH between OpenClaw instances, keep-alive monitoring
metadata:
  openclaw:
    requires:
      bins: ["ssh", "ssh-keygen"]
    os: darwin
---
```

**Setup flow (first run)**:

1. Assign identity: prompt for gateway ID (default: hostname) and friendly name
2. Assign lead number: user picks 1, 2, 3... Warn if already taken in fleet
3. Configure GitHub repo: user provides private repo URL (optional, can add later)
4. Register via mDNS: broadcast `_openclaw._tcp` service with TXT records
5. Discover peers: browse mDNS for other `_openclaw._tcp` services
6. SSH connectivity check: attempt SSH to each discovered peer
7. Handle SSH failures: provide user with key exchange instructions
8. Install keep-alive cron: 15-minute interval for `claw-ping.sh`
9. Push fleet manifest: update `fleet.json` in GitHub repo (if configured)

**SSH failure handling**:

When SSH to a peer fails, output:
```
Cannot SSH to <name> (<gateway>) at <ip>.
To enable claw-clan connectivity, run these commands on THIS machine:

  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  ssh-copy-id -i ~/.ssh/id_ed25519.pub <username>@<lan-ip>

Then run these commands on <name> (<ip>):

  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  ssh-copy-id -i ~/.ssh/id_ed25519.pub <your-username>@<your-ip>

After both machines have exchanged keys, run: claw-clan verify
```

### Keep-Alive Ping Protocol

Every 15 minutes (cron-driven):

1. For each known peer, SSH in and run: `echo "are-you-on-claw-clan $(hostname) $(date +%s)"`
2. Peer responds with: `claw-clan-ack <gateway-id> <timestamp>`
3. On response: reset that peer's "last seen" timer in local state
4. On timeout (30 seconds): mark peer as "unresponsive" in local state
5. Multiple pings can be accepted simultaneously (separate SSH connections)

### mDNS Service Registration

- **Service type**: `_openclaw._tcp`
- **Port**: 22 (SSH)
- **TXT records**: `gateway=<id>`, `name=<name>`, `lead=<number>`, `version=<version>`
- **macOS**: `dns-sd -R` for registration, `dns-sd -B` for browsing
- **Linux**: `avahi-publish-service` / `avahi-browse` (gated dependency)

### Skill: claw-afterlife

**Purpose**: Health monitoring, leader election, offline notification, recovery.

**Frontmatter**:
```yaml
---
name: claw-afterlife
description: OpenClaw fleet health monitoring and recovery. Monitor peer status, leader election, offline notifications, skill reinstallation, cron job management for OpenClaw instances
metadata:
  openclaw:
    requires:
      bins: ["ssh", "crontab"]
    os: darwin
---
```

**Leader election**:

- Instance with lowest lead number is leader
- Static assignment (set during setup, not dynamic)
- If leader goes offline, next-lowest number becomes acting leader
- Original leader reclaims on return (lowest always wins)

**Offline detection**:

After 2 consecutive missed pings (30 minutes):

1. Mark peer as `offline`
2. Notify operator:
   ```
   OpenClaw "<name>" (<gateway>) has gone OFFLINE.
   Last seen: <timestamp>
   Last ping attempt: <timestamp>
   ```
3. Offer options:
   - Monitor continuously (creates 5-minute cron job)
   - Ignore (acknowledge, stop alerting)

**Continuous monitoring** (if requested):

- Dedicated cron job: `*/5 * * * * claw-monitor.sh <gateway-id>`
- Attempts SSH ping every 5 minutes
- Checks mDNS for service reappearing
- Logs to `~/.openclaw/claw-clan/logs/monitor.log`
- Cron job only, no Claude Code sub-agent

**Online recovery** (when peer returns):

1. Kill the monitoring cron job (self-cleanup)
2. Notify operator:
   ```
   OpenClaw "<name>" (<gateway>) is back ONLINE.
   The Gateway <is/is not> responding to ping (are-you-on-claw-clan).
   Downtime: <duration>
   ```
3. Check plugin installation on recovered peer via SSH:
   - Verify `~/.openclaw/claw-clan/state.json` exists
   - Verify mDNS service registration
   - Verify keep-alive cron entry
4. Offer reinstallation:
   ```
   claw-clan status on <name>:
   - Skills: [installed/missing]
   - Cron: [active/missing]
   - mDNS: [broadcasting/silent]

   Options:
   1. Reinstall claw-clan
   2. Ignore
   ```
5. Sync skills from GitHub repo (if configured):
   ```bash
   ssh <user>@<ip> "cd ~/.openclaw/skills && git pull origin main"
   ```

## Storage Backend

### JSON File Backend (Default)

```
~/.openclaw/claw-clan/
├── state.json          # This instance's identity
├── fleet.json          # Fleet manifest (all known instances)
├── config.json         # Backend settings, repo URL
├── peers/
│   └── <gateway-id>.json  # Per-peer status and ping history
├── scripts/            # Runtime scripts
└── logs/
    └── monitor.log     # Monitoring activity
```

### PostgreSQL Backend (Optional)

Switchable at any time. Data migrates automatically from JSON to Postgres.

**Setup flow**:

1. User chooses "switch to postgres"
2. Existing deployment? Provide host/port/db/user/pass
3. No existing deployment? Auto-deploy via Docker or Portainer
4. Test connection, run migrations, migrate JSON data
5. Display DB connection info for safekeeping
6. Distribute connection info to all online agents via SSH
7. Save to claw-afterlife state for recovery scenarios

**Postgres stores** (when enabled):

- Fleet registry
- Ping history (timestamped)
- Incident log (offline/online events)
- Skill installation audit trail
- Leader election history

**Environment variables**: `CLAW_PG_HOST`, `CLAW_PG_PORT`, `CLAW_PG_DB`, `CLAW_PG_USER`, `CLAW_PG_PASS`

## State Schemas

### state.json

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

### peers/<gateway-id>.json

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

## Project File Structure

```
claw-clan/
├── skills/
│   ├── claw-clan/
│   │   ├── SKILL.md
│   │   └── references/
│   │       ├── setup-guide.md
│   │       ├── ssh-troubleshooting.md
│   │       └── mdns-reference.md
│   └── claw-afterlife/
│       ├── SKILL.md
│       └── references/
│           ├── leader-election.md
│           ├── recovery-procedures.md
│           └── postgres-setup.md
├── scripts/
│   ├── claw-register.sh
│   ├── claw-discover.sh
│   ├── claw-ping.sh
│   ├── claw-monitor.sh
│   ├── claw-setup-ssh.sh
│   ├── claw-sync-skills.sh
│   └── lib/
│       ├── storage.sh
│       ├── storage-json.sh
│       ├── storage-postgres.sh
│       └── common.sh
├── migrations/
│   └── 001-initial-schema.sql
└── docs/
    └── plans/
        └── 2026-02-14-claw-clan-design.md
```

## Dependencies

### Required (gated)

- `ssh` — inter-instance communication
- `ssh-keygen` — key generation for setup
- `crontab` — scheduled keep-alive pings

### Platform-specific

- **macOS**: `dns-sd` (built-in) for mDNS
- **Linux**: `avahi-daemon`, `avahi-browse`, `avahi-publish` (gated)

### Optional

- `docker` — PostgreSQL auto-deployment
- `gh` — GitHub CLI for repo operations
- `psql` — PostgreSQL client (when backend enabled)
- `jq` — JSON processing in scripts
