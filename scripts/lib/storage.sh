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
