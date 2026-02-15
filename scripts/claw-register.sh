#!/usr/bin/env bash
# claw-register.sh — Register this instance via mDNS and manage persistence
# macOS: LaunchAgent + dns-sd
# Linux: systemd user service + avahi-publish

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_state

GATEWAY_ID=$(get_state_field "gatewayId")
NAME=$(get_state_field "name")
LEAD_NUMBER=$(get_state_field "leadNumber")
PORT=22

ACTION="${1:-start}"

# ═══════════════════════════════════════════════════════════════════════════════
# macOS: LaunchAgent + dns-sd
# ═══════════════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════════════
# Linux: systemd user service + avahi-publish
# ═══════════════════════════════════════════════════════════════════════════════

install_systemd_service() {
  log_info "Installing systemd user service for mDNS registration..."

  local service_dir
  service_dir="$(dirname "${CLAW_MDNS_SERVICE_PATH}")"
  mkdir -p "$service_dir"

  cat > "${CLAW_MDNS_SERVICE_PATH}" <<UNIT
[Unit]
Description=claw-clan mDNS registration (${NAME})
After=network-online.target avahi-daemon.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/avahi-publish -s "${NAME}" ${CLAW_SERVICE_TYPE} ${PORT} "gateway=${GATEWAY_ID}" "name=${NAME}" "lead=${LEAD_NUMBER}" "version=${CLAW_VERSION}"
Restart=always
RestartSec=5
StandardOutput=append:${CLAW_LOGS_DIR}/mdns-register.log
StandardError=append:${CLAW_LOGS_DIR}/mdns-register-err.log

[Install]
WantedBy=default.target
UNIT

  # Reload systemd, enable and start
  systemctl --user daemon-reload
  systemctl --user enable --now claw-clan-mdns.service

  log_info "mDNS service registered: ${NAME} (${GATEWAY_ID}) on port ${PORT}"
}

uninstall_systemd_service() {
  log_info "Removing systemd user service for mDNS registration..."
  systemctl --user disable --now claw-clan-mdns.service 2>/dev/null || true
  rm -f "${CLAW_MDNS_SERVICE_PATH}"
  systemctl --user daemon-reload
  log_info "mDNS registration stopped."
}

status_systemd_service() {
  if systemctl --user is-active --quiet claw-clan-mdns.service 2>/dev/null; then
    log_info "mDNS systemd service is RUNNING"
    return 0
  else
    log_warn "mDNS systemd service is NOT running"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatch: route actions to OS-specific implementation
# ═══════════════════════════════════════════════════════════════════════════════

do_start() {
  case "$CLAW_OS" in
    Darwin) install_launchagent ;;
    Linux)  install_systemd_service ;;
    *)      log_error "Unsupported OS: $CLAW_OS"; exit 1 ;;
  esac
}

do_stop() {
  case "$CLAW_OS" in
    Darwin) uninstall_launchagent ;;
    Linux)  uninstall_systemd_service ;;
    *)      log_error "Unsupported OS: $CLAW_OS"; exit 1 ;;
  esac
}

do_status() {
  case "$CLAW_OS" in
    Darwin) status_launchagent ;;
    Linux)  status_systemd_service ;;
    *)      log_error "Unsupported OS: $CLAW_OS"; exit 1 ;;
  esac
}

case "$ACTION" in
  start|install)
    do_start
    ;;
  stop|uninstall)
    do_stop
    ;;
  status)
    do_status
    ;;
  restart)
    do_stop
    sleep 1
    do_start
    ;;
  *)
    echo "Usage: $0 {start|stop|status|restart}"
    exit 1
    ;;
esac
