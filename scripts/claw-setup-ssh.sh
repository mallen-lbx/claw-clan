#!/usr/bin/env bash
# claw-setup-ssh.sh — Generate SSH keys and test/guide SSH connectivity

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_state

ACTION="${1:-check}"
TARGET_USER="${2:-}"
TARGET_IP="${3:-}"

MY_IP=$(get_state_field "ip")
MY_USER=$(get_state_field "sshUser")
MY_GATEWAY=$(get_state_field "gatewayId")
MY_NAME=$(get_state_field "name")

SSH_KEY="${HOME}/.ssh/id_ed25519"

ensure_key() {
  if [[ ! -f "$SSH_KEY" ]]; then
    log_info "No SSH key found. Generating ed25519 key..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N ""
    log_info "SSH key generated: ${SSH_KEY}"
  else
    log_info "SSH key exists: ${SSH_KEY}"
  fi
}

test_ssh() {
  local user="$1"
  local ip="$2"
  log_info "Testing SSH to ${user}@${ip}..."
  if ssh ${CLAW_SSH_OPTS} "${user}@${ip}" "echo 'claw-clan-handshake'" 2>/dev/null; then
    log_info "SSH to ${user}@${ip}: SUCCESS"
    return 0
  else
    log_warn "SSH to ${user}@${ip}: FAILED"
    return 1
  fi
}

print_setup_instructions() {
  local target_user="$1"
  local target_ip="$2"
  local target_name="${3:-unknown}"
  local target_gateway="${4:-unknown}"

  cat <<EOF

Cannot SSH to ${target_name} (${target_gateway}) at ${target_ip}.
To enable claw-clan connectivity:

On THIS machine (${MY_NAME} / ${MY_GATEWAY}):

  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  ssh-copy-id -i ~/.ssh/id_ed25519.pub ${target_user}@${target_ip}

On ${target_name} (${target_ip}):

  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  ssh-copy-id -i ~/.ssh/id_ed25519.pub ${MY_USER}@${MY_IP}

After both machines have exchanged keys, run: claw-clan verify

EOF
}

check_all_peers() {
  local failures=0
  for peer_file in "${CLAW_PEERS_DIR}"/*.json; do
    [[ -f "$peer_file" ]] || continue
    local peer_gw peer_ip peer_user peer_name
    peer_gw=$(jq -r '.gatewayId' "$peer_file")
    peer_ip=$(jq -r '.ip' "$peer_file")
    peer_user=$(jq -r '.sshUser // "'"$MY_USER"'"' "$peer_file")
    peer_name=$(jq -r '.name // "unknown"' "$peer_file")

    if ! test_ssh "$peer_user" "$peer_ip"; then
      print_setup_instructions "$peer_user" "$peer_ip" "$peer_name" "$peer_gw"
      ((failures++))

      # Update peer status
      local existing
      existing=$(cat "$peer_file")
      echo "$existing" | jq '.sshConnectivity = false' > "$peer_file"
    else
      local existing
      existing=$(cat "$peer_file")
      echo "$existing" | jq '.sshConnectivity = true' > "$peer_file"
    fi
  done

  if [[ $failures -eq 0 ]]; then
    log_info "All peers are SSH-accessible."
  else
    log_warn "$failures peer(s) not SSH-accessible. See instructions above."
  fi
  return $failures
}

add_peer() {
  local user="$1"
  local ip="$2"
  local peer_name="${3:-}"
  local peer_gateway="${4:-}"

  [[ -z "$user" || -z "$ip" ]] && { echo "Usage: $0 add <user> <ip> [name] [gateway-id]"; return 1; }

  # Default gateway to IP-based identifier if not provided
  [[ -z "$peer_gateway" ]] && peer_gateway="peer-${ip//\./-}"
  [[ -z "$peer_name" ]] && peer_name="$peer_gateway"

  ensure_key

  log_info "Adding peer: ${peer_name} (${peer_gateway}) at ${user}@${ip}"

  # Test SSH connectivity
  local ssh_ok=false
  if test_ssh "$user" "$ip"; then
    ssh_ok=true
  fi

  # Create peer file regardless — we want to track the peer even if SSH fails
  local peer_file="${CLAW_PEERS_DIR}/${peer_gateway}.json"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  jq -n \
    --arg gid "$peer_gateway" \
    --arg name "$peer_name" \
    --arg ip "$ip" \
    --arg user "$user" \
    --argjson ssh_ok "$( [ "$ssh_ok" = "true" ] && echo "true" || echo "false" )" \
    --arg now "$now" \
    '{
      gatewayId: $gid,
      name: $name,
      leadNumber: 0,
      ip: $ip,
      sshUser: $user,
      status: (if $ssh_ok then "online" else "unknown" end),
      lastSeen: (if $ssh_ok then $now else null end),
      lastPingAttempt: $now,
      missedPings: 0,
      sshConnectivity: $ssh_ok,
      clawClanInstalled: false,
      mdnsBroadcasting: false,
      addedManually: true
    }' > "$peer_file"

  if [[ "$ssh_ok" == "true" ]]; then
    log_info "Peer added and SSH verified: ${peer_name} (${user}@${ip})"

    # Check if claw-clan is installed on the remote peer
    local remote_has_claw="false"
    local remote_state_exists
    remote_state_exists=$(ssh ${CLAW_SSH_OPTS} "${user}@${ip}" \
      "test -f ~/.openclaw/claw-clan/state.json && echo 'yes' || echo 'no'" 2>/dev/null) || remote_state_exists="no"

    if [[ "$remote_state_exists" == "yes" ]]; then
      remote_has_claw="true"
      # Update peer file to reflect claw-clan is installed
      local updated
      updated=$(cat "$peer_file")
      echo "$updated" | jq '.clawClanInstalled = true' > "$peer_file"
      log_info "claw-clan is installed on ${peer_name}."
    else
      log_info "claw-clan is NOT installed on ${peer_name}."
    fi

    echo "SSH_STATUS=success"
    echo "CLAW_INSTALLED=${remote_has_claw}"
  else
    print_setup_instructions "$user" "$ip" "$peer_name" "$peer_gateway"
    echo "SSH_STATUS=failed"
    echo "CLAW_INSTALLED=unknown"
  fi
}

case "$ACTION" in
  keygen)
    ensure_key
    ;;
  test)
    [[ -z "$TARGET_USER" || -z "$TARGET_IP" ]] && { echo "Usage: $0 test <user> <ip>"; exit 1; }
    test_ssh "$TARGET_USER" "$TARGET_IP"
    ;;
  check)
    ensure_key
    check_all_peers
    ;;
  add)
    add_peer "$TARGET_USER" "$TARGET_IP" "${4:-}" "${5:-}"
    ;;
  remote-install)
    [[ -z "$TARGET_USER" || -z "$TARGET_IP" ]] && { echo "Usage: $0 remote-install <user> <ip> [name] [gateway-id] [lead-number]"; exit 1; }
    "${SCRIPT_DIR}/claw-remote-install.sh" "$TARGET_USER" "$TARGET_IP" "${4:-}" "${5:-}" "${6:-99}"
    ;;
  *)
    echo "Usage: $0 {keygen|test <user> <ip>|check|add <user> <ip> [name] [gateway-id]|remote-install <user> <ip> [name] [gw] [lead]}"
    exit 1
    ;;
esac
