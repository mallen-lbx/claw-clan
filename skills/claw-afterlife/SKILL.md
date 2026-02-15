---
name: claw-afterlife
description: OpenClaw fleet health monitoring and recovery. Monitor peer status, leader election, offline notifications, skill reinstallation, cron job management for OpenClaw instances
metadata:
  openclaw:
    requires:
      bins: ["ssh", "crontab", "jq"]
    os: [darwin, linux]
---

# Claw-Afterlife: OpenClaw Fleet Health & Recovery

Monitor OpenClaw fleet health, manage leader election, handle offline/online transitions, and coordinate skill reinstallation across instances.

**Prerequisite**: claw-clan must be set up first (state.json must exist).

## Leader Election

The instance with the **lowest lead number** is the leader. Leadership is static (set at setup).

Determine if this instance is leader:

```bash
MY_LEAD=$(jq -r '.leadNumber' ~/.openclaw/claw-clan/state.json)
LOWEST_LEAD=$MY_LEAD

for f in ~/.openclaw/claw-clan/peers/*.json; do
  [[ -f "$f" ]] || continue
  peer_status=$(jq -r '.status' "$f")
  peer_lead=$(jq -r '.leadNumber' "$f")
  # Only consider online peers
  if [[ "$peer_status" == "online" && "$peer_lead" -lt "$LOWEST_LEAD" ]]; then
    LOWEST_LEAD=$peer_lead
  fi
done

if [[ "$MY_LEAD" -le "$LOWEST_LEAD" ]]; then
  echo "This instance IS the leader (lead=$MY_LEAD)"
  IS_LEADER=true
else
  echo "This instance is NOT the leader (lead=$MY_LEAD, leader=$LOWEST_LEAD)"
  IS_LEADER=false
fi
```

## Offline Detection

After running `claw-ping.sh`, check for peers that have gone offline (missed >= threshold pings):

```bash
THRESHOLD=$(jq -r '.offlineThresholdPings // 2' ~/.openclaw/claw-clan/config.json)

for f in ~/.openclaw/claw-clan/peers/*.json; do
  [[ -f "$f" ]] || continue
  status=$(jq -r '.status' "$f")
  name=$(jq -r '.name' "$f")
  gateway=$(jq -r '.gatewayId' "$f")
  last_seen=$(jq -r '.lastSeen' "$f")
  last_ping=$(jq -r '.lastPingAttempt' "$f")

  if [[ "$status" == "offline" ]]; then
    echo "OpenClaw \"$name\" ($gateway) has gone OFFLINE."
    echo "Last seen: $last_seen"
    echo "Last ping attempt: $last_ping"
  fi
done
```

When a peer is detected offline, present the user with options:

1. **Monitor continuously** — Start a 5-minute cron job to watch for recovery
2. **Ignore** — Acknowledge and stop alerting

## Start Continuous Monitoring

Only the leader should do this. Create a dedicated cron job for the offline peer:

```bash
GATEWAY_ID="<offline-gateway-id>"
SCRIPTS_DIR="${HOME}/.openclaw/claw-clan/scripts"
MONITOR_INTERVAL=$(jq -r '.monitorIntervalMinutes // 5' ~/.openclaw/claw-clan/config.json)

# Add monitoring cron (avoid duplicates)
(crontab -l 2>/dev/null | grep -v "claw-monitor.sh ${GATEWAY_ID}"; \
 echo "*/${MONITOR_INTERVAL} * * * * ${SCRIPTS_DIR}/claw-monitor.sh ${GATEWAY_ID} >> ${HOME}/.openclaw/claw-clan/logs/monitor.log 2>&1 # claw-clan-monitor-${GATEWAY_ID}") | crontab -

echo "Monitoring started for ${GATEWAY_ID} (every ${MONITOR_INTERVAL} minutes)"
```

## Handle Recovery

When `claw-monitor.sh` detects a peer is back, it:
1. Updates peer status to `online`
2. Removes its own monitoring cron job
3. Writes a recovery report to `~/.openclaw/claw-clan/logs/recovery-<gateway-id>.json`

Read the recovery report and present to user:

