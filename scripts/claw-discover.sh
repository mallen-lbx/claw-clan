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
