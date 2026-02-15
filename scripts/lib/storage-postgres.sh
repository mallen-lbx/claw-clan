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
