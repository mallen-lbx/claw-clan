# Claw-Clan Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an OpenClaw skill-based system for multi-instance LAN discovery, health monitoring, leader-driven recovery, and shared skill distribution.

**Architecture:** Two OpenClaw skills (claw-clan, claw-afterlife) backed by bash scripts. mDNS for zero-config discovery, SSH for communication, cron for keep-alive, JSON files for default storage with optional Postgres. A LaunchAgent persists mDNS registration across reboots.

**Tech Stack:** Bash scripts, macOS `dns-sd` (mDNS), SSH, cron, LaunchAgent plists, `jq` for JSON, optional PostgreSQL + Docker/Portainer.

**Design Doc:** `docs/plans/2026-02-14-claw-clan-design.md`

---

### Task 1: Project Structure & Shared Library

**Files:**
- Create: `scripts/lib/common.sh`
- Create: `scripts/lib/storage.sh`
- Create: `scripts/lib/storage-json.sh`

**Step 1: Create the project directory structure**

```bash
mkdir -p scripts/lib
mkdir -p skills/claw-clan/references
mkdir -p skills/claw-afterlife/references
mkdir -p migrations
```

**Step 2: Write `scripts/lib/common.sh` — shared constants, logging, validation**

```bash
#!/usr/bin/env bash
# common.sh — shared utilities for claw-clan scripts

set -euo pipefail

CLAW_DIR="${HOME}/.openclaw/claw-clan"
CLAW_STATE="${CLAW_DIR}/state.json"
CLAW_FLEET="${CLAW_DIR}/fleet.json"
CLAW_CONFIG="${CLAW_DIR}/config.json"
CLAW_PEERS_DIR="${CLAW_DIR}/peers"
CLAW_LOGS_DIR="${CLAW_DIR}/logs"
CLAW_VERSION="1.0.0"
CLAW_SERVICE_TYPE="_openclaw._tcp"
CLAW_LAUNCHAGENT_LABEL="com.openclaw.claw-clan-mdns"
CLAW_LAUNCHAGENT_PLIST="${HOME}/Library/LaunchAgents/${CLAW_LAUNCHAGENT_LABEL}.plist"
CLAW_CRON_TAG="# claw-clan"
CLAW_PING_TIMEOUT=30
CLAW_SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

log_info() { echo "[claw-clan] $(date '+%Y-%m-%d %H:%M:%S') INFO: $*"; }
log_warn() { echo "[claw-clan] $(date '+%Y-%m-%d %H:%M:%S') WARN: $*" >&2; }
log_error() { echo "[claw-clan] $(date '+%Y-%m-%d %H:%M:%S') ERROR: $*" >&2; }

ensure_dirs() {
  mkdir -p "${CLAW_DIR}" "${CLAW_PEERS_DIR}" "${CLAW_LOGS_DIR}"
}

require_bin() {
  local bin="$1"
  if ! command -v "$bin" &>/dev/null; then
    log_error "Required binary not found: $bin"
    return 1
  fi
}

require_state() {
  if [[ ! -f "${CLAW_STATE}" ]]; then
    log_error "claw-clan not initialized. Run setup first."
    return 1
  fi
}

get_state_field() {
  local field="$1"
  jq -r ".$field" "${CLAW_STATE}"
}

get_config_field() {
  local field="$1"
  local default="${2:-}"
  if [[ -f "${CLAW_CONFIG}" ]]; then
    jq -r ".$field // \"$default\"" "${CLAW_CONFIG}"
  else
    echo "$default"
  fi
}

get_lan_ip() {
  # Get primary LAN IP on macOS
  local ip
  ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")
  if [[ -z "$ip" ]]; then
    ip=$(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')
  fi
  echo "$ip"
}
```

**Step 3: Write `scripts/lib/storage.sh` — storage backend dispatcher**

```bash
#!/usr/bin/env bash
# storage.sh — pluggable storage backend dispatcher

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

_get_backend() {
  get_config_field "backend" "json"
}

# Load the appropriate backend
_load_backend() {
  local backend
  backend=$(_get_backend)
  case "$backend" in
    json)
      source "${SCRIPT_DIR}/storage-json.sh"
      ;;
    postgres)
      source "${SCRIPT_DIR}/storage-postgres.sh"
      ;;
    *)
      log_error "Unknown storage backend: $backend"
      return 1
      ;;
  esac
}

_load_backend

# Public API — all backends must implement:
# save_peer_status <gateway-id> <json-data>
# get_peer_status <gateway-id>
# get_all_peers
# save_fleet <json-data>
# get_fleet
# log_event <event-type> <json-data>  (postgres only, noop for json)
```

**Step 4: Write `scripts/lib/storage-json.sh` — JSON file backend**

```bash
#!/usr/bin/env bash
# storage-json.sh — JSON file storage backend

save_peer_status() {
  local gateway_id="$1"
  local json_data="$2"
  local peer_file="${CLAW_PEERS_DIR}/${gateway_id}.json"
  echo "$json_data" | jq '.' > "$peer_file"
}

get_peer_status() {
  local gateway_id="$1"
  local peer_file="${CLAW_PEERS_DIR}/${gateway_id}.json"
  if [[ -f "$peer_file" ]]; then
    cat "$peer_file"
  else
    echo "{}"
  fi
}

get_all_peers() {
  local result="[]"
  for peer_file in "${CLAW_PEERS_DIR}"/*.json; do
    [[ -f "$peer_file" ]] || continue
    result=$(echo "$result" | jq --slurpfile peer "$peer_file" '. + $peer')
  done
  echo "$result"
}

save_fleet() {
  local json_data="$1"
  echo "$json_data" | jq '.' > "${CLAW_FLEET}"
}

get_fleet() {
  if [[ -f "${CLAW_FLEET}" ]]; then
    cat "${CLAW_FLEET}"
  else
    echo '{"instances":[]}'
  fi
}

log_event() {
  # JSON backend: append to log file (not queryable, just for debugging)
  local event_type="$1"
  local json_data="$2"
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "{\"timestamp\":\"$timestamp\",\"event\":\"$event_type\",\"data\":$json_data}" >> "${CLAW_LOGS_DIR}/events.log"
}
```

