---
name: claw-clan
description: OpenClaw peer discovery and coordination. Setup claw-clan, discover peers on LAN, manage fleet, configure SSH between OpenClaw instances, keep-alive monitoring
metadata:
  openclaw:
    requires:
      bins: ["ssh", "ssh-keygen", "jq"]
    os: [darwin, linux]
---

# Claw-Clan: OpenClaw Peer Discovery & Coordination

Manage multi-instance OpenClaw coordination on a LAN. Discover peers via mDNS, verify SSH connectivity, maintain fleet state, and run keep-alive health checks.

## Scripts Location

All scripts are in the claw-clan installation directory. Find them:
```bash
CLAW_SCRIPTS="$(dirname "$(readlink -f "$(which claw-register.sh 2>/dev/null || echo "${HOME}/.openclaw/claw-clan/scripts/claw-register.sh")")")"
```

Or default: `~/.openclaw/claw-clan/scripts/`

## First-Time Setup

Run setup interactively. Collect from the user:

1. **Gateway ID** — unique machine identifier (default: `$(hostname)`)
2. **Friendly name** — human-readable name for this instance
3. **Lead number** — priority number (1 = highest, used for leader election in claw-afterlife)
4. **SSH user** — username for SSH connections (default: `$(whoami)`)
5. **GitHub repo** — private repo URL for shared skills (optional, can add later)

After collecting, create the state directory and files:

```bash
mkdir -p ~/.openclaw/claw-clan/{peers,logs}

# Write state.json
jq -n \
  --arg gid "<gateway-id>" \
  --arg name "<friendly-name>" \
  --argjson lead <lead-number> \
  --arg ip "$(case $(uname -s) in Darwin) ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null;; Linux) hostname -I 2>/dev/null | awk '{print $1}';; esac)" \
  --arg user "<ssh-user>" \
  --arg repo "<github-repo-or-null>" \
  '{
    gatewayId: $gid,
    name: $name,
    leadNumber: $lead,
    ip: $ip,
    sshUser: $user,
    version: "1.0.0",
    registeredAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
    githubRepo: $repo
  }' > ~/.openclaw/claw-clan/state.json

# Write default config
jq -n '{
  backend: "json",
  pingIntervalMinutes: 15,
  offlineThresholdPings: 2,
  monitorIntervalMinutes: 5,
  postgres: {host: null, port: 5432, database: "claw_clan", user: null, password: null, deployed: false, deployMethod: null}
}' > ~/.openclaw/claw-clan/config.json
```

Then run these scripts in order:

```bash
# 1. Register on mDNS (macOS: LaunchAgent, Linux: systemd user service)
~/.openclaw/claw-clan/scripts/claw-register.sh start

# 2. Discover peers via mDNS
~/.openclaw/claw-clan/scripts/claw-discover.sh
```

### Step 3: SSH Peer Setup

After mDNS discovery, check if any peers were found. Then ask the user:

**"Do you have other OpenClaw instances on this network you want to connect to?"**

Options:
1. **Yes, add a peer** — prompt for username and LAN IP (see below)
2. **No, skip for now** — continue to cron setup (peers can be added later)
3. **Peers were already found via mDNS** — skip prompting, just verify SSH to discovered peers

If the user chooses to add a peer, collect:

1. **Username** — SSH username on the remote machine (e.g., `mallen`)
2. **LAN IP** — the peer's IP address on the local network (e.g., `192.168.1.101`)
3. **Friendly name** — optional, human-readable name (e.g., `Build Box`)
4. **Gateway ID** — optional, defaults to `peer-<ip>` (e.g., `peer-192-168-1-101`)

Then run:

```bash
~/.openclaw/claw-clan/scripts/claw-setup-ssh.sh add <username> <ip> [name] [gateway-id]
```

This will:
- Ensure an SSH key exists (generate if not — skips if `~/.ssh/id_ed25519` already exists)
- Test SSH to `<username>@<ip>`
- Create a peer file in `~/.openclaw/claw-clan/peers/`
- Check if claw-clan is installed on the remote peer
- Output: `SSH_STATUS=success|failed` and `CLAW_INSTALLED=true|false|unknown`

### Step 3b: Remote Install (if peer lacks claw-clan)

After adding a peer, check the output for `CLAW_INSTALLED=false`. If SSH succeeded but claw-clan is not installed, ask the user:

**"[peer-name] doesn't have claw-clan installed. Would you like to install it remotely?"**

