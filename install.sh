#!/usr/bin/env bash
set -euo pipefail

# ─── Colors & helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_ok()   { echo -e " ${GREEN}✅${NC} $1"; }
log_err()  { echo -e " ${RED}❌${NC} $1"; exit 1; }
log_warn() { echo -e " ${YELLOW}⚠️${NC}  $1"; }
log_info() { echo -e " ${CYAN}ℹ${NC}  $1"; }

# ─── Constants ───────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/frostdeploy"
RELEASES_DIR="${INSTALL_DIR}/releases"
DATA_DIR="/var/lib/frostdeploy"
BACKUP_DIR="${DATA_DIR}/backups"
ENV_FILE="${INSTALL_DIR}/.env"
DIST_REPO="ARTFROST1/FrostDeploy"
SERVICE_NAME="frostdeploy"
FD_USER="frostdeploy"
FD_PORT=9000
NODE_MAJOR=22
CADDYFILE="/etc/caddy/Caddyfile"

# ─── 0. Token ────────────────────────────────────────────────────────────────
# FD_DIST_TOKEN: optional read-only fine-grained PAT for the dist repo. Only
# needed when the dist repo is private (e.g. a studio's internal server).
# Comes from the environment on first install (curl … | sudo -E bash), from
# .env afterwards. Public repo (default) installs work with no token at all.
if [[ -z "${FD_DIST_TOKEN:-}" && -f "${ENV_FILE}" ]]; then
  FD_DIST_TOKEN="$(grep -E '^FD_DIST_TOKEN=' "${ENV_FILE}" | cut -d= -f2- || true)"
fi
if [[ -n "${FD_DIST_TOKEN:-}" ]]; then
  log_info "FD_DIST_TOKEN обнаружен — запросы к dist-репозиторию будут авторизованы"
else
  log_info "Публичный режим: без токена дистрибуции"
fi

# jq — для разбора ответов Releases API
if ! command -v jq >/dev/null 2>&1; then
  # Exit status is checked explicitly (unlike a bare `cmd >/dev/null 2>&1;
  # log_ok`) so a non-root run or offline apt fails loudly here instead of
  # limping on to a `jq: command not found` deep inside section 7.
  if apt-get install -y -qq jq >/dev/null 2>&1; then
    log_ok "jq installed"
  else
    log_err "Failed to install jq (are you root? is apt reachable?)"
  fi
fi

# ─── Banner ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   FrostDeploy Installer v0.1         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ─── 1. Check root ───────────────────────────────────────────────────────────
if [[ $(id -u) -ne 0 ]]; then
  log_err "This script must be run as root: sudo bash install.sh"
fi
log_ok "Running as root"

# ─── 2. Check OS ─────────────────────────────────────────────────────────────
if [[ ! -f /etc/os-release ]]; then
  log_err "Cannot detect OS — /etc/os-release not found"
fi

# shellcheck source=/dev/null
source /etc/os-release

SUPPORTED=false
case "${ID}" in
  ubuntu)
    MAJOR_VER="${VERSION_ID%%.*}"
    if [[ "${MAJOR_VER}" -ge 22 ]]; then
      SUPPORTED=true
    fi
    ;;
  debian)
    MAJOR_VER="${VERSION_ID%%.*}"
    if [[ "${MAJOR_VER}" -ge 12 ]]; then
      SUPPORTED=true
    fi
    ;;
esac

if [[ "${SUPPORTED}" != "true" ]]; then
  log_err "Unsupported OS: ${PRETTY_NAME}. FrostDeploy requires Ubuntu 22.04+ or Debian 12+"
fi
log_ok "OS: ${PRETTY_NAME}"

# ─── 3. Check / install Node.js 20+ ─────────────────────────────────────────
install_node() {
  log_info "Installing Node.js ${NODE_MAJOR}.x via NodeSource..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg > /dev/null 2>&1
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  apt-get install -y -qq nodejs > /dev/null 2>&1
}

if command -v node &> /dev/null; then
  NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
  if [[ "${NODE_VER}" -ge 20 ]]; then
    log_ok "Node.js $(node -v) detected"
  else
    log_warn "Node.js $(node -v) is too old (need 20+). Upgrading..."
    install_node
    log_ok "Node.js $(node -v) installed"
  fi
else
  install_node
  log_ok "Node.js $(node -v) installed"
fi

