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
