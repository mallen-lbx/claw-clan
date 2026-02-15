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