**Step 5: Verify the scripts are syntactically valid**

Run: `bash -n scripts/lib/common.sh && bash -n scripts/lib/storage-json.sh && echo "OK"`
Expected: `OK`

**Step 6: Commit**

```bash
git add scripts/lib/common.sh scripts/lib/storage.sh scripts/lib/storage-json.sh
git commit -m "feat: add shared library and JSON storage backend for claw-clan"
```

---

### Task 2: mDNS Registration Script & LaunchAgent

**Files:**
- Create: `scripts/claw-register.sh`

**Step 1: Write `scripts/claw-register.sh` — mDNS service registration and LaunchAgent management**

```bash
#!/usr/bin/env bash
# claw-register.sh — Register this instance via mDNS and manage LaunchAgent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_state

GATEWAY_ID=$(get_state_field "gatewayId")
NAME=$(get_state_field "name")
LEAD_NUMBER=$(get_state_field "leadNumber")
PORT=22

ACTION="${1:-start}"

install_launchagent() {
  log_info "Installing LaunchAgent for mDNS registration..."

  mkdir -p "$(dirname "${CLAW_LAUNCHAGENT_PLIST}")"

  cat > "${CLAW_LAUNCHAGENT_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${CLAW_LAUNCHAGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/dns-sd</string>
        <string>-R</string>
        <string>${NAME}</string>
        <string>${CLAW_SERVICE_TYPE}</string>
        <string>local</string>
        <string>${PORT}</string>
        <string>gateway=${GATEWAY_ID}</string>
        <string>name=${NAME}</string>
        <string>lead=${LEAD_NUMBER}</string>
        <string>version=${CLAW_VERSION}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${CLAW_LOGS_DIR}/mdns-register.log</string>
    <key>StandardErrorPath</key>
    <string>${CLAW_LOGS_DIR}/mdns-register-err.log</string>
</dict>
</plist>
PLIST

  # Unload if already loaded, then load
  launchctl bootout "gui/$(id -u)/${CLAW_LAUNCHAGENT_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "${CLAW_LAUNCHAGENT_PLIST}"

  log_info "mDNS service registered: ${NAME} (${GATEWAY_ID}) on port ${PORT}"
}

uninstall_launchagent() {
  log_info "Removing LaunchAgent for mDNS registration..."
  launchctl bootout "gui/$(id -u)/${CLAW_LAUNCHAGENT_LABEL}" 2>/dev/null || true
  rm -f "${CLAW_LAUNCHAGENT_PLIST}"
  log_info "mDNS registration stopped."
}

status_launchagent() {
  if launchctl print "gui/$(id -u)/${CLAW_LAUNCHAGENT_LABEL}" &>/dev/null; then
    log_info "mDNS LaunchAgent is RUNNING"
    return 0
  else
    log_warn "mDNS LaunchAgent is NOT running"
    return 1
  fi
}

case "$ACTION" in
  start|install)
    install_launchagent
    ;;
  stop|uninstall)
    uninstall_launchagent
    ;;
  status)
    status_launchagent
    ;;
  restart)
    uninstall_launchagent
    sleep 1
    install_launchagent
    ;;
  *)
    echo "Usage: $0 {start|stop|status|restart}"
    exit 1
    ;;
esac
```

**Step 2: Make script executable and verify syntax**

Run: `chmod +x scripts/claw-register.sh && bash -n scripts/claw-register.sh && echo "OK"`
Expected: `OK`

**Step 3: Commit**

```bash
git add scripts/claw-register.sh
git commit -m "feat: add mDNS registration script with LaunchAgent support"
```

---

### Task 3: mDNS Discovery Script

**Files:**
- Create: `scripts/claw-discover.sh`

**Step 1: Write `scripts/claw-discover.sh` — discover peers via mDNS**

