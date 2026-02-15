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
