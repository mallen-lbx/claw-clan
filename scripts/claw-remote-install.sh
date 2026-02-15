#!/usr/bin/env bash
# claw-remote-install.sh — Push claw-clan to a remote peer via SSH
# Usage: claw-remote-install.sh <user> <ip> [name] [gateway-id] [lead-number]
#
# Performs a first-time install of claw-clan on a remote machine:
#   1. Creates directory structure on remote
#   2. Pushes scripts and lib files via scp
#   3. Generates a state.json on the remote with sensible defaults
#   4. Generates a config.json on the remote
#   5. Registers mDNS on the remote (macOS only)
#   6. Installs keep-alive cron on the remote
#   7. Updates local peer file with clawClanInstalled=true
#
# If claw-clan is already installed on the remote (state.json exists),
# this script behaves as a reinstall: updates scripts but preserves state.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_state

TARGET_USER="${1:?Usage: $0 <user> <ip> [name] [gateway-id] [lead-number]}"
TARGET_IP="${2:?Usage: $0 <user> <ip> [name] [gateway-id] [lead-number]}"
TARGET_NAME="${3:-}"
TARGET_GATEWAY="${4:-}"
TARGET_LEAD="${5:-99}"

MY_IP=$(get_state_field "ip")
MY_USER=$(get_state_field "sshUser")
MY_GATEWAY=$(get_state_field "gatewayId")
MY_NAME=$(get_state_field "name")

# ─── Validate SSH connectivity first ─────────────────────────────────────────

log_info "Testing SSH to ${TARGET_USER}@${TARGET_IP}..."
if ! ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" "echo 'claw-clan-handshake'" 2>/dev/null; then
  log_error "Cannot SSH to ${TARGET_USER}@${TARGET_IP}. Aborting remote install."
  log_error "Ensure SSH keys are exchanged first (see: claw-setup-ssh.sh add)"
  exit 1
fi
log_info "SSH connectivity confirmed."

# ─── Check if already installed ───────────────────────────────────────────────

