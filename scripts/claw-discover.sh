#!/usr/bin/env bash
# claw-discover.sh — Discover OpenClaw peers on the LAN via mDNS
# macOS: dns-sd -B/-L/-G
# Linux: avahi-browse --resolve --parsable

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/storage.sh"

require_state

MY_GATEWAY_ID=$(get_state_field "gatewayId")
TIMEOUT="${1:-5}"  # seconds to browse before stopping

log_info "Browsing for ${CLAW_SERVICE_TYPE} services (${TIMEOUT}s timeout)..."

# ═══════════════════════════════════════════════════════════════════════════════
# macOS: dns-sd based discovery
# ═══════════════════════════════════════════════════════════════════════════════

discover_darwin() {
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
    echo "[]"
    return
  fi

  log_info "Found ${#SERVICE_NAMES[@]} service(s). Resolving..."

  local discovered="[]"

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
    local ip=""
    if [[ -n "$hostname" ]]; then
      IP_OUTPUT=$(timeout 3 dns-sd -G v4 "$hostname" 2>/dev/null || true)
      ip=$(echo "$IP_OUTPUT" | grep -v '^DATE\|^Timestamp\|^$' | tail -1 | awk '{print $6}' || echo "")
    fi

    if [[ -z "$ip" || -z "$gateway_id" ]]; then
      log_warn "Could not fully resolve $service_name, skipping"
      continue
    fi

    log_info "Discovered: $peer_name ($gateway_id) at $ip:$port lead=$lead_num"

    # Build peer JSON and save
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

    save_peer_status "$gateway_id" "$peer_json"
    discovered=$(echo "$discovered" | jq --argjson peer "$peer_json" '. + [$peer]')
  done

  echo "$discovered"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Linux: avahi-browse based discovery
# ═══════════════════════════════════════════════════════════════════════════════

discover_linux() {
  # avahi-browse with --resolve --parsable --terminate gives all info in one pass
  # Output format (semicolon-delimited):
  #   =;interface;protocol;name;type;domain;hostname;address;port;txt
  # The = prefix means "resolved entry"
  local browse_output
  browse_output=$(timeout "$TIMEOUT" avahi-browse "${CLAW_SERVICE_TYPE}" \
    --resolve --parsable --terminate --no-db-lookup 2>/dev/null || true)

  local discovered="[]"
  local seen_gateways=""

  while IFS=';' read -r status iface proto svc_name svc_type domain hostname address port txt_raw; do
    # Only process resolved entries (lines starting with =)
    [[ "$status" != "=" ]] && continue

    # Parse TXT records: avahi gives them as quoted strings like "gateway=foo" "name=bar"
    local gateway_id="" peer_name="" lead_num="0"
    gateway_id=$(echo "$txt_raw" | grep -oP 'gateway=\K[^"]+' || echo "")
    peer_name=$(echo "$txt_raw" | grep -oP 'name=\K[^"]+' || echo "")
    lead_num=$(echo "$txt_raw" | grep -oP 'lead=\K[^"]+' || echo "0")

    # Skip ourselves
    [[ "$gateway_id" == "$MY_GATEWAY_ID" ]] && continue
    [[ -z "$gateway_id" ]] && continue

    # Skip duplicates (avahi may report same service on multiple interfaces)
    if echo "$seen_gateways" | grep -q "^${gateway_id}$"; then
      continue
    fi
    seen_gateways="${seen_gateways}${gateway_id}
"

    # Clean up hostname (remove trailing dot)
    hostname="${hostname%.}"

    log_info "Discovered: $peer_name ($gateway_id) at $address:$port lead=$lead_num"

    # Build peer JSON and save
    peer_json=$(jq -n \
      --arg gid "$gateway_id" \
      --arg name "$peer_name" \
      --arg lead "$lead_num" \
      --arg ip "$address" \
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

    save_peer_status "$gateway_id" "$peer_json"
    discovered=$(echo "$discovered" | jq --argjson peer "$peer_json" '. + [$peer]')

  done <<< "$browse_output"

  echo "$discovered"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatch
# ═══════════════════════════════════════════════════════════════════════════════

case "$CLAW_OS" in
  Darwin) DISCOVERED_PEERS=$(discover_darwin) ;;
  Linux)  DISCOVERED_PEERS=$(discover_linux) ;;
  *)
    log_error "Unsupported OS: $CLAW_OS"
    exit 1
    ;;
esac

PEER_COUNT=$(echo "$DISCOVERED_PEERS" | jq 'length')
log_info "Discovery complete. Found $PEER_COUNT peer(s)."
echo "$DISCOVERED_PEERS" | jq '.'
