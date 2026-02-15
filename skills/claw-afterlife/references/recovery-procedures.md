# Recovery Procedures Reference

## Overview

Recovery is the process of detecting that a previously offline peer has come back online, verifying its claw-clan installation, notifying the user, and optionally reinstalling or syncing skills. Only the leader instance performs recovery actions.

## Recovery Detection

Recovery is detected by `claw-monitor.sh`, which runs as a cron job on the leader instance. When a peer goes offline and the user chooses to monitor it, a dedicated cron entry is created that runs `claw-monitor.sh <gateway-id>` at the configured interval (default: every 5 minutes).

Each monitoring cycle:
1. Attempts an SSH connection to the peer (`ssh <user>@<ip> "echo 'claw-clan-ack ...'"`)
2. Checks for mDNS presence via `dns-sd -B _openclaw._tcp local` (3-second timeout)
3. If SSH succeeds, the peer is considered recovered

The SSH check is the primary recovery signal. mDNS is supplementary and is used to determine whether the gateway is broadcasting.

## Recovery Report Schema

When recovery is detected, `claw-monitor.sh` writes a JSON report to:

```
~/.openclaw/claw-clan/logs/recovery-<gateway-id>.json
```

The report contains:

```json
{
  "gatewayId": "gw-abc123",
  "name": "Studio Mac",
  "recoveredAt": "2025-05-10T14:30:00Z",
  "downtime": "2h 15m",
  "sshResponding": true,
  "mdnsBroadcasting": true,
  "gatewayResponding": "is",
  "clawClanInstalled": true,
  "clawStateExists": true,
  "clawCronActive": true
}
```

### Field Descriptions

| Field | Type | Description |
|---|---|---|
| `gatewayId` | string | The unique gateway identifier of the recovered peer |
| `name` | string | Human-readable name of the peer |
| `recoveredAt` | string (ISO 8601) | UTC timestamp of when recovery was detected |
| `downtime` | string | Human-readable duration (e.g., `"2h 15m"`) since the peer was last seen. `"unknown"` if the previous `lastSeen` timestamp is unavailable |
| `sshResponding` | boolean | Whether the SSH ping returned a valid `claw-clan-ack` response |
| `mdnsBroadcasting` | boolean | Whether the peer's name appeared in a `dns-sd -B` browse |
| `gatewayResponding` | string | `"is"` if mDNS broadcasting is true, `"is not"` otherwise. Used directly in the notification message |
| `clawClanInstalled` | boolean | `true` if both `clawStateExists` and `clawCronActive` are true |
| `clawStateExists` | boolean | Whether `~/.openclaw/claw-clan/state.json` exists on the remote peer |
| `clawCronActive` | boolean | Whether the remote peer has claw-clan cron entries |

## Notification Message Format

When presenting recovery to the user, use this format:

```
OpenClaw "<name>" (<gatewayId>) is back ONLINE.
The Gateway <is/is not> responding to ping (are-you-on-claw-clan).
Downtime: <downtime>

claw-clan status on <name>:
  - State file: installed | MISSING
  - Cron jobs:  active | MISSING

Options:
  1. Reinstall claw-clan (re-run setup on remote)
  2. Ignore (peer is functional)
```

The `<is/is not>` value comes directly from the `gatewayResponding` field in the recovery report. The Gateway ping referenced here is the mDNS `_openclaw._tcp` service check, which is the mechanism peers use to discover each other (`are-you-on-claw-clan` is the conceptual name for this broadcast).

## Installation Check on Recovered Peer

After SSH connectivity is confirmed, `claw-monitor.sh` runs two checks on the remote peer via SSH:

### 1. State File Exists

```bash
ssh ${CLAW_SSH_OPTS} "${peer_user}@${peer_ip}" \
  "test -f ~/.openclaw/claw-clan/state.json && echo 'yes' || echo 'no'"
```

This verifies the claw-clan state file is present. If missing, the peer was either never set up or had its configuration wiped.

### 2. Cron Entries Present

```bash
ssh ${CLAW_SSH_OPTS} "${peer_user}@${peer_ip}" \
  "crontab -l 2>/dev/null | grep -c 'claw-clan' || echo '0'"
```

This counts claw-clan cron entries. A value greater than 0 means the peer's cron jobs (ping cycle, etc.) are still installed.

### 3. mDNS Broadcasting

Checked locally on the leader (not via SSH) using:

```bash
timeout 3 dns-sd -B _openclaw._tcp local
```

The output is scanned for the peer's name. This tells you whether the peer's mDNS LaunchAgent is running and advertising its `_openclaw._tcp` service.

### Combined Assessment

`clawClanInstalled` is `true` only when both `clawStateExists` and `clawCronActive` are true. If either is missing, the peer needs reinstallation.

## Reinstallation Procedure