Options:
1. **Yes, install remotely** — push scripts, create state, register mDNS, install cron
2. **No, skip** — peer will still be tracked but only one-directional monitoring

If the user chooses remote install:

```bash
~/.openclaw/claw-clan/scripts/claw-remote-install.sh <username> <ip> [name] [gateway-id] [lead-number]
```

This will:
- Push all claw-clan scripts and skills to the remote via `scp`
- Generate `state.json` and `config.json` with sensible defaults (lead=99)
- Add THIS machine as a peer on the remote (bidirectional relationship)
- Register mDNS on the remote (macOS via LaunchAgent, Linux via systemd)
- Install the keep-alive cron on the remote
- Update the local peer file with `clawClanInstalled=true`

The remote peer gets default settings. Its OpenClaw agent can later refine them by running `claw-clan setup` (which will detect existing state and offer reconfiguration without losing scripts).

After the first peer, ask: **"Add another peer, or continue setup?"**

Repeat until the user is done, then verify all peers:

```bash
~/.openclaw/claw-clan/scripts/claw-setup-ssh.sh check
```

Finally, install the keep-alive cron:

```bash
# Install keep-alive cron (every 15 minutes)
(crontab -l 2>/dev/null | grep -v 'claw-ping.sh'; echo "*/15 * * * * ${HOME}/.openclaw/claw-clan/scripts/claw-ping.sh >> ${HOME}/.openclaw/claw-clan/logs/ping.log 2>&1 # claw-clan") | crontab -
```

## SSH Failure Handling

When SSH to a peer fails, provide these instructions:

```
Cannot SSH to <name> (<gateway>) at <ip>.
To enable claw-clan connectivity:

On THIS machine (<my-name> / <my-gateway>):

  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  ssh-copy-id -i ~/.ssh/id_ed25519.pub <username>@<lan-ip>

On <name> (<ip>):

  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  ssh-copy-id -i ~/.ssh/id_ed25519.pub <my-username>@<my-ip>

After both machines have exchanged keys, run: claw-clan verify
```

After the user completes the key exchange, verify with:

```bash
~/.openclaw/claw-clan/scripts/claw-setup-ssh.sh test <username> <ip>
```

## Adding Peers Later

Peers can be added at any time after setup. Ask the agent: "Add a peer to claw-clan"

The agent will prompt for username and IP, then run:

```bash
~/.openclaw/claw-clan/scripts/claw-setup-ssh.sh add <username> <ip> [name] [gateway-id]
```

## Available Commands

| Command | Script | Purpose |
|---------|--------|---------|
| Register mDNS | `claw-register.sh start` | Broadcast service on LAN |
| Stop mDNS | `claw-register.sh stop` | Remove mDNS registration |
| Discover peers | `claw-discover.sh` | Browse LAN for OpenClaw instances |
| Add peer | `claw-setup-ssh.sh add <user> <ip> [name] [gw]` | Manually add a peer by username + IP |
| Remote install | `claw-remote-install.sh <user> <ip> [name] [gw] [lead]` | Push claw-clan to a peer via SSH |
| Check SSH | `claw-setup-ssh.sh check` | Test SSH to all known peers |
| Test SSH | `claw-setup-ssh.sh test <user> <ip>` | Test SSH to a specific host |
| Manual ping | `claw-ping.sh` | Send keep-alive to all peers |
| Sync skills | `claw-sync-skills.sh` | Pull/push skills from GitHub repo |

## Fleet Status

Read fleet state from JSON files:

```bash
# This instance
cat ~/.openclaw/claw-clan/state.json | jq .

# All peers
for f in ~/.openclaw/claw-clan/peers/*.json; do
  jq '{gatewayId, name, status, lastSeen, missedPings}' "$f"
done

# Quick status table
for f in ~/.openclaw/claw-clan/peers/*.json; do
  jq -r '[.name, .gatewayId, .status, .lastSeen] | @tsv' "$f"
done | column -t
```

## Peer Data Schema

Each peer file (`~/.openclaw/claw-clan/peers/<gateway-id>.json`):

```json
{
  "gatewayId": "string",
  "name": "string",
  "leadNumber": 0,
  "ip": "string",
  "sshUser": "string",
  "status": "online|offline|unresponsive",
  "lastSeen": "ISO-8601",
  "lastPingAttempt": "ISO-8601",
  "missedPings": 0,
  "sshConnectivity": true,
  "clawClanInstalled": true,
  "mdnsBroadcasting": true
}
```