```bash
#!/usr/bin/env bash
# claw-discover.sh — Discover OpenClaw peers on the LAN via mDNS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/storage.sh"

require_state

MY_GATEWAY_ID=$(get_state_field "gatewayId")
TIMEOUT="${1:-5}"  # seconds to browse before stopping

log_info "Browsing for ${CLAW_SERVICE_TYPE} services (${TIMEOUT}s timeout)..."

# Browse for services, capture output, kill after timeout
BROWSE_OUTPUT=$(timeout "$TIMEOUT" dns-sd -B "${CLAW_SERVICE_TYPE}" local 2>/dev/null || true)

# Extract unique service names (skip header lines, skip our own)
SERVICE_NAMES=()
while IFS= read -r line; do
  # Lines look like: "timestamp  Add  flags ifindex domain type  name"
  name=$(echo "$line" | awk '/Add/ {for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | xargs)
  [[ -z "$name" ]] && continue
  SERVICE_NAMES+=("$name")
done <<< "$BROWSE_OUTPUT"

# Deduplicate
readarray -t SERVICE_NAMES < <(printf '%s\n' "${SERVICE_NAMES[@]}" | sort -u)

if [[ ${#SERVICE_NAMES[@]} -eq 0 ]]; then
  log_info "No peers found on the network."
  exit 0
fi

log_info "Found ${#SERVICE_NAMES[@]} service(s). Resolving..."

DISCOVERED_PEERS="[]"

for service_name in "${SERVICE_NAMES[@]}"; do
  log_info "Resolving: $service_name"

  # Resolve to get hostname, port, TXT records
  RESOLVE_OUTPUT=$(timeout 3 dns-sd -L "$service_name" "${CLAW_SERVICE_TYPE}" local 2>/dev/null || true)

  # Extract hostname and port from resolve output
  hostname=$(echo "$RESOLVE_OUTPUT" | grep "can be reached" | sed 's/.*at //' | sed 's/:.*//' | xargs)
  port=$(echo "$RESOLVE_OUTPUT" | grep "can be reached" | sed 's/.*://' | sed 's/ .*//' | xargs)

  # Extract TXT record values
  txt_line=$(echo "$RESOLVE_OUTPUT" | grep "text record:" || echo "")
  gateway_id=$(echo "$txt_line" | grep -o 'gateway=[^ ]*' | cut -d= -f2)
  peer_name=$(echo "$txt_line" | grep -o 'name=[^ ]*' | cut -d= -f2)
  lead_num=$(echo "$txt_line" | grep -o 'lead=[^ ]*' | cut -d= -f2)

  # Skip ourselves
  [[ "$gateway_id" == "$MY_GATEWAY_ID" ]] && continue

  # Resolve hostname to IP
  if [[ -n "$hostname" ]]; then
    IP_OUTPUT=$(timeout 3 dns-sd -G v4 "$hostname" 2>/dev/null || true)
    ip=$(echo "$IP_OUTPUT" | grep -v '^DATE\|^Timestamp\|^$' | tail -1 | awk '{print $6}' || echo "")
  fi

  if [[ -z "$ip" || -z "$gateway_id" ]]; then
    log_warn "Could not fully resolve $service_name, skipping"
    continue
  fi

  log_info "Discovered: $peer_name ($gateway_id) at $ip:$port lead=$lead_num"

  # Build peer JSON
  peer_json=$(jq -n \
    --arg gid "$gateway_id" \
    --arg name "$peer_name" \
    --arg lead "$lead_num" \
    --arg ip "$ip" \
    --arg port "$port" \
    '{
      gatewayId: $gid,
      name: $name,
      leadNumber: ($lead | tonumber),
      ip: $ip,
      port: ($port | tonumber),
      discoveredAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      discoveryMethod: "mdns"
    }')

  # Save peer
  save_peer_status "$gateway_id" "$peer_json"

  DISCOVERED_PEERS=$(echo "$DISCOVERED_PEERS" | jq --argjson peer "$peer_json" '. + [$peer]')
done

PEER_COUNT=$(echo "$DISCOVERED_PEERS" | jq 'length')
log_info "Discovery complete. Found $PEER_COUNT peer(s)."
echo "$DISCOVERED_PEERS" | jq '.'
```

**Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/claw-discover.sh && bash -n scripts/claw-discover.sh && echo "OK"`
Expected: `OK`

**Step 3: Commit**

```bash
git add scripts/claw-discover.sh
git commit -m "feat: add mDNS peer discovery script"
```

---

### Task 4: SSH Setup Helper

**Files:**
- Create: `scripts/claw-setup-ssh.sh`

**Step 1: Write `scripts/claw-setup-ssh.sh` — SSH key generation and exchange helper**

```bash
#!/usr/bin/env bash
# claw-setup-ssh.sh — Generate SSH keys and test/guide SSH connectivity

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_state

ACTION="${1:-check}"
TARGET_USER="${2:-}"
TARGET_IP="${3:-}"

MY_IP=$(get_state_field "ip")
MY_USER=$(get_state_field "sshUser")
MY_GATEWAY=$(get_state_field "gatewayId")
MY_NAME=$(get_state_field "name")

SSH_KEY="${HOME}/.ssh/id_ed25519"

ensure_key() {
  if [[ ! -f "$SSH_KEY" ]]; then
    log_info "No SSH key found. Generating ed25519 key..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N ""
    log_info "SSH key generated: ${SSH_KEY}"
  else
    log_info "SSH key exists: ${SSH_KEY}"
  fi
}

test_ssh() {
  local user="$1"
  local ip="$2"
  log_info "Testing SSH to ${user}@${ip}..."
  if ssh ${CLAW_SSH_OPTS} "${user}@${ip}" "echo 'claw-clan-handshake'" 2>/dev/null; then
    log_info "SSH to ${user}@${ip}: SUCCESS"
    return 0
  else
    log_warn "SSH to ${user}@${ip}: FAILED"
    return 1
  fi
}

print_setup_instructions() {
  local target_user="$1"
  local target_ip="$2"
  local target_name="${3:-unknown}"
  local target_gateway="${4:-unknown}"

  cat <<EOF

Cannot SSH to ${target_name} (${target_gateway}) at ${target_ip}.
To enable claw-clan connectivity:

On THIS machine (${MY_NAME} / ${MY_GATEWAY}):

  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  ssh-copy-id -i ~/.ssh/id_ed25519.pub ${target_user}@${target_ip}

On ${target_name} (${target_ip}):

  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  ssh-copy-id -i ~/.ssh/id_ed25519.pub ${MY_USER}@${MY_IP}

After both machines have exchanged keys, run: claw-clan verify

EOF
}

