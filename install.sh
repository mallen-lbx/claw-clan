#!/usr/bin/env bash
set -euo pipefail

# ─── Banner ──────────────────────────────────────────────────────────────────

cat << 'BANNER'

   _____ _                       _____ _
  / ____| |                     / ____| |
 | |    | | __ ___      __     | |    | | __ _ _ __
 | |    | |/ _` \ \ /\ / /___ | |    | |/ _` | '_ \
 | |____| | (_| |\ V  V /____|| |____| | (_| | | | |
  \_____|_|\__,_| \_/\_/       \_____|_|\__,_|_| |_|

  OpenClaw Fleet Coordination
  LAN discovery | Health monitoring | Skill sharing

BANNER

# ─── Constants ───────────────────────────────────────────────────────────────

CLAW_DIR="${HOME}/.openclaw/claw-clan"
SKILLS_DIR="${HOME}/.openclaw/skills"
SCRIPT_SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Helpers ─────────────────────────────────────────────────────────────────

info()  { printf '  [INFO]  %s\n' "$1"; }
ok()    { printf '  [ OK ]  %s\n' "$1"; }
warn()  { printf '  [WARN]  %s\n' "$1"; }
fail()  { printf '  [FAIL]  %s\n' "$1"; exit 1; }

# ─── Prerequisites ──────────────────────────────────────────────────────────

echo "Checking prerequisites..."
echo ""

# Bash 4+
bash_major="${BASH_VERSINFO[0]}"
if (( bash_major < 4 )); then
    fail "Bash 4+ is required (found ${BASH_VERSION}). On macOS: brew install bash"
else
    ok "bash ${BASH_VERSION}"
fi

# ssh
if ! command -v ssh &>/dev/null; then
    fail "ssh is required but not found"
else
    ok "ssh"
fi

# ssh-keygen
if ! command -v ssh-keygen &>/dev/null; then
    fail "ssh-keygen is required but not found"
else
    ok "ssh-keygen"
fi

# jq
if ! command -v jq &>/dev/null; then
    fail "jq is required but not found. Install: brew install jq (macOS) or apt install jq (Linux)"
else
    ok "jq $(jq --version 2>/dev/null || echo '')"
fi

# crontab
if ! command -v crontab &>/dev/null; then
    fail "crontab is required but not found"
else
    ok "crontab"
fi

# Platform-specific: mDNS discovery tool
case "$(uname -s)" in
    Darwin)
        if ! command -v dns-sd &>/dev/null; then
            fail "dns-sd is required on macOS but not found (should be built-in)"
        else
            ok "dns-sd (macOS mDNS)"
        fi
        ;;
    Linux)
        if ! command -v avahi-browse &>/dev/null; then
            warn "avahi-browse not found. mDNS discovery will not work without it."
            warn "Install: sudo apt install avahi-utils (Debian/Ubuntu)"
        else
            ok "avahi-browse (Linux mDNS)"
        fi
        ;;
    *)
        warn "Unsupported platform: $(uname -s). mDNS discovery may not work."
        ;;
esac

echo ""

# ─── Directory Structure ────────────────────────────────────────────────────

echo "Creating directory structure..."
echo ""

directories=(
    "${CLAW_DIR}"
    "${CLAW_DIR}/peers"
    "${CLAW_DIR}/logs"
    "${CLAW_DIR}/scripts"
    "${CLAW_DIR}/scripts/lib"
    "${CLAW_DIR}/migrations"
    "${SKILLS_DIR}/claw-clan"
    "${SKILLS_DIR}/claw-clan/references"
    "${SKILLS_DIR}/claw-afterlife"
    "${SKILLS_DIR}/claw-afterlife/references"
)

for dir in "${directories[@]}"; do
    mkdir -p "${dir}"
done

ok "Directory structure created"

# ─── Copy Scripts ────────────────────────────────────────────────────────────

echo ""
echo "Installing scripts..."
echo ""

# Copy top-level scripts
script_count=0
for script in "${SCRIPT_SOURCE_DIR}/scripts/"*.sh; do
    [ -f "${script}" ] || continue
    cp "${script}" "${CLAW_DIR}/scripts/"
    ok "scripts/$(basename "${script}")"
    (( script_count++ ))
done

# Copy lib scripts
lib_count=0
for lib in "${SCRIPT_SOURCE_DIR}/scripts/lib/"*.sh; do
    [ -f "${lib}" ] || continue
    cp "${lib}" "${CLAW_DIR}/scripts/lib/"
    ok "scripts/lib/$(basename "${lib}")"
    (( lib_count++ ))
done

# Set executable permissions on all scripts
chmod +x "${CLAW_DIR}/scripts/"*.sh 2>/dev/null || true
chmod +x "${CLAW_DIR}/scripts/lib/"*.sh 2>/dev/null || true

# ─── Copy Skills ─────────────────────────────────────────────────────────────

echo ""
echo "Installing skills..."
echo ""

# claw-clan skill
skill_count=0
if [ -d "${SCRIPT_SOURCE_DIR}/skills/claw-clan" ]; then
    cp -r "${SCRIPT_SOURCE_DIR}/skills/claw-clan/." "${SKILLS_DIR}/claw-clan/"
    ok "skills/claw-clan"
    (( skill_count++ ))
fi

# claw-afterlife skill
if [ -d "${SCRIPT_SOURCE_DIR}/skills/claw-afterlife" ]; then
    cp -r "${SCRIPT_SOURCE_DIR}/skills/claw-afterlife/." "${SKILLS_DIR}/claw-afterlife/"
    ok "skills/claw-afterlife"
    (( skill_count++ ))
fi

# ─── Copy Migrations ────────────────────────────────────────────────────────

echo ""
echo "Installing migrations..."
echo ""

migration_count=0
if [ -d "${SCRIPT_SOURCE_DIR}/migrations" ]; then
    for migration in "${SCRIPT_SOURCE_DIR}/migrations/"*.sql; do
        [ -f "${migration}" ] || continue
        cp "${migration}" "${CLAW_DIR}/migrations/"
        ok "migrations/$(basename "${migration}")"
        (( migration_count++ ))
    done
fi

# ─── Status ──────────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────────────────"
echo ""

# Summary
echo "  Installed:"
echo "    ${script_count} script(s) + ${lib_count} lib module(s)"
echo "    ${skill_count} skill(s)"
echo "    ${migration_count} migration(s)"
echo ""
echo "  Locations:"
echo "    Scripts:    ${CLAW_DIR}/scripts/"
echo "    Skills:     ${SKILLS_DIR}/claw-clan/"
echo "                ${SKILLS_DIR}/claw-afterlife/"
echo "    Migrations: ${CLAW_DIR}/migrations/"
echo "    Logs:       ${CLAW_DIR}/logs/"
echo "    Peers:      ${CLAW_DIR}/peers/"
echo ""

# Detect fresh install vs recovery reinstall
if [ -f "${CLAW_DIR}/state.json" ]; then
    echo "  Recovery install complete. Existing configuration preserved."
    echo ""
    echo "  state.json found at: ${CLAW_DIR}/state.json"
    echo "  Your peer identity, fleet membership, and cron jobs are intact."
else
    echo "  Fresh install complete."
    echo "  Run claw-clan setup in your OpenClaw agent to initialize."
fi

echo ""
