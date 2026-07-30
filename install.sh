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

# jq — для разбора ответов Releases API.
#
# `apt-get update` ОБЯЗАТЕЛЕН перед первой установкой. На свежем образе
# /var/lib/apt/lists пуст, и apt не знает ни одного пакета: установщик падал на
# самой первой команде с `E: Unable to locate package jq`. Воспроизведено на
# чистом Debian 12 — то есть на всём, с чего начинает любой новый пользователь.
#
# Ошибка apt показывается целиком. Прежний текст («are you root? is apt
# reachable?») назвал две причины, и обе были неверны: скрипт шёл от root, apt
# был доступен. Догадка вместо диагностики хуже, чем отсутствие диагностики, —
# она уводит от настоящей причины.
if ! command -v jq >/dev/null 2>&1; then
  log_info "Обновляю списки пакетов apt..."
  if ! APT_OUT="$(apt-get update -qq 2>&1)"; then
    log_err "apt-get update не прошёл:\n${APT_OUT}"
  fi
  if APT_OUT="$(apt-get install -y -qq jq 2>&1)"; then
    log_ok "jq installed"
  else
    log_err "Не удалось установить jq:\n${APT_OUT}"
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

# ─── Подпись релиза (аудит C-5) ─────────────────────────────────────────────
# Тарбол распаковывается КАК ROOT. Без проверки подписи тот, кто может записать
# один release-asset, получает root на каждом сервере при следующем
# install/update — и молча, потому что подменённый архив ничем не отличался от
# настоящего.
#
# Публичный ключ. Не секрет: он существует, чтобы отличить наш артефакт от
# чужого. Приватная половина живёт только в секретах CI (FD_SIGNING_KEY) и
# отделена от DIST_PUSH_TOKEN — утёкший push-токен сам по себе больше не даёт
# отравить серверы, валидную подпись им не сделать.
#
# KEEP IN SYNC: тот же ключ и та же функция продублированы в
# scripts/dist/frostdeploy (путь `frostdeploy update`). Оба скрипта
# распространяются отдельно, общий файл им подключить неоткуда.
read -r -d '' FD_RELEASE_PUBKEY <<'PUBKEY' || true
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAH7ZmEJxyrsoTPoWG+4wLKkf6nwGiwoZWomiJcdY6jOo=
-----END PUBLIC KEY-----
PUBKEY

# verify_release <tarball> <sig> — падает, если подпись не сходится.
verify_release() {
  local tgz="$1" sig="$2" pub
  command -v openssl >/dev/null 2>&1 || log_err "openssl не найден — проверить подпись релиза нечем"
  [[ -s "${sig}" ]] || log_err "у релиза нет файла подписи (.sig) — установка ОСТАНОВЛЕНА"
  pub="$(mktemp)"
  printf '%s\n' "${FD_RELEASE_PUBKEY}" > "${pub}"
  if ! openssl pkeyutl -verify -rawin -pubin -inkey "${pub}" -sigfile "${sig}" -in "${tgz}" >/dev/null 2>&1; then
    rm -f "${pub}"
    log_err "ПОДПИСЬ РЕЛИЗА НЕ СХОДИТСЯ. Архив подменён или собран не нами — установка ОСТАНОВЛЕНА."
  fi
  rm -f "${pub}"
  log_ok "подпись релиза проверена (ed25519)"
}

if [[ -d "${RELEASES_DIR}/${VERSION}" ]]; then
  log_ok "Release ${VERSION} already present"
else
  log_info "Downloading FrostDeploy ${VERSION}..."
  TMP_TGZ="$(mktemp)"
  TMP_SIG="$(mktemp)"
  curl -fsSL "${AUTH[@]}" -H "Accept: application/octet-stream" \
    -o "${TMP_TGZ}" "https://api.github.com/repos/${DIST_REPO}/releases/assets/${ASSET_ID}"
  SIG_ID="$(echo "${LATEST_JSON}" | jq -r '.assets[] | select(.name|endswith(".tar.gz.sig")) | .id')"
  if [[ -n "${SIG_ID}" && "${SIG_ID}" != "null" ]]; then
    curl -fsSL "${AUTH[@]}" -H "Accept: application/octet-stream" \
      -o "${TMP_SIG}" "https://api.github.com/repos/${DIST_REPO}/releases/assets/${SIG_ID}"
  fi
  # ПРОВЕРКА ДО РАСПАКОВКИ: после tar злоумышленный код уже на диске, а
  # prepare-host.sh запускается из этого самого дерева от root.
  verify_release "${TMP_TGZ}" "${TMP_SIG}"
  mkdir -p "${RELEASES_DIR}"
  # --no-same-owner/--no-same-permissions: архив не должен диктовать, кому будут
  # принадлежать файлы и с какими правами (setuid в том числе).
  tar -xzf "${TMP_TGZ}" --no-same-owner --no-same-permissions -C "${RELEASES_DIR}"
  mv "${RELEASES_DIR}/frostdeploy-${VERSION}" "${RELEASES_DIR}/${VERSION}"
  rm -f "${TMP_TGZ}" "${TMP_SIG}"
  log_ok "Release ${VERSION} unpacked"