check_all_peers() {
  local failures=0
  for peer_file in "${CLAW_PEERS_DIR}"/*.json; do
    [[ -f "$peer_file" ]] || continue
    local peer_gw peer_ip peer_user peer_name
    peer_gw=$(jq -r '.gatewayId' "$peer_file")
    peer_ip=$(jq -r '.ip' "$peer_file")
    peer_user=$(jq -r '.sshUser // "'"$MY_USER"'"' "$peer_file")
    peer_name=$(jq -r '.name // "unknown"' "$peer_file")

    if ! test_ssh "$peer_user" "$peer_ip"; then
      print_setup_instructions "$peer_user" "$peer_ip" "$peer_name" "$peer_gw"
      ((failures++))

      # Update peer status
      local existing
      existing=$(cat "$peer_file")
      echo "$existing" | jq '.sshConnectivity = false' > "$peer_file"
    else
      local existing
      existing=$(cat "$peer_file")
      echo "$existing" | jq '.sshConnectivity = true' > "$peer_file"
    fi
  done

  if [[ $failures -eq 0 ]]; then
    log_info "All peers are SSH-accessible."
  else
    log_warn "$failures peer(s) not SSH-accessible. See instructions above."
  fi
  return $failures
}

case "$ACTION" in
  keygen)
    ensure_key
    ;;
  test)
    [[ -z "$TARGET_USER" || -z "$TARGET_IP" ]] && { echo "Usage: $0 test <user> <ip>"; exit 1; }
    test_ssh "$TARGET_USER" "$TARGET_IP"
    ;;
  check)
    ensure_key
    check_all_peers
    ;;
  *)
    echo "Usage: $0 {keygen|test <user> <ip>|check}"
    exit 1
    ;;
esac
```

**Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/claw-setup-ssh.sh && bash -n scripts/claw-setup-ssh.sh && echo "OK"`
Expected: `OK`

**Step 3: Commit**

```bash
git add scripts/claw-setup-ssh.sh
git commit -m "feat: add SSH key setup and connectivity verification script"
```

---

### Task 5: Keep-Alive Ping Script

**Files:**
- Create: `scripts/claw-ping.sh`

**Step 1: Write `scripts/claw-ping.sh` — cron-driven keep-alive ping**

```bash
#!/usr/bin/env bash
# claw-ping.sh — Send keep-alive pings to all known peers (cron-driven)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/storage.sh"

require_state

MY_GATEWAY=$(get_state_field "gatewayId")
MY_NAME=$(get_state_field "name")
MY_USER=$(get_state_field "sshUser")
TIMESTAMP=$(date +%s)

log_info "Starting keep-alive ping cycle..."

for peer_file in "${CLAW_PEERS_DIR}"/*.json; do
  [[ -f "$peer_file" ]] || continue

  peer_gw=$(jq -r '.gatewayId' "$peer_file")
  peer_ip=$(jq -r '.ip' "$peer_file")
  peer_user=$(jq -r '.sshUser // "'"$MY_USER"'"' "$peer_file")
  peer_name=$(jq -r '.name // "unknown"' "$peer_file")

  log_info "Pinging ${peer_name} (${peer_gw}) at ${peer_ip}..."

  # Send ping via SSH, capture response
  response=$(timeout "${CLAW_PING_TIMEOUT}" ssh ${CLAW_SSH_OPTS} \
    "${peer_user}@${peer_ip}" \
    "echo 'claw-clan-ack $(hostname) $(date +%s)'" 2>/dev/null) || true

  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  if [[ "$response" == claw-clan-ack* ]]; then
    log_info "  ${peer_name}: ALIVE"

    # Update peer status — reset timer, clear missed pings
    existing=$(cat "$peer_file")
    echo "$existing" | jq \
      --arg now "$now" \
      '.status = "online" | .lastSeen = $now | .lastPingAttempt = $now | .missedPings = 0 | .sshConnectivity = true' \
      > "$peer_file"

    log_event "ping_success" "$(jq -n --arg gw "$peer_gw" --arg ts "$now" '{gatewayId: $gw, timestamp: $ts}')"
  else
    # Increment missed pings
    missed=$(jq -r '.missedPings // 0' "$peer_file")
    missed=$((missed + 1))

    threshold=$(get_config_field "offlineThresholdPings" "2")

    if [[ $missed -ge $threshold ]]; then
      log_warn "  ${peer_name}: OFFLINE (missed $missed pings)"
      status="offline"
    else
      log_warn "  ${peer_name}: UNRESPONSIVE (missed $missed/$threshold pings)"
      status="unresponsive"
    fi

    existing=$(cat "$peer_file")
    echo "$existing" | jq \
      --arg now "$now" \
      --arg status "$status" \
      --argjson missed "$missed" \
      '.status = $status | .lastPingAttempt = $now | .missedPings = $missed | .sshConnectivity = false' \
      > "$peer_file"

    log_event "ping_fail" "$(jq -n --arg gw "$peer_gw" --arg ts "$now" --argjson missed "$missed" '{gatewayId: $gw, timestamp: $ts, missedPings: $missed}')"
  fi
done

log_info "Ping cycle complete."
```

**Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/claw-ping.sh && bash -n scripts/claw-ping.sh && echo "OK"`
Expected: `OK`

**Step 3: Commit**

```bash
git add scripts/claw-ping.sh
git commit -m "feat: add keep-alive ping script for cron-driven health checks"
```

---

### Task 6: Monitoring Script (Leader Only)

**Files:**
- Create: `scripts/claw-monitor.sh`

**Step 1: Write `scripts/claw-monitor.sh` — leader's monitoring and recovery**

```bash
#!/usr/bin/env bash
# claw-monitor.sh — Monitor a specific peer (leader-only, cron-driven)
# Usage: claw-monitor.sh <gateway-id>
# Called by cron every 5 minutes when continuous monitoring is active

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/storage.sh"

require_state

TARGET_GATEWAY="${1:?Usage: $0 <gateway-id>}"
MY_USER=$(get_state_field "sshUser")

PEER_FILE="${CLAW_PEERS_DIR}/${TARGET_GATEWAY}.json"
if [[ ! -f "$PEER_FILE" ]]; then
  log_error "Unknown peer: $TARGET_GATEWAY"
  exit 1
fi

peer_ip=$(jq -r '.ip' "$PEER_FILE")
peer_user=$(jq -r '.sshUser // "'"$MY_USER"'"' "$PEER_FILE")
peer_name=$(jq -r '.name // "unknown"' "$PEER_FILE")
now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

log_info "Monitoring check: ${peer_name} (${TARGET_GATEWAY}) at ${peer_ip}" >> "${CLAW_LOGS_DIR}/monitor.log"

# Attempt 1: SSH ping
ssh_alive=false
response=$(timeout "${CLAW_PING_TIMEOUT}" ssh ${CLAW_SSH_OPTS} \
  "${peer_user}@${peer_ip}" \
  "echo 'claw-clan-ack $(hostname) $(date +%s)'" 2>/dev/null) || true

if [[ "$response" == claw-clan-ack* ]]; then
  ssh_alive=true
fi

# Attempt 2: Check mDNS (quick 3-second browse)
mdns_alive=false
mdns_output=$(timeout 3 dns-sd -B "${CLAW_SERVICE_TYPE}" local 2>/dev/null || true)
if echo "$mdns_output" | grep -q "$peer_name"; then
  mdns_alive=true
fi

if [[ "$ssh_alive" == "true" ]]; then
  log_info "RECOVERY: ${peer_name} is back online (SSH responding)" >> "${CLAW_LOGS_DIR}/monitor.log"

  # Update peer status
  existing=$(cat "$PEER_FILE")
  went_offline=$(echo "$existing" | jq -r '.lastSeen // "unknown"')
  echo "$existing" | jq \
    --arg now "$now" \
    '.status = "online" | .lastSeen = $now | .lastPingAttempt = $now | .missedPings = 0 | .sshConnectivity = true' \
    > "$PEER_FILE"

  # Calculate downtime
  downtime="unknown"
  if [[ "$went_offline" != "unknown" && "$went_offline" != "null" ]]; then
    offline_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$went_offline" '+%s' 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    if [[ $offline_epoch -gt 0 ]]; then
      diff=$((now_epoch - offline_epoch))
      hours=$((diff / 3600))
      minutes=$(( (diff % 3600) / 60 ))
      downtime="${hours}h ${minutes}m"
    fi
  fi

  # Check claw-clan installation on recovered peer
  claw_installed=false
  claw_state_exists=$(ssh ${CLAW_SSH_OPTS} "${peer_user}@${peer_ip}" \
    "test -f ~/.openclaw/claw-clan/state.json && echo 'yes' || echo 'no'" 2>/dev/null) || claw_state_exists="no"

  claw_cron_active=$(ssh ${CLAW_SSH_OPTS} "${peer_user}@${peer_ip}" \
    "crontab -l 2>/dev/null | grep -c 'claw-clan' || echo '0'" 2>/dev/null) || claw_cron_active="0"

  if [[ "$claw_state_exists" == "yes" && "$claw_cron_active" -gt 0 ]]; then
    claw_installed=true
  fi

  # Write recovery report
  gateway_responding="is"
  if [[ "$mdns_alive" != "true" ]]; then
    gateway_responding="is not"
  fi

  cat > "${CLAW_LOGS_DIR}/recovery-${TARGET_GATEWAY}.json" <<EOF
{
  "gatewayId": "${TARGET_GATEWAY}",
  "name": "${peer_name}",
  "recoveredAt": "${now}",
  "downtime": "${downtime}",
  "sshResponding": ${ssh_alive},
  "mdnsBroadcasting": ${mdns_alive},
  "gatewayResponding": "${gateway_responding}",
  "clawClanInstalled": ${claw_installed},
  "clawStateExists": $([ "$claw_state_exists" = "yes" ] && echo true || echo false),
  "clawCronActive": $([ "$claw_cron_active" -gt 0 ] && echo true || echo false)
}
EOF

  log_event "peer_recovery" "$(cat "${CLAW_LOGS_DIR}/recovery-${TARGET_GATEWAY}.json")"

  # Remove the monitoring cron job (self-cleanup)
  crontab -l 2>/dev/null | grep -v "claw-monitor.sh ${TARGET_GATEWAY}" | crontab -

  log_info "Monitoring cron removed for ${TARGET_GATEWAY}" >> "${CLAW_LOGS_DIR}/monitor.log"
else
  log_info "Still offline: ${peer_name} (SSH=$ssh_alive, mDNS=$mdns_alive)" >> "${CLAW_LOGS_DIR}/monitor.log"
fi
```

**Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/claw-monitor.sh && bash -n scripts/claw-monitor.sh && echo "OK"`
Expected: `OK`

**Step 3: Commit**

```bash
git add scripts/claw-monitor.sh
git commit -m "feat: add leader monitoring script with recovery detection"
```

---

### Task 7: Skill Sync Script

**Files:**
- Create: `scripts/claw-sync-skills.sh`

**Step 1: Write `scripts/claw-sync-skills.sh` — distribute skills from GitHub repo**

```bash
#!/usr/bin/env bash
# claw-sync-skills.sh — Sync shared skills from GitHub repo to peers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_state

REPO_URL=$(get_state_field "githubRepo")
MY_USER=$(get_state_field "sshUser")
TARGET_GATEWAY="${1:-all}"  # "all" or a specific gateway-id

if [[ -z "$REPO_URL" || "$REPO_URL" == "null" ]]; then
  log_error "No GitHub repo configured. Set githubRepo in state.json during setup."
  exit 1
fi

SKILLS_DIR="${HOME}/.openclaw/skills"

sync_local() {
  log_info "Syncing local skills from $REPO_URL..."
  if [[ -d "${SKILLS_DIR}/.git" ]]; then
    git -C "${SKILLS_DIR}" pull origin main 2>&1
  else
    git clone "$REPO_URL" "${SKILLS_DIR}" 2>&1
  fi
  log_info "Local skills synced."
}

sync_peer() {
  local peer_gw="$1"
  local peer_file="${CLAW_PEERS_DIR}/${peer_gw}.json"
  [[ -f "$peer_file" ]] || { log_warn "Peer not found: $peer_gw"; return 1; }

  local peer_ip peer_user peer_name
  peer_ip=$(jq -r '.ip' "$peer_file")
  peer_user=$(jq -r '.sshUser // "'"$MY_USER"'"' "$peer_file")
  peer_name=$(jq -r '.name // "unknown"' "$peer_file")

  log_info "Syncing skills to ${peer_name} (${peer_gw}) at ${peer_ip}..."

  ssh ${CLAW_SSH_OPTS} "${peer_user}@${peer_ip}" bash <<REMOTE_SCRIPT
    SKILLS_DIR="\${HOME}/.openclaw/skills"
    mkdir -p "\${SKILLS_DIR}"
    if [[ -d "\${SKILLS_DIR}/.git" ]]; then
      git -C "\${SKILLS_DIR}" pull origin main 2>&1
    else
      git clone "${REPO_URL}" "\${SKILLS_DIR}" 2>&1
    fi
REMOTE_SCRIPT

  if [[ $? -eq 0 ]]; then
    log_info "  ${peer_name}: Skills synced successfully."
  else
    log_warn "  ${peer_name}: Skill sync failed."
    return 1
  fi
}

# Always sync locally first
sync_local

if [[ "$TARGET_GATEWAY" == "all" ]]; then
  for peer_file in "${CLAW_PEERS_DIR}"/*.json; do
    [[ -f "$peer_file" ]] || continue
    peer_gw=$(jq -r '.gatewayId' "$peer_file")
    peer_status=$(jq -r '.status // "unknown"' "$peer_file")
    if [[ "$peer_status" == "online" ]]; then
      sync_peer "$peer_gw" || true
    else
      log_warn "Skipping ${peer_gw} (status: $peer_status)"
    fi
  done
else
  sync_peer "$TARGET_GATEWAY"
fi

log_info "Skill sync complete."
```

**Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/claw-sync-skills.sh && bash -n scripts/claw-sync-skills.sh && echo "OK"`
Expected: `OK`

**Step 3: Commit**

```bash
git add scripts/claw-sync-skills.sh
git commit -m "feat: add skill distribution script for GitHub repo sync"
```

---

### Task 8: claw-clan SKILL.md

**Files:**
- Create: `skills/claw-clan/SKILL.md`

**Step 1: Write the claw-clan skill**

This is the OpenClaw skill that teaches Claude Code how to set up and manage peer discovery.

```markdown
---
name: claw-clan
description: OpenClaw peer discovery and coordination. Setup claw-clan, discover peers on LAN, manage fleet, configure SSH between OpenClaw instances, keep-alive monitoring
metadata:
  openclaw:
    requires:
      bins: ["ssh", "ssh-keygen", "jq"]
    os: darwin
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
  --arg ip "$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)" \
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
# 1. Register on mDNS (installs LaunchAgent)
~/.openclaw/claw-clan/scripts/claw-register.sh start

# 2. Discover peers
~/.openclaw/claw-clan/scripts/claw-discover.sh

# 3. Check SSH connectivity
~/.openclaw/claw-clan/scripts/claw-setup-ssh.sh check

# 4. Install keep-alive cron (every 15 minutes)
(crontab -l 2>/dev/null | grep -v 'claw-ping.sh'; echo "*/15 * * * * ${HOME}/.openclaw/claw-clan/scripts/claw-ping.sh >> ${HOME}/.openclaw/claw-clan/logs/ping.log 2>&1 # claw-clan") | crontab -
```

## SSH Failure Handling

When SSH to a peer fails, provide these instructions:

```
Cannot SSH to <name> (<gateway>) at <ip>.
To enable claw-clan connectivity, run these commands on THIS machine:

  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  ssh-copy-id -i ~/.ssh/id_ed25519.pub <username>@<lan-ip>

Then on <name> (<ip>):

  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  ssh-copy-id -i ~/.ssh/id_ed25519.pub <your-username>@<your-ip>

After exchanging keys: claw-clan verify
```

## Available Commands

| Command | Script | Purpose |
|---------|--------|---------|
| Register mDNS | `claw-register.sh start` | Broadcast service on LAN |
| Stop mDNS | `claw-register.sh stop` | Remove mDNS registration |
| Discover peers | `claw-discover.sh` | Browse LAN for OpenClaw instances |
| Check SSH | `claw-setup-ssh.sh check` | Test SSH to all peers |
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
```

**Step 2: Commit**

```bash
git add skills/claw-clan/SKILL.md
git commit -m "feat: add claw-clan OpenClaw skill definition"
```

---

### Task 9: claw-afterlife SKILL.md

**Files:**
- Create: `skills/claw-afterlife/SKILL.md`

**Step 1: Write the claw-afterlife skill**

```markdown
---
name: claw-afterlife
description: OpenClaw fleet health monitoring and recovery. Monitor peer status, leader election, offline notifications, skill reinstallation, cron job management for OpenClaw instances
metadata:
  openclaw:
    requires:
      bins: ["ssh", "crontab", "jq"]
    os: darwin
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
  echo "Options:"
  echo "  1. Reinstall claw-clan (re-run setup on remote)"
  echo "  2. Ignore (peer is functional)"

  # Clean up report after reading
  # rm "$REPORT"
fi
```

## Reinstall claw-clan on Recovered Peer

If user chooses reinstall, SSH to the peer and re-run setup:

```bash
GATEWAY_ID="<gateway-id>"
PEER_FILE="${HOME}/.openclaw/claw-clan/peers/${GATEWAY_ID}.json"
PEER_IP=$(jq -r '.ip' "$PEER_FILE")
PEER_USER=$(jq -r '.sshUser' "$PEER_FILE")

# Copy scripts to remote
scp -r ~/.openclaw/claw-clan/scripts/ "${PEER_USER}@${PEER_IP}:~/.openclaw/claw-clan/scripts/"

# Re-register mDNS
ssh "${PEER_USER}@${PEER_IP}" "~/.openclaw/claw-clan/scripts/claw-register.sh restart"

# Reinstall cron
ssh "${PEER_USER}@${PEER_IP}" bash <<'REMOTE'
(crontab -l 2>/dev/null | grep -v 'claw-ping.sh'; \
 echo "*/15 * * * * ${HOME}/.openclaw/claw-clan/scripts/claw-ping.sh >> ${HOME}/.openclaw/claw-clan/logs/ping.log 2>&1 # claw-clan") | crontab -
REMOTE
```

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
```

**Step 2: Commit**

```bash
git add skills/claw-afterlife/SKILL.md
git commit -m "feat: add claw-afterlife OpenClaw skill definition"
```

---

### Task 10: PostgreSQL Schema & Storage Backend

**Files:**
- Create: `migrations/001-initial-schema.sql`
- Create: `scripts/lib/storage-postgres.sh`

**Step 1: Write the Postgres migration**

```sql
-- 001-initial-schema.sql
-- Claw-friends PostgreSQL schema

CREATE TABLE IF NOT EXISTS fleet_instances (
  gateway_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  lead_number INTEGER NOT NULL,
  ip TEXT NOT NULL,
  ssh_user TEXT NOT NULL,
  version TEXT NOT NULL DEFAULT '1.0.0',
  registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  github_repo TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS peer_status (
  gateway_id TEXT PRIMARY KEY REFERENCES fleet_instances(gateway_id),
  status TEXT NOT NULL DEFAULT 'unknown' CHECK (status IN ('online', 'offline', 'unresponsive', 'unknown')),
  last_seen TIMESTAMPTZ,
  last_ping_attempt TIMESTAMPTZ,
  missed_pings INTEGER NOT NULL DEFAULT 0,
  ssh_connectivity BOOLEAN NOT NULL DEFAULT false,
  claw_clan_installed BOOLEAN NOT NULL DEFAULT false,
  mdns_broadcasting BOOLEAN NOT NULL DEFAULT false,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ping_history (
  id SERIAL PRIMARY KEY,
  source_gateway TEXT NOT NULL,
  target_gateway TEXT NOT NULL,
  success BOOLEAN NOT NULL,
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  response_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_ping_history_target ON ping_history(target_gateway, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_ping_history_timestamp ON ping_history(timestamp DESC);

CREATE TABLE IF NOT EXISTS incident_log (
  id SERIAL PRIMARY KEY,
  gateway_id TEXT NOT NULL,
  event_type TEXT NOT NULL CHECK (event_type IN ('offline', 'online', 'recovery', 'reinstall', 'skill_sync', 'leader_change')),
  details JSONB,
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_incident_log_gateway ON incident_log(gateway_id, timestamp DESC);

CREATE TABLE IF NOT EXISTS skill_audit (
  id SERIAL PRIMARY KEY,
  gateway_id TEXT NOT NULL,
  skill_name TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('install', 'update', 'remove')),
  source TEXT,
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Step 2: Write `scripts/lib/storage-postgres.sh`**

```bash
#!/usr/bin/env bash
# storage-postgres.sh — PostgreSQL storage backend

_pg_cmd() {
  local host port db user pass
  host=$(get_config_field "postgres.host")
  port=$(get_config_field "postgres.port" "5432")
  db=$(get_config_field "postgres.database" "claw_clan")
  user=$(get_config_field "postgres.user")
  pass=$(get_config_field "postgres.password")

  PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db" -t -A -c "$1" 2>/dev/null
}

save_peer_status() {
  local gateway_id="$1"
  local json_data="$2"

  local status last_seen last_ping missed ssh mdns claw_installed
  status=$(echo "$json_data" | jq -r '.status // "unknown"')
  last_seen=$(echo "$json_data" | jq -r '.lastSeen // null')
  last_ping=$(echo "$json_data" | jq -r '.lastPingAttempt // null')
  missed=$(echo "$json_data" | jq -r '.missedPings // 0')
  ssh=$(echo "$json_data" | jq -r '.sshConnectivity // false')
  mdns=$(echo "$json_data" | jq -r '.mdnsBroadcasting // false')
  claw_installed=$(echo "$json_data" | jq -r '.clawClanInstalled // false')

  _pg_cmd "INSERT INTO peer_status (gateway_id, status, last_seen, last_ping_attempt, missed_pings, ssh_connectivity, mdns_broadcasting, claw_clan_installed)
    VALUES ('$gateway_id', '$status', $([ "$last_seen" = "null" ] && echo "NULL" || echo "'$last_seen'"), $([ "$last_ping" = "null" ] && echo "NULL" || echo "'$last_ping'"), $missed, $ssh, $mdns, $claw_installed)
    ON CONFLICT (gateway_id) DO UPDATE SET
      status = EXCLUDED.status,
      last_seen = EXCLUDED.last_seen,
      last_ping_attempt = EXCLUDED.last_ping_attempt,
      missed_pings = EXCLUDED.missed_pings,
      ssh_connectivity = EXCLUDED.ssh_connectivity,
      mdns_broadcasting = EXCLUDED.mdns_broadcasting,
      claw_clan_installed = EXCLUDED.claw_clan_installed,
      updated_at = NOW();"

  # Also save to JSON for local fallback
  local peer_file="${CLAW_PEERS_DIR}/${gateway_id}.json"
  echo "$json_data" | jq '.' > "$peer_file"
}

get_peer_status() {
  local gateway_id="$1"
  _pg_cmd "SELECT row_to_json(ps) FROM peer_status ps WHERE gateway_id = '$gateway_id';" || echo "{}"
}

get_all_peers() {
  _pg_cmd "SELECT json_agg(row_to_json(ps)) FROM peer_status ps;" || echo "[]"
}

save_fleet() {
  local json_data="$1"
  # Upsert each instance
  echo "$json_data" | jq -c '.instances[]' | while read -r instance; do
    local gid name lead ip user version repo
    gid=$(echo "$instance" | jq -r '.gatewayId')
    name=$(echo "$instance" | jq -r '.name')
    lead=$(echo "$instance" | jq -r '.leadNumber')
    ip=$(echo "$instance" | jq -r '.ip')
    user=$(echo "$instance" | jq -r '.sshUser')
    version=$(echo "$instance" | jq -r '.version // "1.0.0"')
    repo=$(echo "$instance" | jq -r '.githubRepo // null')

    _pg_cmd "INSERT INTO fleet_instances (gateway_id, name, lead_number, ip, ssh_user, version, github_repo)
      VALUES ('$gid', '$name', $lead, '$ip', '$user', '$version', $([ "$repo" = "null" ] && echo "NULL" || echo "'$repo'"))
      ON CONFLICT (gateway_id) DO UPDATE SET
        name = EXCLUDED.name, lead_number = EXCLUDED.lead_number, ip = EXCLUDED.ip,
        ssh_user = EXCLUDED.ssh_user, version = EXCLUDED.version, github_repo = EXCLUDED.github_repo,
        updated_at = NOW();"
  done

  # Also save to JSON
  echo "$json_data" | jq '.' > "${CLAW_FLEET}"
}

get_fleet() {
  local result
  result=$(_pg_cmd "SELECT json_build_object('instances', json_agg(row_to_json(fi))) FROM fleet_instances fi;")
  if [[ -n "$result" && "$result" != "null" ]]; then
    echo "$result"
  else
    echo '{"instances":[]}'
  fi
}

log_event() {
  local event_type="$1"
  local json_data="$2"
  local gateway_id
  gateway_id=$(echo "$json_data" | jq -r '.gatewayId // "unknown"')
  _pg_cmd "INSERT INTO incident_log (gateway_id, event_type, details) VALUES ('$gateway_id', '$event_type', '$json_data'::jsonb);"
}
```

**Step 3: Verify syntax**

Run: `bash -n scripts/lib/storage-postgres.sh && echo "OK"`
Expected: `OK`

**Step 4: Commit**

```bash
git add migrations/001-initial-schema.sql scripts/lib/storage-postgres.sh
git commit -m "feat: add PostgreSQL schema and storage backend"
```

---

### Task 11: Skill Reference Documents

**Files:**
- Create: `skills/claw-clan/references/setup-guide.md`
- Create: `skills/claw-clan/references/ssh-troubleshooting.md`
- Create: `skills/claw-clan/references/mdns-reference.md`
- Create: `skills/claw-afterlife/references/leader-election.md`
- Create: `skills/claw-afterlife/references/recovery-procedures.md`
- Create: `skills/claw-afterlife/references/postgres-setup.md`

**Step 1: Write reference docs**

These are detailed reference files loaded on-demand by the skills. Each should cover its topic exhaustively. Content is derived from the design doc and mDNS research.

Key content per file:

- **setup-guide.md**: Step-by-step first-time setup walkthrough with all prompts, defaults, and validation
- **ssh-troubleshooting.md**: Common SSH failures (permission denied, host key changed, timeout), resolution steps, key formats, agent forwarding
- **mdns-reference.md**: `dns-sd` command reference for macOS (`-R`, `-B`, `-L`, `-G`), LaunchAgent lifecycle, firewall notes, Sequoia mDNS bug workaround (`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`)
- **leader-election.md**: Leader determination algorithm, acting leader on failure, leadership reclamation, edge cases (tie-breaking, all peers offline)
- **recovery-procedures.md**: Full recovery workflow, recovery report schema, reinstallation steps, skill sync process
- **postgres-setup.md**: Docker deployment, Portainer deployment, existing instance connection, migration from JSON, distributing credentials to fleet

**Step 2: Commit**

```bash
git add skills/claw-clan/references/ skills/claw-afterlife/references/
git commit -m "feat: add reference documentation for claw-clan and claw-afterlife skills"
```

---

### Task 12: Initialize Git Repo & Final Verification

**Step 1: Initialize git in the project root**

```bash
cd /Users/MAllen/Library/CloudStorage/OneDrive-Personal/__AI_Development/OpenClaw-Development/claw-clan
git init
```

**Step 2: Create `.gitignore`**

```
.DS_Store
*.log
```

**Step 3: Make all scripts executable**

```bash
chmod +x scripts/*.sh
```

**Step 4: Verify all scripts parse cleanly**

```bash
for f in scripts/*.sh scripts/lib/*.sh; do
  bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"
done
```
Expected: All `OK`

**Step 5: Verify directory structure matches design**

```bash
find . -type f | grep -v '.git/' | grep -v '.DS_Store' | sort
```

Expected output should match the project file structure from the design doc.

**Step 6: Initial commit with all files**

```bash
git add -A
git commit -m "feat: initial claw-clan implementation — skills, scripts, storage backends, and documentation"
```

---

## Execution Order Summary

| Task | Component | Dependencies |
|------|-----------|-------------|
| 1 | Shared library & JSON storage | None |
| 2 | mDNS registration + LaunchAgent | Task 1 |
| 3 | mDNS discovery | Task 1 |
| 4 | SSH setup helper | Task 1 |
| 5 | Keep-alive ping | Task 1 |
| 6 | Monitoring (leader) | Task 1, 5 |
| 7 | Skill sync | Task 1 |
| 8 | claw-clan SKILL.md | Tasks 1-5 |
| 9 | claw-afterlife SKILL.md | Tasks 1-7 |
| 10 | PostgreSQL schema + backend | Task 1 |
| 11 | Reference documents | Tasks 8-9 |
| 12 | Git init & final verification | All |

Tasks 2-5 and 7 can be parallelized. Tasks 8-10 can be parallelized. Task 12 must be last.
