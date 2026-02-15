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
