#!/usr/bin/env bash
# common.sh — shared utilities for claw-clan scripts

set -euo pipefail

# ─── Platform Detection ──────────────────────────────────────────────────────

CLAW_OS="$(uname -s)"  # "Darwin" or "Linux"

# ─── Paths & Constants ───────────────────────────────────────────────────────

CLAW_DIR="${HOME}/.openclaw/claw-clan"
CLAW_STATE="${CLAW_DIR}/state.json"
CLAW_FLEET="${CLAW_DIR}/fleet.json"
CLAW_CONFIG="${CLAW_DIR}/config.json"
CLAW_PEERS_DIR="${CLAW_DIR}/peers"
CLAW_LOGS_DIR="${CLAW_DIR}/logs"
CLAW_VERSION="1.0.0"
CLAW_SERVICE_TYPE="_openclaw._tcp"
CLAW_CRON_TAG="# claw-clan"
CLAW_PING_TIMEOUT=30
CLAW_SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

# ─── mDNS Persistence Paths (OS-specific) ────────────────────────────────────

CLAW_LAUNCHAGENT_LABEL="com.openclaw.claw-clan-mdns"

case "$CLAW_OS" in
  Darwin)
    CLAW_MDNS_SERVICE_PATH="${HOME}/Library/LaunchAgents/${CLAW_LAUNCHAGENT_LABEL}.plist"
    CLAW_MDNS_TOOL="dns-sd"
    ;;
  Linux)
    CLAW_MDNS_SERVICE_PATH="${HOME}/.config/systemd/user/claw-clan-mdns.service"
    CLAW_MDNS_TOOL="avahi-publish"
    ;;
  *)
    CLAW_MDNS_SERVICE_PATH=""
    CLAW_MDNS_TOOL=""
    ;;
esac

# Legacy alias (referenced by some scripts)
CLAW_LAUNCHAGENT_PLIST="${HOME}/Library/LaunchAgents/${CLAW_LAUNCHAGENT_LABEL}.plist"

# ─── Logging ─────────────────────────────────────────────────────────────────

log_info() { echo "[claw-clan] $(date '+%Y-%m-%d %H:%M:%S') INFO: $*"; }
log_warn() { echo "[claw-clan] $(date '+%Y-%m-%d %H:%M:%S') WARN: $*" >&2; }
log_error() { echo "[claw-clan] $(date '+%Y-%m-%d %H:%M:%S') ERROR: $*" >&2; }

# ─── Directory Setup ─────────────────────────────────────────────────────────

ensure_dirs() {
  mkdir -p "${CLAW_DIR}" "${CLAW_PEERS_DIR}" "${CLAW_LOGS_DIR}"
}

# ─── Dependency Checks ───────────────────────────────────────────────────────

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

# ─── State & Config Accessors ────────────────────────────────────────────────

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

# ─── Network Helpers ─────────────────────────────────────────────────────────

get_lan_ip() {
  local ip=""
  case "$CLAW_OS" in
    Darwin)
      ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")
      if [[ -z "$ip" ]]; then
        ip=$(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')
      fi
      ;;
    Linux)
      ip=$(hostname -I 2>/dev/null | awk '{print $1}')
      if [[ -z "$ip" ]]; then
        ip=$(ip -4 addr show scope global | grep 'inet ' | head -1 | awk '{print $2}' | cut -d/ -f1)
      fi
      ;;
  esac
  echo "$ip"
}

# ─── Date Helpers (cross-platform) ───────────────────────────────────────────

# Parse ISO-8601 date to epoch seconds
iso_to_epoch() {
  local iso_date="$1"
  case "$CLAW_OS" in
    Darwin)
      date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso_date" '+%s' 2>/dev/null || echo "0"
      ;;
    Linux)
      date -d "$iso_date" '+%s' 2>/dev/null || echo "0"
      ;;
  esac
}