fi
ln -sfn "${RELEASES_DIR}/${VERSION}" "${INSTALL_DIR}/current"
log_ok "current → ${VERSION}"

# ─── 8. (секция pnpm install/build УДАЛЕНА — тарбол уже собран) ─────────────

# ─── 9. Data dirs & .env (как раньше, плюс FD_DIST_TOKEN) ───────────────────
GUEST_BUILD_DIR="${DATA_DIR}/guest-builds"
# 750, not the umask default 755: data.db holds ssh_keys, env_variables and
# sessions (audit H-1 — a session token needs no decryption to be replayed).
install -d -m 750 "${DATA_DIR}"
install -d -m 750 "${BACKUP_DIR}" "${GUEST_BUILD_DIR}"
chown -R "${FD_USER}:${FD_USER}" "${DATA_DIR}"

if [[ -f "${ENV_FILE}" ]]; then
  log_ok ".env exists — preserving"
  if [[ -n "${FD_DIST_TOKEN:-}" ]]; then
    grep -q '^FD_DIST_TOKEN=' "${ENV_FILE}" || echo "FD_DIST_TOKEN=${FD_DIST_TOKEN}" >> "${ENV_FILE}"
  fi
  # The panel now trusts X-Forwarded-For ONLY from an explicit
  # PANEL_TRUSTED_PROXIES list (the default set is empty). Without this line an
  # upgraded install would key every per-IP rate limit on 127.0.0.1 — i.e. one
  # shared bucket for the whole internet, since Caddy is the only client.
  if ! grep -q '^PANEL_TRUSTED_PROXIES=' "${ENV_FILE}"; then
    printf 'PANEL_TRUSTED_PROXIES=127.0.0.1\n' >> "${ENV_FILE}"
    log_ok "PANEL_TRUSTED_PROXIES=127.0.0.1 добавлен в .env (per-IP лимиты за Caddy)"
  fi
else
  ENCRYPTION_KEY=$(openssl rand -hex 32)
  SESSION_SECRET=$(openssl rand -hex 32)
  # Create the file 600 BEFORE writing anything into it. `cat > file` followed by
  # `chmod 600` leaves a window in which the file exists at the default umask
  # (0644) with ENCRYPTION_KEY already inside — and that key decrypts every SSH
  # key in the DB. install(1) creates with the mode, so there is no window.
  install -m 600 -o root -g root /dev/null "${ENV_FILE}"
  cat > "${ENV_FILE}" <<EOF
NODE_ENV=production
PORT=${FD_PORT}
# The panel binds 127.0.0.1 by default (server/src/index.ts). It is reached
# through Caddy over HTTPS, never directly — audit C-2: :9000 open to the
# internet served the login form in cleartext.
DATABASE_PATH=${DATA_DIR}/data.db
BACKUP_DIR=${BACKUP_DIR}
FD_GUEST_BUILD_DIR=${GUEST_BUILD_DIR}
# Only this proxy's X-Forwarded-For is believed. The default trusted set is
# EMPTY, so without this line the header is ignored and every per-IP limit
# (login backoff included) collapses onto the loopback address.
PANEL_TRUSTED_PROXIES=127.0.0.1
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

# ─── 9b. prepare-host из релиза (+ базовая линия безопасности) ──────────────
# prepare-host.sh теперь ещё и применяет harden-host.sh: до этого релиза
# control-plane — машина, где лежит ENCRYPTION_KEY и SSH-ключи ко всем
# управляемым серверам — не получала из базовой линии НИЧЕГО (аудит §4).
bash "${INSTALL_DIR}/current/scripts/prepare-host.sh"
log_ok "Host prepared (/srv/frostdeploy + sudoers + security baseline)"

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
  # Без --environ: он сбрасывает всё окружение процесса в журнал при старте.
  # RuntimeDirectory=caddy создаёт /run/caddy под admin-сокет.
  # Канонической версией этого файла владеет harden-host.sh и обновляет её на
  # каждом апдейте; здесь достаточно, чтобы ПЕРВАЯ установка была корректной.
  cat > /etc/systemd/system/caddy.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/caddy run --resume