REMOTE_HAS_STATE=$(ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" \
  "test -f ~/.openclaw/claw-clan/state.json && echo 'yes' || echo 'no'" 2>/dev/null) || REMOTE_HAS_STATE="no"

if [[ "$REMOTE_HAS_STATE" == "yes" ]]; then
  log_info "claw-clan already installed on remote. Performing script update (state preserved)."
  IS_REINSTALL=true
else
  log_info "First-time install on remote. Will create full setup."
  IS_REINSTALL=false
fi

# ─── Resolve defaults ────────────────────────────────────────────────────────

# Get remote hostname for defaults
REMOTE_HOSTNAME=$(ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" "hostname" 2>/dev/null) || REMOTE_HOSTNAME="peer-${TARGET_IP//\./-}"

[[ -z "$TARGET_GATEWAY" ]] && TARGET_GATEWAY="${REMOTE_HOSTNAME}"
[[ -z "$TARGET_NAME" ]] && TARGET_NAME="${REMOTE_HOSTNAME}"

log_info "Remote install target: ${TARGET_NAME} (${TARGET_GATEWAY}) at ${TARGET_USER}@${TARGET_IP}"

# ─── Create directory structure on remote ─────────────────────────────────────

log_info "Creating directory structure on remote..."
ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" bash <<'REMOTE_DIRS'
mkdir -p ~/.openclaw/claw-clan/{peers,logs,scripts/lib,migrations}
mkdir -p ~/.openclaw/skills/claw-clan/references
mkdir -p ~/.openclaw/skills/claw-afterlife/references
REMOTE_DIRS

# ─── Push scripts ─────────────────────────────────────────────────────────────

log_info "Pushing scripts to remote..."

# Use the installed scripts location (where this script lives)
LOCAL_SCRIPTS_DIR="${SCRIPT_DIR}"

# Copy top-level scripts
scp ${CLAW_SSH_OPTS} "${LOCAL_SCRIPTS_DIR}"/*.sh \
  "${TARGET_USER}@${TARGET_IP}:~/.openclaw/claw-clan/scripts/" 2>/dev/null

# Copy lib scripts
scp ${CLAW_SSH_OPTS} "${LOCAL_SCRIPTS_DIR}/lib/"*.sh \
  "${TARGET_USER}@${TARGET_IP}:~/.openclaw/claw-clan/scripts/lib/" 2>/dev/null

# Set executable permissions
ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" bash <<'REMOTE_CHMOD'
chmod +x ~/.openclaw/claw-clan/scripts/*.sh 2>/dev/null || true
chmod +x ~/.openclaw/claw-clan/scripts/lib/*.sh 2>/dev/null || true
REMOTE_CHMOD

log_info "Scripts pushed successfully."

# ─── Push skills (if available locally) ───────────────────────────────────────

SKILLS_BASE="${HOME}/.openclaw/skills"

if [[ -d "${SKILLS_BASE}/claw-clan" ]]; then
  log_info "Pushing claw-clan skill to remote..."
  scp -r ${CLAW_SSH_OPTS} "${SKILLS_BASE}/claw-clan/" \
    "${TARGET_USER}@${TARGET_IP}:~/.openclaw/skills/claw-clan/" 2>/dev/null || true
fi

if [[ -d "${SKILLS_BASE}/claw-afterlife" ]]; then
  log_info "Pushing claw-afterlife skill to remote..."
  scp -r ${CLAW_SSH_OPTS} "${SKILLS_BASE}/claw-afterlife/" \
    "${TARGET_USER}@${TARGET_IP}:~/.openclaw/skills/claw-afterlife/" 2>/dev/null || true
fi

# ─── Push migrations ─────────────────────────────────────────────────────────

if [[ -d "${CLAW_DIR}/migrations" ]]; then
  log_info "Pushing migrations to remote..."
  scp ${CLAW_SSH_OPTS} "${CLAW_DIR}/migrations/"*.sql \
    "${TARGET_USER}@${TARGET_IP}:~/.openclaw/claw-clan/migrations/" 2>/dev/null || true
fi

# ─── Generate state.json on remote (first-time only) ─────────────────────────

if [[ "$IS_REINSTALL" == "false" ]]; then
  log_info "Generating state.json on remote..."

  # Get the remote's LAN IP from the remote machine itself
  REMOTE_LAN_IP=$(ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" \
    "ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print \$1}' || echo '${TARGET_IP}'" 2>/dev/null) || REMOTE_LAN_IP="${TARGET_IP}"

  # Generate state.json on remote
  ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" bash <<REMOTE_STATE
jq -n \\
  --arg gid "${TARGET_GATEWAY}" \\
  --arg name "${TARGET_NAME}" \\
  --argjson lead ${TARGET_LEAD} \\
  --arg ip "${REMOTE_LAN_IP}" \\
  --arg user "${TARGET_USER}" \\
  '{
    gatewayId: \$gid,
    name: \$name,
    leadNumber: \$lead,
    ip: \$ip,
    sshUser: \$user,
    version: "1.0.0",
    registeredAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
    githubRepo: null,
    remoteInstalled: true,
    installedBy: "${MY_GATEWAY}"
  }' > ~/.openclaw/claw-clan/state.json
REMOTE_STATE

  log_info "state.json created on remote."

  # Generate config.json on remote
  ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" bash <<'REMOTE_CONFIG'
jq -n '{
  backend: "json",
  pingIntervalMinutes: 15,
  offlineThresholdPings: 2,
  monitorIntervalMinutes: 5,
  postgres: {host: null, port: 5432, database: "claw_clan", user: null, password: null, deployed: false, deployMethod: null}
}' > ~/.openclaw/claw-clan/config.json
REMOTE_CONFIG

  log_info "config.json created on remote."

  # ─── Add THIS machine as a peer on the remote ────────────────────────────────

  log_info "Adding this machine as a peer on remote..."
  ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" bash <<REMOTE_ADD_PEER
NOW=\$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq -n \\
  --arg gid "${MY_GATEWAY}" \\
  --arg name "${MY_NAME}" \\
  --arg ip "${MY_IP}" \\
  --arg user "${MY_USER}" \\
  --arg now "\$NOW" \\
  '{
    gatewayId: \$gid,
    name: \$name,
    leadNumber: 0,
    ip: \$ip,
    sshUser: \$user,
    status: "online",
    lastSeen: \$now,
    lastPingAttempt: \$now,
    missedPings: 0,
    sshConnectivity: true,
    clawClanInstalled: true,
    mdnsBroadcasting: true,
    addedManually: false
  }' > ~/.openclaw/claw-clan/peers/${MY_GATEWAY}.json
REMOTE_ADD_PEER

  log_info "This machine added as peer on remote."
fi

# ─── Register mDNS on remote (macOS only) ────────────────────────────────────

REMOTE_OS=$(ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" "uname -s" 2>/dev/null) || REMOTE_OS="unknown"

if [[ "$REMOTE_OS" == "Darwin" ]]; then
  log_info "Registering mDNS on remote (macOS)..."
  ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" \
    "~/.openclaw/claw-clan/scripts/claw-register.sh restart" 2>/dev/null || {
    log_warn "mDNS registration on remote failed (non-fatal). Remote agent can re-run later."
  }
else
  log_info "Skipping mDNS registration (remote OS: ${REMOTE_OS}, mDNS requires macOS dns-sd)."
fi

# ─── Install keep-alive cron on remote ────────────────────────────────────────

log_info "Installing keep-alive cron on remote..."
ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" bash <<'REMOTE_CRON'
(crontab -l 2>/dev/null | grep -v 'claw-ping.sh'; \
 echo "*/15 * * * * ${HOME}/.openclaw/claw-clan/scripts/claw-ping.sh >> ${HOME}/.openclaw/claw-clan/logs/ping.log 2>&1 # claw-clan") | crontab -
REMOTE_CRON

log_info "Keep-alive cron installed on remote."

# ─── Update local peer file ──────────────────────────────────────────────────

PEER_FILE="${CLAW_PEERS_DIR}/${TARGET_GATEWAY}.json"
now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

if [[ -f "$PEER_FILE" ]]; then
  # Update existing peer file
  existing=$(cat "$PEER_FILE")
  echo "$existing" | jq \
    --arg now "$now" \
    '.clawClanInstalled = true | .status = "online" | .lastSeen = $now | .sshConnectivity = true' \
    > "$PEER_FILE"
  log_info "Updated local peer file: ${PEER_FILE}"
else
  # Create new peer file
  jq -n \
    --arg gid "$TARGET_GATEWAY" \
    --arg name "$TARGET_NAME" \
    --arg ip "$TARGET_IP" \
    --arg user "$TARGET_USER" \
    --argjson lead "$TARGET_LEAD" \
    --arg now "$now" \
    '{
      gatewayId: $gid,
      name: $name,
      leadNumber: $lead,
      ip: $ip,
      sshUser: $user,
      status: "online",
      lastSeen: $now,
      lastPingAttempt: $now,
      missedPings: 0,
      sshConnectivity: true,
      clawClanInstalled: true,
      mdnsBroadcasting: false,
      addedManually: false,
      remoteInstalled: true
    }' > "$PEER_FILE"
  log_info "Created local peer file: ${PEER_FILE}"
fi

# ─── Verify installation ─────────────────────────────────────────────────────

log_info "Verifying remote installation..."

VERIFY_STATE=$(ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" \
  "test -f ~/.openclaw/claw-clan/state.json && echo 'yes' || echo 'no'" 2>/dev/null) || VERIFY_STATE="no"

VERIFY_SCRIPTS=$(ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" \
  "ls ~/.openclaw/claw-clan/scripts/*.sh 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null) || VERIFY_SCRIPTS="0"

VERIFY_CRON=$(ssh ${CLAW_SSH_OPTS} "${TARGET_USER}@${TARGET_IP}" \
  "crontab -l 2>/dev/null | grep -c 'claw-clan' || echo '0'" 2>/dev/null) || VERIFY_CRON="0"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Remote Install Summary: ${TARGET_NAME} (${TARGET_GATEWAY})"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  Target:      ${TARGET_USER}@${TARGET_IP}"
echo "  Install type: $( [ "$IS_REINSTALL" = "true" ] && echo "Script update (state preserved)" || echo "First-time install" )"
echo ""
echo "  Verification:"
echo "    state.json:    $( [ "$VERIFY_STATE" = "yes" ] && echo "✓ present" || echo "✗ MISSING" )"
echo "    Scripts:       $( [ "$VERIFY_SCRIPTS" -gt 0 ] && echo "✓ ${VERIFY_SCRIPTS} installed" || echo "✗ MISSING" )"
echo "    Cron jobs:     $( [ "$VERIFY_CRON" -gt 0 ] && echo "✓ ${VERIFY_CRON} active" || echo "✗ MISSING" )"
echo "    mDNS:          $( [ "$REMOTE_OS" = "Darwin" ] && echo "✓ registered" || echo "— skipped (not macOS)" )"
echo ""

if [[ "$IS_REINSTALL" == "false" ]]; then
  echo "  ⚠ Note: The remote has default settings (lead=99, no GitHub repo)."
  echo "    The peer's OpenClaw agent can refine these by running 'claw-clan setup'."
  echo "    This will preserve scripts but allow interactive reconfiguration."
fi

echo ""
echo "  INSTALL_STATUS=success"