# ─── 4. Install / detect Caddy (coexist-aware) ──────────────────────────────
# FOREIGN_CADDY=true means Caddy is already here serving someone else's sites
# (a non-trivial /etc/caddy/Caddyfile). We then MUST NOT reconfigure it — the
# panel manages Caddy via the admin API (POST /load), which replaces the whole
# config and would wipe the existing sites. On such a server the panel stays on
# :${FD_PORT} and its own-domain auto-config is disabled (needs coexist mode).
FOREIGN_CADDY=false
if command -v caddy &> /dev/null; then
  log_ok "Caddy $(caddy version | head -1) detected"
  if [[ -f "${CADDYFILE}" ]] && [[ "$(grep -cvE '^\s*(#|\{|\}|admin |$)' "${CADDYFILE}" 2>/dev/null)" -gt 0 ]]; then
    FOREIGN_CADDY=true
    log_warn "На сервере уже есть непустой ${CADDYFILE} — Caddy обслуживает чужие сайты."
    log_warn "НЕ трогаю Caddy, чтобы их не сломать. Панель будет доступна на порту ${FD_PORT}."
    log_warn "Авто-настройка домена панели из UI в этом режиме отключена (нужен coexist-режим)."
  fi
else
  log_info "Installing Caddy..."
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https > /dev/null 2>&1
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy > /dev/null 2>&1
  log_ok "Caddy $(caddy version | head -1) installed"
fi

# ─── 5. Install pnpm ────────────────────────────────────────────────────────
if command -v pnpm &> /dev/null; then
  log_ok "pnpm $(pnpm -v) detected"
else
  log_info "Installing pnpm via corepack..."
  corepack enable
  corepack prepare pnpm@latest --activate
  log_ok "pnpm $(pnpm -v) installed"
fi

# Also ensure git is available
if ! command -v git &> /dev/null; then
  log_info "Installing git..."
  apt-get install -y -qq git > /dev/null 2>&1
  log_ok "git installed"
fi

# ─── 6. Create user ─────────────────────────────────────────────────────────
if id "${FD_USER}" &> /dev/null; then
  log_ok "User '${FD_USER}' already exists"
else
  useradd --system --shell /usr/sbin/nologin --home-dir "${INSTALL_DIR}" "${FD_USER}"
  log_ok "User '${FD_USER}' created"
fi

# ─── 7. Download latest release (заменяет git clone) ────────────────────────
# AUTH is only populated when FD_DIST_TOKEN is set; against a public dist repo
# it stays empty and curl is called with no Authorization header at all.
AUTH=()
[[ -n "${FD_DIST_TOKEN:-}" ]] && AUTH=(-H "Authorization: Bearer ${FD_DIST_TOKEN}")