RuntimeDirectory=caddy
RuntimeDirectoryMode=0755
ExecReload=
ExecReload=/bin/sh -c 'if [ -S /run/caddy/admin.sock ]; then A="--unix-socket /run/caddy/admin.sock http://localhost"; else A="http://localhost:2019"; fi; curl -sf $A/config/ | curl -sf -X POST -H "Content-Type: application/json" -H "Cache-Control: must-revalidate" --data-binary @- $A/load'
EOF
  # Панель ходит в admin API Caddy через unix-сокет 0660, владелец группы caddy.
  # Без этого членства панель не сможет настраивать Caddy вообще.
  if getent group caddy >/dev/null 2>&1; then
    usermod -aG caddy "${FD_USER}"
  fi
  systemctl daemon-reload
  systemctl enable caddy --quiet 2>/dev/null || true
  systemctl restart caddy
  log_ok "Caddy runs with --resume (config managed by the panel via admin API)"
fi

# ─── 11c. The panel port is NEVER opened in the firewall ────────────────────
# There used to be an `ufw allow ${FD_PORT}/tcp` here "so the browser can reach
# the panel during setup". That is exactly what put the admin panel on the open
# internet in cleartext HTTP (audit C-2): 51 964 brute-force attempts landed on
# it, and because the login rate limiter trusted X-Forwarded-For from anyone, a
# direct request to :9000 could set that header itself and reset the limit.
#
# The panel binds 127.0.0.1 and is reached over HTTPS through Caddy. Before a
# domain is configured, use an SSH tunnel from your own machine:
#
#   ssh -L 9000:127.0.0.1:9000 root@<server>   →  http://127.0.0.1:9000
#
# Do not "just open the port to have a quick look".
if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "${FD_PORT}"; then
  ufw delete allow "${FD_PORT}/tcp" > /dev/null 2>&1 \
    && log_ok "ufw: закрыт унаследованный allow ${FD_PORT}/tcp (панель не смотрит в интернет)" \
    || true
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
# NB: no `http://<ip>:9000` here. The panel binds loopback and that URL was never
# reachable from a browser without opening the port — the exact hole audit C-2 is
# about. Advertise the HTTPS domain and the tunnel, nothing else.
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║             FrostDeploy is ready! 🚀                         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e " ${BOLD}Панель слушает 127.0.0.1:${FD_PORT} и в интернет НЕ смотрит.${NC}"
echo ""
echo -e " ${BOLD}1) Первый вход — через SSH-туннель.${NC}"
echo -e "    ${YELLOW}Команду ниже выполни НА СВОЁМ КОМПЬЮТЕРЕ, не здесь.${NC}"
echo -e "    ${YELLOW}Сейчас ты на сервере — открой новое окно терминала у себя.${NC}"
echo ""
echo -e "      ${CYAN}ssh -L ${FD_PORT}:127.0.0.1:${FD_PORT} root@${SERVER_IP}${NC}"
echo ""
echo -e "    Не закрывая его, открой в браузере ${BOLD}на своём компьютере${NC}:"
echo -e "      ${CYAN}http://127.0.0.1:${FD_PORT}${NC}"
echo -e "    Пройди Setup Wizard и создай админский аккаунт."
echo ""
echo -e " ${BOLD}2) Дальше — только по своему домену через HTTPS:${NC}"
echo -e "    в панели укажи домен (Settings → Domain), Caddy сам возьмёт"
echo -e "    сертификат, и панель будет доступна как ${CYAN}https://<твой-домен>${NC}"
echo ""
echo -e " ${YELLOW}Порт ${FD_PORT} открывать в файрволе НЕ надо и НЕ нужно никогда.${NC}"
echo ""
echo -e " ${BOLD}Полезные команды:${NC}"
echo "    systemctl status ${SERVICE_NAME}"
echo "    journalctl -u ${SERVICE_NAME} -f"
echo "    systemctl restart ${SERVICE_NAME}"
echo "    frostdeploy update | rollback"
echo "    bash ${INSTALL_DIR}/current/scripts/harden-host.sh --dry-run   # аудит базовой линии"
echo ""