If the user chooses to reinstall, the leader performs these steps over SSH:

### Step 1: Copy Scripts to Remote

```bash
GATEWAY_ID="<gateway-id>"
PEER_FILE="${HOME}/.openclaw/claw-clan/peers/${GATEWAY_ID}.json"
PEER_IP=$(jq -r '.ip' "$PEER_FILE")
PEER_USER=$(jq -r '.sshUser' "$PEER_FILE")

scp -r ~/.openclaw/claw-clan/scripts/ "${PEER_USER}@${PEER_IP}:~/.openclaw/claw-clan/scripts/"
```

This copies the full scripts directory (including `lib/`) to the remote peer, ensuring it has the latest versions.

### Step 2: Restart mDNS Registration

```bash
ssh "${PEER_USER}@${PEER_IP}" "~/.openclaw/claw-clan/scripts/claw-register.sh restart"
```

This unloads the existing LaunchAgent (if any), then reinstalls and reloads it. The peer will resume broadcasting its `_openclaw._tcp` mDNS service.

### Step 3: Reinstall Cron

```bash
ssh "${PEER_USER}@${PEER_IP}" bash <<'REMOTE'
(crontab -l 2>/dev/null | grep -v 'claw-ping.sh'; \
 echo "*/15 * * * * ${HOME}/.openclaw/claw-clan/scripts/claw-ping.sh >> ${HOME}/.openclaw/claw-clan/logs/ping.log 2>&1 # claw-clan") | crontab -
REMOTE
```

This removes any existing claw-ping cron entry (to avoid duplicates), then installs a fresh one. The `# claw-clan` comment tag at the end is used for identification and cleanup.

## Skill Sync After Recovery

After recovery (and optionally after reinstallation), sync shared skills from the configured GitHub repo:

### Sync to a Specific Peer

```bash
~/.openclaw/claw-clan/scripts/claw-sync-skills.sh <gateway-id>
```

### Sync to All Online Peers

```bash
~/.openclaw/claw-clan/scripts/claw-sync-skills.sh all
```

`claw-sync-skills.sh` performs these actions:
1. Syncs the local skills directory first (`git pull` or `git clone` from the configured `githubRepo`).
2. SSHs to the target peer(s) and runs `git pull` (or `git clone` if the skills directory does not exist).
3. Only targets peers with `status == "online"` when using `all`.

## Monitoring Cron Cleanup

The monitoring cron job is self-removing. When `claw-monitor.sh` detects recovery (SSH responds), it removes its own cron entry:

```bash
crontab -l 2>/dev/null | grep -v "claw-monitor.sh ${TARGET_GATEWAY}" | crontab -
```

This ensures monitoring stops automatically once the peer is confirmed back online. No manual cleanup is needed.

To verify that a monitoring cron has been removed:

```bash
crontab -l 2>/dev/null | grep "claw-monitor.sh"
```

If no output, all monitoring jobs have self-cleaned.

## Manual Recovery

If automated recovery fails (SSH keys changed, IP changed, network misconfigured), follow these manual steps:

### 1. Verify Network Connectivity

```bash
ping <peer-ip>
```

If the IP has changed, update the peer file:

```bash
jq --arg ip "<new-ip>" '.ip = $ip' ~/.openclaw/claw-clan/peers/<gateway-id>.json > /tmp/peer.json \
  && mv /tmp/peer.json ~/.openclaw/claw-clan/peers/<gateway-id>.json
```

### 2. Fix SSH Access

If SSH keys have changed or `BatchMode=yes` is failing:

```bash
# Remove old host key
ssh-keygen -R <peer-ip>

# Test SSH manually (will prompt for confirmation)
ssh <user>@<peer-ip> echo "ok"
```

### 3. Run Installation Steps Manually

SSH to the peer and run each step interactively:

```bash
ssh <user>@<peer-ip>

# On the remote peer:
ls ~/.openclaw/claw-clan/state.json          # Check state
crontab -l | grep claw-clan                   # Check cron
~/.openclaw/claw-clan/scripts/claw-register.sh status  # Check mDNS
```

### 4. Update Peer Status Locally

After manual verification, update the peer file to reflect the current state:

```bash
jq --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '.status = "online" | .lastSeen = $now | .missedPings = 0 | .sshConnectivity = true' \
  ~/.openclaw/claw-clan/peers/<gateway-id>.json > /tmp/peer.json \
  && mv /tmp/peer.json ~/.openclaw/claw-clan/peers/<gateway-id>.json
```

### 5. Remove Stale Monitoring Cron

If the monitoring cron is still running for this peer, remove it:

```bash
crontab -l 2>/dev/null | grep -v "claw-monitor.sh <gateway-id>" | crontab -
```

### 6. Trigger Skill Sync

```bash
~/.openclaw/claw-clan/scripts/claw-sync-skills.sh <gateway-id>
```