gh_api() { curl -fsSL "${AUTH[@]}" \
  -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${DIST_REPO}$1"; }

LATEST_JSON="$(gh_api /releases/latest)" || log_err "Cannot reach ${DIST_REPO} releases (network? private repo needs FD_DIST_TOKEN?)"
TAG="$(echo "${LATEST_JSON}" | jq -r .tag_name)"
VERSION="${TAG#v}"
# Tag-derived; goes into filesystem paths (incl. rm -rf) — refuse anything
# that could traverse (../) or start with a dot/dash.
[[ "${VERSION}" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] \
  || log_err "refusing suspicious version '${VERSION}'"
ASSET_ID="$(echo "${LATEST_JSON}" | jq -r '.assets[] | select(.name|endswith("linux-x64.tar.gz")) | .id')"
[[ -n "${ASSET_ID}" && "${ASSET_ID}" != "null" ]] || log_err "Release ${TAG} has no linux-x64 tarball"

if [[ -d "${RELEASES_DIR}/${VERSION}" ]]; then
  log_ok "Release ${VERSION} already present"
else
  log_info "Downloading FrostDeploy ${VERSION}..."
  TMP_TGZ="$(mktemp)"
  curl -fsSL "${AUTH[@]}" -H "Accept: application/octet-stream" \
    -o "${TMP_TGZ}" "https://api.github.com/repos/${DIST_REPO}/releases/assets/${ASSET_ID}"
  mkdir -p "${RELEASES_DIR}"
  tar -xzf "${TMP_TGZ}" -C "${RELEASES_DIR}"
  mv "${RELEASES_DIR}/frostdeploy-${VERSION}" "${RELEASES_DIR}/${VERSION}"
  rm -f "${TMP_TGZ}"
  log_ok "Release ${VERSION} unpacked"
fi
ln -sfn "${RELEASES_DIR}/${VERSION}" "${INSTALL_DIR}/current"
log_ok "current → ${VERSION}"

# ─── 8. (секция pnpm install/build УДАЛЕНА — тарбол уже собран) ─────────────

# ─── 9. Data dirs & .env (как раньше, плюс FD_DIST_TOKEN) ───────────────────
GUEST_BUILD_DIR="${DATA_DIR}/guest-builds"
mkdir -p "${DATA_DIR}" "${BACKUP_DIR}" "${GUEST_BUILD_DIR}"
chown -R "${FD_USER}:${FD_USER}" "${DATA_DIR}"

if [[ -f "${ENV_FILE}" ]]; then
  log_ok ".env exists — preserving"
  if [[ -n "${FD_DIST_TOKEN:-}" ]]; then
    grep -q '^FD_DIST_TOKEN=' "${ENV_FILE}" || echo "FD_DIST_TOKEN=${FD_DIST_TOKEN}" >> "${ENV_FILE}"
  fi
else
  ENCRYPTION_KEY=$(openssl rand -hex 32)
  SESSION_SECRET=$(openssl rand -hex 32)
  cat > "${ENV_FILE}" <<EOF
NODE_ENV=production
PORT=${FD_PORT}
DATABASE_PATH=${DATA_DIR}/data.db
BACKUP_DIR=${BACKUP_DIR}
FD_GUEST_BUILD_DIR=${GUEST_BUILD_DIR}
ENCRYPTION_KEY=${ENCRYPTION_KEY}
SESSION_SECRET=${SESSION_SECRET}
EOF
  if [[ -n "${FD_DIST_TOKEN:-}" ]]; then
    echo "FD_DIST_TOKEN=${FD_DIST_TOKEN}" >> "${ENV_FILE}"
  fi
  chmod 600 "${ENV_FILE}"
  log_ok ".env created"
fi
chown -R "${FD_USER}:${FD_USER}" "${INSTALL_DIR}"

# ─── 9b. prepare-host из релиза ─────────────────────────────────────────────
bash "${INSTALL_DIR}/current/scripts/prepare-host.sh"
log_ok "Host prepared as a deploy target (/srv/frostdeploy + sudoers)"

# ─── 10. Units & CLI из релиза ──────────────────────────────────────────────
install -m 644 "${INSTALL_DIR}/current/scripts/frostdeploy.service" \
  "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" --quiet
log_ok "Systemd unit installed and enabled"
install -m 755 "${INSTALL_DIR}/current/scripts/frostdeploy" /usr/local/bin/frostdeploy
log_ok "CLI installed: frostdeploy {status|logs|restart|update|rollback|reset-password}"

# ─── 11. Configure Caddy (admin-API model, --resume) ────────────────────────
# The panel drives Caddy entirely through the admin API; --resume persists the
# last loaded config across restarts, so no Caddyfile is needed. On a foreign
# Caddy we skip ALL of this to avoid disturbing existing sites.
if [[ "${FOREIGN_CADDY}" == "true" ]]; then
  log_warn "Пропускаю настройку Caddy (обслуживает чужие сайты). Панель — на :${FD_PORT}."
else
  mkdir -p /var/lib/caddy /var/log/caddy /etc/systemd/system/caddy.service.d
  cat > /etc/systemd/system/caddy.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/caddy run --environ --resume
EOF
  systemctl daemon-reload
  systemctl enable caddy --quiet 2>/dev/null || true
  systemctl restart caddy
  log_ok "Caddy runs with --resume (config managed by the panel via admin API)"
fi

# ─── 11c. Open the panel port in ufw (only if ufw is already active) ────────
# Non-destructive: ADDS one allow rule, never enables ufw and never closes
# anything. On a server with ufw active the panel port would otherwise be
# unreachable from the browser during setup.
if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${FD_PORT}/tcp" > /dev/null 2>&1 && log_ok "ufw: разрешён порт ${FD_PORT}/tcp (панель)"
fi

# ─── 12. Start FrostDeploy ──────────────────────────────────────────────────
systemctl restart "${SERVICE_NAME}"

# Wait a few seconds for the service to start
sleep 3

if systemctl is-active --quiet "${SERVICE_NAME}"; then
  log_ok "FrostDeploy service is running"
else
  log_err "FrostDeploy service failed to start. Check logs: journalctl -u ${SERVICE_NAME} -n 50"
fi

# ─── 13. Final output ───────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           FrostDeploy is ready! 🚀                  ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}                                                      ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  URL:    ${CYAN}http://${SERVER_IP}:${FD_PORT}${NC}                  ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}                                                      ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  Open this URL in your browser to start the          ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  Setup Wizard and create your admin account.         ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}                                                      ${BOLD}║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  Useful commands:                                    ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}    systemctl status ${SERVICE_NAME}               ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}    journalctl -u ${SERVICE_NAME} -f              ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}    systemctl restart ${SERVICE_NAME}              ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}    frostdeploy update | rollback                     ${BOLD}║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
