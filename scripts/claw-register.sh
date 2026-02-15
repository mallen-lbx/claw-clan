#!/usr/bin/env bash
# claw-register.sh — Register this instance via mDNS and manage LaunchAgent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_state

GATEWAY_ID=$(get_state_field "gatewayId")
NAME=$(get_state_field "name")
LEAD_NUMBER=$(get_state_field "leadNumber")
PORT=22

ACTION="${1:-start}"

install_launchagent() {
  log_info "Installing LaunchAgent for mDNS registration..."

  mkdir -p "$(dirname "${CLAW_LAUNCHAGENT_PLIST}")"

  cat > "${CLAW_LAUNCHAGENT_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${CLAW_LAUNCHAGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/dns-sd</string>
        <string>-R</string>
        <string>${NAME}</string>
        <string>${CLAW_SERVICE_TYPE}</string>
        <string>local</string>
        <string>${PORT}</string>
        <string>gateway=${GATEWAY_ID}</string>
        <string>name=${NAME}</string>
        <string>lead=${LEAD_NUMBER}</string>
        <string>version=${CLAW_VERSION}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${CLAW_LOGS_DIR}/mdns-register.log</string>
    <key>StandardErrorPath</key>
    <string>${CLAW_LOGS_DIR}/mdns-register-err.log</string>
</dict>
</plist>
PLIST

  # Unload if already loaded, then load
  launchctl bootout "gui/$(id -u)/${CLAW_LAUNCHAGENT_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "${CLAW_LAUNCHAGENT_PLIST}"

  log_info "mDNS service registered: ${NAME} (${GATEWAY_ID}) on port ${PORT}"
}

uninstall_launchagent() {
  log_info "Removing LaunchAgent for mDNS registration..."
  launchctl bootout "gui/$(id -u)/${CLAW_LAUNCHAGENT_LABEL}" 2>/dev/null || true
  rm -f "${CLAW_LAUNCHAGENT_PLIST}"
  log_info "mDNS registration stopped."
}

status_launchagent() {
  if launchctl print "gui/$(id -u)/${CLAW_LAUNCHAGENT_LABEL}" &>/dev/null; then
    log_info "mDNS LaunchAgent is RUNNING"
    return 0
  else
    log_warn "mDNS LaunchAgent is NOT running"
    return 1
  fi
}

case "$ACTION" in
  start|install)
    install_launchagent
    ;;
  stop|uninstall)
    uninstall_launchagent
    ;;
  status)
    status_launchagent
    ;;
  restart)
    uninstall_launchagent
    sleep 1
    install_launchagent
    ;;
  *)
    echo "Usage: $0 {start|stop|status|restart}"
    exit 1
    ;;
esac
