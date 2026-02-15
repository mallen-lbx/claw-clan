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
case "$CLAW_OS" in
  Darwin)
    mdns_output=$(timeout 3 dns-sd -B "${CLAW_SERVICE_TYPE}" local 2>/dev/null || true)
    ;;
  Linux)
    mdns_output=$(timeout 3 avahi-browse "${CLAW_SERVICE_TYPE}" --terminate --parsable 2>/dev/null || true)
    ;;
esac
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
    offline_epoch=$(iso_to_epoch "$went_offline")
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