```bash
GATEWAY_ID="<recovered-gateway-id>"
REPORT="${HOME}/.openclaw/claw-clan/logs/recovery-${GATEWAY_ID}.json"

if [[ -f "$REPORT" ]]; then
  name=$(jq -r '.name' "$REPORT")
  gateway=$(jq -r '.gatewayId' "$REPORT")
  downtime=$(jq -r '.downtime' "$REPORT")
  gw_responding=$(jq -r '.gatewayResponding' "$REPORT")
  state_exists=$(jq -r '.clawStateExists' "$REPORT")
  cron_active=$(jq -r '.clawCronActive' "$REPORT")

  echo "OpenClaw \"$name\" ($gateway) is back ONLINE."
  echo "The Gateway $gw_responding responding to ping (are-you-on-claw-clan)."
  echo "Downtime: $downtime"
  echo ""
  echo "claw-clan status on $name:"
  echo "  - State file: $([ "$state_exists" = "true" ] && echo "installed" || echo "MISSING")"
  echo "  - Cron jobs:  $([ "$cron_active" = "true" ] && echo "active" || echo "MISSING")"
  echo ""
  echo ""

  if [[ "$state_exists" == "true" && "$cron_active" == "true" ]]; then
    echo "  claw-clan appears fully functional. Options:"
    echo "  1. Update scripts (push latest scripts, preserve state)"
    echo "  2. Ignore (peer is operational)"
  elif [[ "$state_exists" == "true" ]]; then
    echo "  claw-clan state exists but cron is missing. Options:"
    echo "  1. Repair (reinstall scripts + cron, preserve state)"
    echo "  2. Full reinstall (re-run remote install from scratch)"
    echo "  3. Ignore"
  else
    echo "  claw-clan is NOT installed on this peer. Options:"
    echo "  1. Install remotely (first-time push of claw-clan)"
    echo "  2. Ignore (peer will be tracked but one-directional only)"
  fi
fi
```

## Install or Reinstall claw-clan on Peer

Use `claw-remote-install.sh` for both first-time installs and reinstalls. The script auto-detects which scenario applies:

- **First-time install** (no `state.json` on remote): Creates full setup — directories, scripts, state.json, config.json, mDNS, cron, and adds this machine as a peer on the remote
- **Reinstall/update** (existing `state.json`): Pushes latest scripts and skills but preserves existing state.json and configuration

```bash
GATEWAY_ID="<gateway-id>"
PEER_FILE="${HOME}/.openclaw/claw-clan/peers/${GATEWAY_ID}.json"
PEER_IP=$(jq -r '.ip' "$PEER_FILE")
PEER_USER=$(jq -r '.sshUser' "$PEER_FILE")
PEER_NAME=$(jq -r '.name' "$PEER_FILE")

# Remote install handles both first-time and reinstall automatically
~/.openclaw/claw-clan/scripts/claw-remote-install.sh "$PEER_USER" "$PEER_IP" "$PEER_NAME" "$GATEWAY_ID"
```

### First-Time Remote Install Details

When `state.json` does not exist on the remote, `claw-remote-install.sh` will:
1. Create directory structure (`~/.openclaw/claw-clan/{peers,logs,scripts/lib,migrations}`)
2. Push all scripts and lib files via `scp`
3. Push claw-clan and claw-afterlife skills
4. Generate `state.json` with defaults (lead=99, gateway=hostname)
5. Generate `config.json` with default settings
6. Add THIS machine as a peer on the remote (bidirectional)
7. Register mDNS on the remote (macOS via LaunchAgent, Linux via systemd)
8. Install keep-alive cron (every 15 minutes)
9. Update local peer file with `clawClanInstalled=true`

The remote peer's OpenClaw agent can later refine settings by running `claw-clan setup`.

### Script Update (Reinstall) Details

When `state.json` already exists, `claw-remote-install.sh` will:
1. Push latest scripts and skills (overwriting old versions)
2. Restart mDNS registration
3. Ensure cron is installed
4. Preserve existing state.json and config.json

## Sync Skills from GitHub

After recovery, sync shared skills:

```bash
~/.openclaw/claw-clan/scripts/claw-sync-skills.sh <gateway-id>
```

Or sync to all online peers:

```bash
~/.openclaw/claw-clan/scripts/claw-sync-skills.sh all
```

## Switch to PostgreSQL Backend

Switch storage from JSON to PostgreSQL at any time.

### Option A: Use existing PostgreSQL

```bash
# Update config
jq '.backend = "postgres" | .postgres.host = "<host>" | .postgres.port = <port> | .postgres.database = "<db>" | .postgres.user = "<user>" | .postgres.password = "<pass>"' \
  ~/.openclaw/claw-clan/config.json > /tmp/config.json && mv /tmp/config.json ~/.openclaw/claw-clan/config.json

# Run migrations
psql -h <host> -p <port> -U <user> -d <db> -f ~/.openclaw/claw-clan/migrations/001-initial-schema.sql
```

### Option B: Deploy new PostgreSQL via Docker

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

# Capture connection info
echo "Host: $(hostname -I | awk '{print $1}')"
echo "Port: 5432"
echo "Database: claw_clan"
echo "User: claw"
echo "Password: <generated above>"
```

### Option C: Deploy via Portainer

Use the Portainer API to create a stack. See reference: `references/postgres-setup.md`.

After deployment:
1. Display DB connection info to user for safekeeping
2. Distribute config to all online agents via SSH
3. Save to claw-afterlife state for recovery

## Cron Job Management

List all claw-clan cron entries:

```bash
crontab -l 2>/dev/null | grep 'claw-clan'
```

Remove all claw-clan cron entries:

```bash
crontab -l 2>/dev/null | grep -v 'claw-clan' | crontab -
```

Remove monitoring cron for a specific peer:

```bash
crontab -l 2>/dev/null | grep -v "claw-monitor.sh <gateway-id>" | crontab -
```
