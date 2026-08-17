#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# torrent-to-direct-download v3.0.1
# qBittorrent + Nginx + optional Let's Encrypt IP SSL for Ubuntu.
#
# Safety goals:
# - password reset never reinstalls the stack or touches downloaded content
# - SSL is optional and decided before package/image/service changes
# - qBittorrent v5 content deletion is forced to permanent delete
# - persistent data is never removed by install/update
# - no Docker volume removal and no recursive chmod/chown over large downloads

SCRIPT_VERSION="3.0.1"
STACK_NAME="torrent-to-direct-download"
STACK_DIR="${STACK_DIR:-/opt/${STACK_NAME}}"
COMPOSE_FILE="${STACK_DIR}/compose.yaml"
ENV_FILE="${STACK_DIR}/.env"
STATE_FILE="${STACK_DIR}/.installation-complete"

# Preserve values explicitly provided by the caller before loading a previous .env.
CALLER_KEYS=""
for _v in \
  DATA_DIR QBT_CONFIG_DIR DOWNLOAD_DIR INCOMPLETE_DIR LETSENCRYPT_DIR ACME_DIR \
  NGINX_CONF_DIR NGINX_ENTRYPOINT_DIR NGINX_MAIN_CONF PUBLIC_IP QBT_IMAGE NGINX_IMAGE CERTBOT_IMAGE \
  WEBUI_BIND WEBUI_PORT TORRENT_PORT TIMEZONE QBT_PUID QBT_PGID QBT_USERNAME \
  ENABLE_SSL LETSENCRYPT_EMAIL LETSENCRYPT_STAGING RUN_RENEWAL_DRY_RUN SKIP_IMAGE_PULL; do
  if [[ -n "${!_v+x}" ]]; then CALLER_KEYS+=" ${_v} "; fi
done

caller_set() { [[ "${CALLER_KEYS}" == *" $1 "* ]]; }

read_persisted_env() {
  [[ -r "${ENV_FILE}" ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    [[ -n "${key}" && "${key}" != \#* ]] || continue
    case "${key}" in
      DATA_DIR|QBT_CONFIG_DIR|DOWNLOAD_DIR|INCOMPLETE_DIR|LETSENCRYPT_DIR|ACME_DIR|\
      NGINX_CONF_DIR|NGINX_ENTRYPOINT_DIR|NGINX_MAIN_CONF|PUBLIC_IP|QBT_IMAGE|NGINX_IMAGE|CERTBOT_IMAGE|\
      WEBUI_BIND|WEBUI_PORT|TORRENT_PORT|TIMEZONE|QBT_PUID|QBT_PGID|QBT_USERNAME|\
      ENABLE_SSL|LETSENCRYPT_EMAIL|LETSENCRYPT_STAGING|RUN_RENEWAL_DRY_RUN|SKIP_IMAGE_PULL)
        if ! caller_set "${key}"; then printf -v "${key}" '%s' "${value}"; fi
        ;;
    esac
  done < "${ENV_FILE}"
}
read_persisted_env

DATA_DIR="${DATA_DIR:-/srv/qbittorrent}"
QBT_CONFIG_DIR="${QBT_CONFIG_DIR:-${DATA_DIR}/config}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${DATA_DIR}/downloads}"
INCOMPLETE_DIR="${INCOMPLETE_DIR:-${DATA_DIR}/incomplete}"
LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-${DATA_DIR}/letsencrypt}"
ACME_DIR="${ACME_DIR:-${DATA_DIR}/acme}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-${STACK_DIR}/nginx/conf.d}"
NGINX_ENTRYPOINT_DIR="${NGINX_ENTRYPOINT_DIR:-${STACK_DIR}/nginx/entrypoint}"
NGINX_MAIN_CONF="${NGINX_MAIN_CONF:-${STACK_DIR}/nginx/nginx.conf}"

QBT_CONFIG_FILE="${QBT_CONFIG_DIR}/qBittorrent/config/qBittorrent.conf"
QBT_DATA_DIR="${QBT_CONFIG_DIR}/qBittorrent/data"
QBT_CONTAINER="ttdd-qbittorrent"
NGINX_CONTAINER="ttdd-nginx"
CERTBOT_RENEW_CONTAINER="ttdd-certbot-renew"

QBT_IMAGE="${QBT_IMAGE:-qbittorrentofficial/qbittorrent-nox:latest}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:stable-alpine}"
CERTBOT_IMAGE="${CERTBOT_IMAGE:-certbot/certbot:latest}"
WEBUI_BIND="${WEBUI_BIND:-0.0.0.0}"
WEBUI_PORT="${WEBUI_PORT:-8080}"
TORRENT_PORT="${TORRENT_PORT:-49160}"
TIMEZONE="${TIMEZONE:-UTC}"
QBT_PUID="${QBT_PUID:-1000}"
QBT_PGID="${QBT_PGID:-1000}"
QBT_USERNAME="${QBT_USERNAME:-admin}"
QBT_PASSWORD="${QBT_PASSWORD:-}"

# Intentionally empty on a first install so the user is asked immediately.
ENABLE_SSL="${ENABLE_SSL:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-0}"
# Full certbot dry-run is deliberately opt-in; it is slow and duplicates work.
RUN_RENEWAL_DRY_RUN="${RUN_RENEWAL_DRY_RUN:-0}"
SKIP_IMAGE_PULL="${SKIP_IMAGE_PULL:-0}"
RESET_QBT_PASSWORD="${RESET_QBT_PASSWORD:-0}"
PURGE_QBT_TRASH="${PURGE_QBT_TRASH:-0}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
FORCE="${FORCE:-0}"

CREDENTIAL_FILE="${CREDENTIAL_FILE:-/root/qbittorrent-credentials.txt}"
DOWNLOAD_INFO_FILE="${DOWNLOAD_INFO_FILE:-/root/qbittorrent-download-info.txt}"
SSL_INFO_FILE="${SSL_INFO_FILE:-/root/qbittorrent-ip-ssl-info.txt}"
ERROR_REPORT_FILE="${ERROR_REPORT_FILE:-/root/torrent-to-direct-download-error.log}"
CERTBOT_ISSUE_LOG="${STACK_DIR}/certbot-issue.log"
CERTBOT_RENEW_TEST_LOG="${STACK_DIR}/certbot-renew-dry-run.log"

CERT_NAME=""
CERT_LIVE_DIR=""
CERT_FULLCHAIN=""
CERT_PRIVATE_KEY=""
CERT_CERT=""
CERT_CHAIN=""
QBT_RUNTIME_VERSION=""
BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
CURRENT_STAGE="initialization"
ERROR_REPORTING=0
ACTION="install"

usage() {
  cat <<EOF
Torrent to Direct Download installer v${SCRIPT_VERSION}

Usage:
  sudo bash install.sh                    Install/update; first install asks about SSL first
  sudo bash install.sh --enable-ssl       Install/update with HTTPS
  sudo bash install.sh --disable-ssl      Install/update with HTTP only
  sudo bash install.sh --reset-password   Reset qBittorrent password ONLY
  sudo bash install.sh --disk-check       Diagnose disk usage and hidden trash
  sudo bash install.sh --purge-trash      Permanently remove qBittorrent .Trash-* data
  sudo bash install.sh --status           Show stack status and storage usage

Useful environment overrides:
  QBT_PASSWORD='...'            Set a password (minimum 12 characters)
  ENABLE_SSL=0|1               Non-interactive SSL choice
  LETSENCRYPT_EMAIL='...'      Optional Let's Encrypt email
  LETSENCRYPT_STAGING=1        Test certificate issuance
  RUN_RENEWAL_DRY_RUN=1        Run slow certbot renewal dry-run (default 0)
  SKIP_IMAGE_PULL=1            Reuse local images without pulling
  PUBLIC_IP=x.x.x.x            Override public IPv4 detection
  FORCE=1                      Skip confirmation for --purge-trash

Backward compatibility:
  RESET_QBT_PASSWORD=1         Same as --reset-password
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --reset-password) ACTION="reset-password" ;;
    --disk-check) ACTION="disk-check" ;;
    --purge-trash) ACTION="purge-trash" ;;
    --status) ACTION="status" ;;
    --enable-ssl) ENABLE_SSL="1" ;;
    --disable-ssl) ENABLE_SSL="0" ;;
    --non-interactive) NON_INTERACTIVE="1" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n\n' "${arg}" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "${RESET_QBT_PASSWORD}" == "1" ]] && ACTION="reset-password"
[[ "${PURGE_QBT_TRASH}" == "1" ]] && ACTION="purge-trash"

log() { CURRENT_STAGE="$*"; printf '\n>>> %s\n' "$*"; }
compose() {
  docker compose --project-name "${STACK_NAME}" --env-file "${ENV_FILE}" --file "${COMPOSE_FILE}" "$@"
}

print_failure_report() {
  local ec="${1:-1}" line="${2:-unknown}" cmd="${3:-unknown}"
  [[ "${ERROR_REPORTING}" == "0" ]] || return 0
  ERROR_REPORTING=1
  trap - ERR
  set +e
  install -d -m 0700 "$(dirname "${ERROR_REPORT_FILE}")" 2>/dev/null || true
  {
    printf 'torrent-to-direct-download diagnostic report\n'
    printf 'Time: %s\nVersion: %s\nAction: %s\nStage: %s\nLine: %s\nExit: %s\nCommand: %s\n' \
      "$(date --iso-8601=seconds 2>/dev/null || date)" "${SCRIPT_VERSION}" "${ACTION}" "${CURRENT_STAGE}" "${line}" "${ec}" "${cmd}"
    printf '\nDisk usage:\n'; df -hT "${DATA_DIR}" "${STACK_DIR}" 2>&1 || df -hT 2>&1 || true
    if command -v docker >/dev/null 2>&1; then
      printf '\nDocker disk usage:\n'; docker system df 2>&1 || true
      if [[ -f "${COMPOSE_FILE}" && -f "${ENV_FILE}" ]]; then
        printf '\nCompose status:\n'; compose ps -a 2>&1 || true
        printf '\nRecent logs:\n'; compose logs --no-color --tail=120 2>&1 || true
      fi
    fi
    [[ -s "${CERTBOT_ISSUE_LOG}" ]] && { printf '\nCertbot issue log:\n'; tail -n 200 "${CERTBOT_ISSUE_LOG}"; }
  } > "${ERROR_REPORT_FILE}" 2>&1
  printf '\nERROR during: %s\nDiagnostic report: %s\n' "${CURRENT_STAGE}" "${ERROR_REPORT_FILE}" >&2
}
trap 'ec=$?; print_failure_report "$ec" "$LINENO" "$BASH_COMMAND"; exit "$ec"' ERR

die() { printf '\nERROR: %s\n' "$*" >&2; return 1; }
require_root() { [[ "${EUID}" -eq 0 ]] || die "Run this script as root."; }
validate_boolean() { [[ "$1" == "0" || "$1" == "1" ]] || die "$2 must be 0 or 1."; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )) || die "$2 must be a port from 1 to 65535."; }
validate_uid_gid() { [[ "$1" =~ ^[0-9]+$ ]] || die "$2 must be numeric."; }

require_ubuntu() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu only."
  case "${VERSION_ID:-}" in 22.04|24.04|25.10|26.04) ;; *) die "Unsupported Ubuntu release: ${VERSION_ID:-unknown}" ;; esac
}

ask_yes_no() {
  local prompt="$1" default="${2:-N}" answer=""
  if [[ "${NON_INTERACTIVE}" == "1" || ! -t 0 ]]; then [[ "${default}" == "Y" ]]; return; fi
  if [[ "${default}" == "Y" ]]; then read -r -p "${prompt} [Y/n]: " answer || true; else read -r -p "${prompt} [y/N]: " answer || true; fi
  answer="${answer:-${default}}"
  [[ "${answer}" =~ ^[Yy]$ ]]
}

resolve_ssl_choice() {
  if [[ -n "${ENABLE_SSL}" ]]; then validate_boolean "${ENABLE_SSL}" "ENABLE_SSL"; return; fi
  printf '\nSSL/HTTPS selection\n-------------------\n'
  if ask_yes_no "Install/enable a Let's Encrypt SSL certificate for the public IPv4?" "N"; then ENABLE_SSL=1; else ENABLE_SSL=0; fi
  printf 'SSL selected: %s\n' "$( [[ "${ENABLE_SSL}" == "1" ]] && printf enabled || printf disabled )"
}

wait_for_apt_locks() {
  local deadline=$((SECONDS + 300))
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "APT/dpkg is busy for more than 300 seconds. Try again after the other package process finishes."
    printf 'Waiting for another apt/dpkg process...\n'; sleep 3
  done
}

install_base_packages_if_needed() {
  local required=(ca-certificates curl gnupg openssl python3 python3-yaml iproute2 lsof) missing=() p
  for p in "${required[@]}"; do dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -q '^installed$' || missing+=("$p"); done
  (( ${#missing[@]} == 0 )) && { log "Required host packages are already installed."; return; }
  log "Installing only missing host packages: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  wait_for_apt_locks
  apt-get update
  wait_for_apt_locks
  apt-get install -y "${missing[@]}"
}

install_official_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    systemctl enable --now docker.service 2>/dev/null || true
    if docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      log "Docker Engine and Compose are already available."
      return
    fi
  fi
  log "Installing Docker Engine and Compose from Docker's official repository."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-${VERSION_CODENAME}}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  wait_for_apt_locks; apt-get update; wait_for_apt_locks

  # Remove only packages that conflict with Docker CE, and only when Docker CE
  # actually needs to be installed. Persistent /var/lib/docker data is not purged.
  local conflicts=() p
  for p in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -q '^installed$' && conflicts+=("$p") || true
  done
  if (( ${#conflicts[@]} > 0 )); then wait_for_apt_locks; apt-get remove -y "${conflicts[@]}"; fi
  wait_for_apt_locks
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker info >/dev/null; docker compose version >/dev/null
}

validate_public_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try: ip = ipaddress.ip_address(sys.argv[1])
except ValueError: raise SystemExit(1)
raise SystemExit(0 if ip.version == 4 and ip.is_global else 1)
PY
}

detect_public_ip() {
  if [[ -n "${PUBLIC_IP}" ]] && caller_set PUBLIC_IP; then
    validate_public_ipv4 "${PUBLIC_IP}" || die "PUBLIC_IP is not a globally routable IPv4: ${PUBLIC_IP}"
    return
  fi
  log "Detecting public IPv4."
  local endpoint detected="" persisted="${PUBLIC_IP}"
  for endpoint in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.co/ip; do
    detected="$(curl -4fsS --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$detected" ]] && validate_public_ipv4 "$detected"; then PUBLIC_IP="$detected"; break; fi
  done
  # If external detection temporarily fails during an update, a previously
  # persisted valid public IP is safer than aborting or inventing an address.
  if [[ -z "${PUBLIC_IP}" || "${PUBLIC_IP}" == "${persisted}" && -z "${detected}" ]]; then
    if [[ -n "${persisted}" ]] && validate_public_ipv4 "${persisted}"; then PUBLIC_IP="${persisted}"; fi
  fi
  [[ -n "${PUBLIC_IP}" ]] || die "Could not detect public IPv4. Set PUBLIC_IP explicitly."
  validate_public_ipv4 "${PUBLIC_IP}" || die "Detected/persisted PUBLIC_IP is invalid: ${PUBLIC_IP}"
  printf 'Public IPv4: %s\n' "${PUBLIC_IP}"
}

initialize_certificate_paths() {
  local safe_ip="${PUBLIC_IP//./-}"
  CERT_NAME="qbittorrent-ip-${safe_ip}"
  CERT_LIVE_DIR="${LETSENCRYPT_DIR}/live/${CERT_NAME}"
  CERT_FULLCHAIN="${CERT_LIVE_DIR}/fullchain.pem"
  CERT_PRIVATE_KEY="${CERT_LIVE_DIR}/privkey.pem"
  CERT_CERT="${CERT_LIVE_DIR}/cert.pem"
  CERT_CHAIN="${CERT_LIVE_DIR}/chain.pem"
}

backup_stack_metadata() {
  [[ -e "${COMPOSE_FILE}" || -e "${ENV_FILE}" || -d "${STACK_DIR}/nginx" ]] || return 0
  local bdir="${STACK_DIR}/backups/${BACKUP_STAMP}"
  install -d -m 0700 "${bdir}"
  [[ -f "${COMPOSE_FILE}" ]] && cp -a "${COMPOSE_FILE}" "${bdir}/compose.yaml" || true
  [[ -f "${ENV_FILE}" ]] && cp -a "${ENV_FILE}" "${bdir}/.env" || true
  [[ -d "${STACK_DIR}/nginx" ]] && cp -a "${STACK_DIR}/nginx" "${bdir}/nginx" || true
  printf 'Previous stack metadata backup: %s\n' "${bdir}"
}

stop_previous_stack() {
  log "Stopping only this project's previous containers (persistent data is untouched)."
  if [[ -f "${COMPOSE_FILE}" && -f "${ENV_FILE}" ]]; then compose down --remove-orphans 2>/dev/null || true; fi
  local c
  for c in "${QBT_CONTAINER}" "${NGINX_CONTAINER}" "${CERTBOT_RENEW_CONTAINER}"; do
    docker container inspect "$c" >/dev/null 2>&1 && docker rm -f "$c" >/dev/null || true
  done
}

stop_legacy_native_qbt() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^qbittorrent-root\.service'; then
    log "Stopping legacy installer-managed qbittorrent-root.service."
    systemctl disable --now qbittorrent-root.service 2>/dev/null || true
    [[ -f /etc/systemd/system/qbittorrent-root.service ]] && cp -a /etc/systemd/system/qbittorrent-root.service "/etc/systemd/system/qbittorrent-root.service.backup.${BACKUP_STAMP}"
    pkill -TERM -x qbittorrent-nox 2>/dev/null || true
  fi
}

legacy_nginx_is_ours() {
  [[ -d /etc/nginx ]] || return 1
  grep -RqsE '/srv/qbittorrent|qbittorrent-download' /etc/nginx 2>/dev/null
}

handle_host_nginx_safely() {
  systemctl is-active --quiet nginx.service 2>/dev/null || return 0
  local needed_ports=':80'
  [[ "${ENABLE_SSL}" == "1" ]] && needed_ports=':80|:443'
  # An active host Nginx that does not occupy the ports this project needs can coexist.
  ss -H -lntp 2>/dev/null | grep -E "(${needed_ports})([[:space:]]|$)" | grep -q nginx || return 0
  if legacy_nginx_is_ours; then
    log "Backing up and stopping legacy Nginx that appears to belong to an older TTDD install."
    install -d -m 0700 /root/torrent-to-direct-download-backups
    tar -czf "/root/torrent-to-direct-download-backups/host-nginx.${BACKUP_STAMP}.tar.gz" -C /etc nginx
    systemctl disable --now nginx.service
  else
    die "Host nginx.service occupies a required port and does not appear to belong to this project. Refusing to disable an unrelated web server."
  fi
}

check_tcp_port_free() {
  local port="$1" desc="$2" out
  out="$(ss -H -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ (p "$") {print}' || true)"
  [[ -z "$out" ]] || { printf '\nTCP port %s is in use:\n%s\n' "$port" "$out" >&2; die "${desc} requires TCP port ${port}."; }
}
check_udp_port_free() {
  local port="$1" desc="$2" out
  out="$(ss -H -lunp 2>/dev/null | awk -v p=":${port}" '$5 ~ (p "$") || $4 ~ (p "$") {print}' || true)"
  [[ -z "$out" ]] || { printf '\nUDP port %s is in use:\n%s\n' "$port" "$out" >&2; die "${desc} requires UDP port ${port}."; }
}

configure_ufw_if_active() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  log "Opening required ports in UFW."
  ufw allow 80/tcp >/dev/null
  [[ "${ENABLE_SSL}" == "1" ]] && ufw allow 443/tcp >/dev/null
  ufw allow "${WEBUI_PORT}/tcp" >/dev/null
  ufw allow "${TORRENT_PORT}/tcp" >/dev/null
  ufw allow "${TORRENT_PORT}/udp" >/dev/null
}

prepare_directories() {
  log "Preparing persistent directories without deleting existing data."
  install -d -m 0755 "${STACK_DIR}" "${NGINX_CONF_DIR}" "${NGINX_ENTRYPOINT_DIR}"
  install -d -m 0755 "${DATA_DIR}" "${QBT_CONFIG_DIR}" "${DOWNLOAD_DIR}" "${INCOMPLETE_DIR}"
  install -d -m 0755 "$(dirname "${QBT_CONFIG_FILE}")" "${QBT_DATA_DIR}"
  if [[ "${ENABLE_SSL}" == "1" ]]; then
    install -d -m 0755 "${LETSENCRYPT_DIR}" "${ACME_DIR}/.well-known/acme-challenge"
    chmod 0755 "${DATA_DIR}" "${ACME_DIR}" "${ACME_DIR}/.well-known" "${ACME_DIR}/.well-known/acme-challenge"
  fi
}

migrate_previous_native_data() {
  log "Checking for data from older native installations."
  if [[ ! -s "${QBT_CONFIG_FILE}" && -s /root/.config/qBittorrent/qBittorrent.conf ]]; then cp -a /root/.config/qBittorrent/qBittorrent.conf "${QBT_CONFIG_FILE}"; fi
  if [[ -d /root/.local/share/qBittorrent && -z "$(find "${QBT_DATA_DIR}" -mindepth 1 -print -quit 2>/dev/null)" ]]; then cp -a /root/.local/share/qBittorrent/. "${QBT_DATA_DIR}/"; fi
}

read_existing_password() {
  [[ -n "${QBT_PASSWORD}" ]] && return 0
  [[ -r "${CREDENTIAL_FILE}" ]] || return 0
  local existing
  existing="$(awk -F': ' '/^Password: / {print $2; exit}' "${CREDENTIAL_FILE}" || true)"
  [[ -n "$existing" && "$existing" != "unchanged" && "$existing" != "temporary" ]] && QBT_PASSWORD="$existing"
}

generate_password_hash() {
  python3 - "$1" <<'PY'
import base64, hashlib, os, sys
# qBittorrent uses PBKDF2-HMAC-SHA512, 100000 iterations.
known_salt = base64.b64decode("ARQ77eY1NUZaQsuDHbIMCA==")
known_expected = base64.b64decode("0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gur2hmQCvCDpm39Q+PsJRJPaCU51dEiz+dTzh8qbPsL8WkFljQYFQ==")
assert hashlib.pbkdf2_hmac("sha512", b"adminadmin", known_salt, 100000) == known_expected
salt = os.urandom(16)
derived = hashlib.pbkdf2_hmac("sha512", sys.argv[1].encode(), salt, 100000)
print("@ByteArray(" + base64.b64encode(salt).decode() + ":" + base64.b64encode(derived).decode() + ")")
PY
}

write_credentials_file() {
  install -d -m 0700 "$(dirname "${CREDENTIAL_FILE}")"
  [[ -s "${CREDENTIAL_FILE}" ]] && cp -a "${CREDENTIAL_FILE}" "${CREDENTIAL_FILE}.backup.${BACKUP_STAMP}" || true
  cat > "${CREDENTIAL_FILE}" <<EOF
qBittorrent WebUI Credentials
==============================
URL: http://${PUBLIC_IP:-SERVER_IP}:${WEBUI_PORT}
Username: ${QBT_USERNAME}
Password: ${QBT_PASSWORD}
Installer version: ${SCRIPT_VERSION}
EOF
  chmod 0600 "${CREDENTIAL_FILE}"
}

configure_qbittorrent_offline() {
  local mode="${1:-full}" password_hash
  [[ "${mode}" == "full" ]] && read_existing_password
  [[ -n "${QBT_PASSWORD}" ]] || QBT_PASSWORD="$(openssl rand -hex 18)"
  (( ${#QBT_PASSWORD} >= 12 )) || die "QBT_PASSWORD must contain at least 12 characters."
  password_hash="$(generate_password_hash "${QBT_PASSWORD}")"
  [[ -s "${QBT_CONFIG_FILE}" ]] && cp -a "${QBT_CONFIG_FILE}" "${QBT_CONFIG_FILE}.backup.${BACKUP_STAMP}"
  install -d -m 0755 "$(dirname "${QBT_CONFIG_FILE}")"

  python3 - "${QBT_CONFIG_FILE}" "$mode" "${QBT_USERNAME}" "$password_hash" "${WEBUI_PORT}" "${TORRENT_PORT}" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1]); mode,user,pwh,web,port=sys.argv[2:]
lines=(path.read_text(encoding='utf-8',errors='replace').splitlines() if path.exists() else [])
def setv(section,key,value):
    global lines
    h=f'[{section}]'; start=None; end=len(lines)
    for i,l in enumerate(lines):
        if l.strip()==h: start=i; break
    if start is None:
        if lines and lines[-1].strip(): lines.append('')
        lines.extend([h,f'{key}={value}']); return
    for i in range(start+1,len(lines)):
        if lines[i].startswith('[') and lines[i].endswith(']'): end=i; break
    pref=f'{key}='
    for i in range(start+1,end):
        if lines[i].startswith(pref): lines[i]=f'{key}={value}'; return
    lines.insert(end,f'{key}={value}')

setv('LegalNotice','Accepted','true')
setv('Preferences',r'WebUI\Address','*')
setv('Preferences',r'WebUI\Port',web)
setv('Preferences',r'WebUI\Username',user)
setv('Preferences',r'WebUI\Password_PBKDF2',f'"{pwh}"')
setv('Preferences',r'WebUI\LocalHostAuth','true')
setv('Preferences',r'WebUI\AuthSubnetWhitelistEnabled','false')
setv('Preferences',r'WebUI\HostHeaderValidation','false')
setv('Preferences',r'WebUI\CSRFProtection','true')
setv('Preferences',r'WebUI\ClickjackingProtection','true')
setv('Preferences',r'WebUI\SecureCookie','false')
setv('Preferences',r'WebUI\ServerDomains','*')
setv('Preferences',r'WebUI\UseUPnP','false')
if mode=='full':
    # New torrents keep complete and incomplete paths below one /data mount.
    setv('BitTorrent',r'Session\DefaultSavePath','/data/downloads')
    setv('BitTorrent',r'Session\TempPath','/data/incomplete')
    setv('BitTorrent',r'Session\TempPathEnabled','true')
    setv('BitTorrent',r'Session\Port',port)
    setv('BitTorrent',r'Session\QueueingSystemEnabled','false')
    # Critical on qBittorrent v5 headless systems: do not move deletions to .Trash-*.
    setv('BitTorrent',r'Session\TorrentContentRemoveOption','Delete')
    setv('Preferences',r'Downloads\SavePath','/data/downloads/')
    setv('Preferences',r'Downloads\TempPath','/data/incomplete/')
    setv('Preferences',r'Downloads\TempPathEnabled','true')
path.write_text('\n'.join(lines).rstrip()+'\n',encoding='utf-8')
PY

  # Config is small; downloaded content may be multi-terabyte. Never recursively
  # chmod/chown the data tree during reset/install.
  if [[ "$mode" == "full" ]]; then
    chown -R "${QBT_PUID}:${QBT_PGID}" "${QBT_CONFIG_DIR}"
    chown "${QBT_PUID}:${QBT_PGID}" "${DOWNLOAD_DIR}" "${INCOMPLETE_DIR}"
    chmod 0755 "${DOWNLOAD_DIR}" "${INCOMPLETE_DIR}"
  else
    chown "${QBT_PUID}:${QBT_PGID}" "$(dirname "${QBT_CONFIG_FILE}")" "${QBT_CONFIG_FILE}"
  fi
  write_credentials_file
}

write_environment_file() {
  cat > "${ENV_FILE}" <<EOF
DATA_DIR=${DATA_DIR}
QBT_CONFIG_DIR=${QBT_CONFIG_DIR}
DOWNLOAD_DIR=${DOWNLOAD_DIR}
INCOMPLETE_DIR=${INCOMPLETE_DIR}
LETSENCRYPT_DIR=${LETSENCRYPT_DIR}
ACME_DIR=${ACME_DIR}
NGINX_CONF_DIR=${NGINX_CONF_DIR}
NGINX_ENTRYPOINT_DIR=${NGINX_ENTRYPOINT_DIR}
NGINX_MAIN_CONF=${NGINX_MAIN_CONF}
PUBLIC_IP=${PUBLIC_IP}
QBT_IMAGE=${QBT_IMAGE}
NGINX_IMAGE=${NGINX_IMAGE}
CERTBOT_IMAGE=${CERTBOT_IMAGE}
WEBUI_BIND=${WEBUI_BIND}
WEBUI_PORT=${WEBUI_PORT}
TORRENT_PORT=${TORRENT_PORT}
TIMEZONE=${TIMEZONE}
QBT_PUID=${QBT_PUID}
QBT_PGID=${QBT_PGID}
QBT_USERNAME=${QBT_USERNAME}
ENABLE_SSL=${ENABLE_SSL}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
LETSENCRYPT_STAGING=${LETSENCRYPT_STAGING}
RUN_RENEWAL_DRY_RUN=${RUN_RENEWAL_DRY_RUN}
SKIP_IMAGE_PULL=${SKIP_IMAGE_PULL}
EOF
  chmod 0600 "${ENV_FILE}"
}

write_compose_file() {
  if [[ "${ENABLE_SSL}" == "1" ]]; then
    cat > "${COMPOSE_FILE}" <<'YAML'
name: torrent-to-direct-download
services:
  qbittorrent:
    image: ${QBT_IMAGE}
    container_name: ttdd-qbittorrent
    restart: unless-stopped
    read_only: true
    tty: true
    stop_grace_period: 30m
    tmpfs:
      - /tmp
    environment:
      QBT_LEGAL_NOTICE: confirm
      QBT_TORRENTING_PORT: ${TORRENT_PORT}
      QBT_WEBUI_PORT: ${WEBUI_PORT}
      TZ: ${TIMEZONE}
      PUID: ${QBT_PUID}
      PGID: ${QBT_PGID}
      UMASK: "022"
    ports:
      - "${WEBUI_BIND}:${WEBUI_PORT}:${WEBUI_PORT}/tcp"
      - "0.0.0.0:${TORRENT_PORT}:${TORRENT_PORT}/tcp"
      - "0.0.0.0:${TORRENT_PORT}:${TORRENT_PORT}/udp"
    volumes:
      - "${QBT_CONFIG_DIR}:/config"
      - "${DATA_DIR}:/data"
      # Compatibility aliases for existing v2.x resume paths. These point to
      # the SAME host data; Docker bind mounts do not create copies.
      - "${DOWNLOAD_DIR}:/downloads"
      - "${INCOMPLETE_DIR}:/incomplete"
  nginx:
    image: ${NGINX_IMAGE}
    container_name: ttdd-nginx
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    sysctls:
      net.core.somaxconn: "65535"
    environment:
      CERT_RELOAD_INTERVAL: "60"
    ports:
      - "0.0.0.0:80:80/tcp"
      - "0.0.0.0:443:443/tcp"
    volumes:
      - "${DOWNLOAD_DIR}:/downloads:ro"
      - "${LETSENCRYPT_DIR}:/etc/letsencrypt:ro"
      - "${ACME_DIR}:/var/www/certbot"
      - "${NGINX_MAIN_CONF}:/etc/nginx/nginx.conf:ro"
      - "${NGINX_CONF_DIR}:/etc/nginx/conf.d:ro"
      - "${NGINX_ENTRYPOINT_DIR}:/docker-entrypoint.d:ro"
  certbot:
    image: ${CERTBOT_IMAGE}
    profiles: ["tools"]
    volumes:
      - "${LETSENCRYPT_DIR}:/etc/letsencrypt"
      - "${ACME_DIR}:/var/www/certbot"
  certbot-renew:
    image: ${CERTBOT_IMAGE}
    container_name: ttdd-certbot-renew
    restart: unless-stopped
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        trap 'exit 0' TERM INT
        while :; do
          certbot renew --quiet --deploy-hook 'touch /var/www/certbot/.reload-nginx'
          sleep 43200
        done
    volumes:
      - "${LETSENCRYPT_DIR}:/etc/letsencrypt"
      - "${ACME_DIR}:/var/www/certbot"
YAML
  else
    cat > "${COMPOSE_FILE}" <<'YAML'
name: torrent-to-direct-download
services:
  qbittorrent:
    image: ${QBT_IMAGE}
    container_name: ttdd-qbittorrent
    restart: unless-stopped
    read_only: true
    tty: true
    stop_grace_period: 30m
    tmpfs:
      - /tmp
    environment:
      QBT_LEGAL_NOTICE: confirm
      QBT_TORRENTING_PORT: ${TORRENT_PORT}
      QBT_WEBUI_PORT: ${WEBUI_PORT}
      TZ: ${TIMEZONE}
      PUID: ${QBT_PUID}
      PGID: ${QBT_PGID}
      UMASK: "022"
    ports:
      - "${WEBUI_BIND}:${WEBUI_PORT}:${WEBUI_PORT}/tcp"
      - "0.0.0.0:${TORRENT_PORT}:${TORRENT_PORT}/tcp"
      - "0.0.0.0:${TORRENT_PORT}:${TORRENT_PORT}/udp"
    volumes:
      - "${QBT_CONFIG_DIR}:/config"
      - "${DATA_DIR}:/data"
      - "${DOWNLOAD_DIR}:/downloads"
      - "${INCOMPLETE_DIR}:/incomplete"
  nginx:
    image: ${NGINX_IMAGE}
    container_name: ttdd-nginx
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    sysctls:
      net.core.somaxconn: "65535"
    ports:
      - "0.0.0.0:80:80/tcp"
    volumes:
      # Read-only bind to the actual download directory; no cache/copy.
      - "${DOWNLOAD_DIR}:/downloads:ro"
      - "${NGINX_MAIN_CONF}:/etc/nginx/nginx.conf:ro"
      - "${NGINX_CONF_DIR}:/etc/nginx/conf.d:ro"
YAML
  fi
}


write_nginx_main_config() {
  # High-throughput static-file profile. These are capacity ceilings, not
  # bandwidth throttles. No per-IP, per-request, or response-rate limiter is
  # configured anywhere in the generated Nginx configuration.
  cat > "${NGINX_MAIN_CONF}" <<'NGINX'
user nginx;
worker_processes auto;
worker_rlimit_nofile 262144;
pid /var/run/nginx.pid;
error_log /var/log/nginx/error.log warn;

# The official default is much lower. Raise connection capacity while keeping
# worker count automatic so Nginx scales with available CPU cores.
events {
    worker_connections 65535;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Static large-file delivery: kernel zero-copy path + full packets.
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    # Explicitly unlimited response rate. Nginx byte-range support remains
    # enabled, so download managers may open many parallel range requests.
    limit_rate 0;
    limit_rate_after 0;

    # Keep connections reusable without keeping idle sockets around forever.
    keepalive_timeout 30s;
    keepalive_requests 1000;
    send_timeout 300s;
    reset_timedout_connection on;

    # Direct-download traffic can be very high volume; avoid turning access
    # logging into a disk-I/O bottleneck. Errors are still logged at warn level.
    access_log off;
    server_tokens off;
    gzip off;

    include /etc/nginx/conf.d/*.conf;
}
NGINX
  chmod 0644 "${NGINX_MAIN_CONF}"
}


write_nginx_reload_script() {
  if [[ "${ENABLE_SSL}" != "1" ]]; then rm -f "${NGINX_ENTRYPOINT_DIR}/99-cert-reload.sh"; return; fi
  cat > "${NGINX_ENTRYPOINT_DIR}/99-cert-reload.sh" <<'SH'
#!/bin/sh
set -eu
(
  while :; do
    sleep "${CERT_RELOAD_INTERVAL:-60}"
    if [ -f /var/www/certbot/.reload-nginx ]; then
      if nginx -t; then nginx -s reload && rm -f /var/www/certbot/.reload-nginx; fi
    fi
  done
) &
SH
  chmod 0755 "${NGINX_ENTRYPOINT_DIR}/99-cert-reload.sh"
}

write_nginx_http_config() {
  cat > "${NGINX_CONF_DIR}/default.conf" <<'NGINX'
server {
    listen 80 default_server reuseport backlog=65535;
    server_name _;
    root /downloads;
    charset utf-8;
    server_tokens off;
    limit_rate 0;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
        allow all;
        try_files $uri =404;
    }
    location / {
        limit_except GET HEAD { deny all; }
        try_files $uri $uri/ =404;
    }
    location ~ /\. { deny all; }
    add_header X-Content-Type-Options "nosniff" always;
}
NGINX
  chmod 0644 "${NGINX_CONF_DIR}/default.conf"
}

write_nginx_https_config() {
  cat > "${NGINX_CONF_DIR}/default.conf" <<EOF
server {
    listen 80 default_server reuseport backlog=65535;
    server_name _;
    root /downloads;
    charset utf-8;
    server_tokens off;
    limit_rate 0;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;
    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; default_type text/plain; allow all; try_files \$uri =404; }
    location / { limit_except GET HEAD { deny all; } try_files \$uri \$uri/ =404; }
    location ~ /\. { deny all; }
    add_header X-Content-Type-Options "nosniff" always;
}
server {
    listen 443 ssl default_server reuseport backlog=65535;
    server_name ${PUBLIC_IP};
    root /downloads;
    charset utf-8;
    server_tokens off;
    limit_rate 0;
    ssl_certificate /etc/letsencrypt/live/${CERT_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CERT_NAME}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:TTDD_SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;
    location / { limit_except GET HEAD { deny all; } try_files \$uri \$uri/ =404; }
    location ~ /\. { deny all; }
    add_header X-Content-Type-Options "nosniff" always;
}
EOF
  chmod 0644 "${NGINX_CONF_DIR}/default.conf"
}

validate_generated_stack() {
  log "Validating generated shell, Compose and Nginx files."
  bash -n "$0"
  python3 - "${COMPOSE_FILE}" <<'PY'
import sys,yaml
x=yaml.safe_load(open(sys.argv[1]))
assert isinstance(x,dict) and 'services' in x
assert 'qbittorrent' in x['services'] and 'nginx' in x['services']
PY
  compose config >/dev/null
}

pull_images() {
  [[ "${SKIP_IMAGE_PULL}" == "1" ]] && { log "Skipping image pulls by request."; return; }
  log "Pulling qBittorrent and Nginx images."
  compose pull qbittorrent nginx
  if [[ "${ENABLE_SSL}" == "1" ]]; then
    # certbot and certbot-renew use the same image. On a normal reinstall with
    # a still-valid certificate, keep the already-present image to avoid an
    # unnecessary network pull. Pull it only when it is missing or issuance is needed.
    if certificate_is_reusable && docker image inspect "${CERTBOT_IMAGE}" >/dev/null 2>&1; then
      log "Existing SSL certificate and Certbot image are reusable; skipping Certbot pull."
    else
      log "Preparing Certbot image for SSL issuance/renewal."
      compose --profile tools pull certbot
    fi
  fi
}

wait_for_qbittorrent() {
  local i
  for i in $(seq 1 90); do curl -fsS --max-time 2 "http://127.0.0.1:${WEBUI_PORT}/" >/dev/null 2>&1 && return 0; sleep 1; done
  die "qBittorrent WebUI did not become ready."
}

verify_qbittorrent_authentication() {
  local cookie body code
  cookie="$(mktemp)"; body="$(mktemp)"
  curl -sS --cookie-jar "$cookie" -H "Referer: http://127.0.0.1:${WEBUI_PORT}" -H "Origin: http://127.0.0.1:${WEBUI_PORT}" \
    --data-urlencode "username=${QBT_USERNAME}" --data-urlencode "password=${QBT_PASSWORD}" \
    "http://127.0.0.1:${WEBUI_PORT}/api/v2/auth/login" >/dev/null
  code="$(curl -sS -o "$body" -w '%{http_code}' --cookie "$cookie" "http://127.0.0.1:${WEBUI_PORT}/api/v2/app/version")"
  rm -f "$cookie"
  [[ "$code" == "200" ]] || { cat "$body" >&2; rm -f "$body"; die "qBittorrent rejected the configured password."; }
  QBT_RUNTIME_VERSION="$(tr -d '\r\n' < "$body")"; rm -f "$body"
  printf 'Authenticated qBittorrent version: %s\n' "${QBT_RUNTIME_VERSION}"
}

start_http_stack() {
  log "Starting qBittorrent and Nginx."
  compose up -d qbittorrent nginx
  wait_for_qbittorrent
  verify_qbittorrent_authentication
  compose exec -T nginx nginx -t
  curl -fsS --max-time 5 -H "Host: ${PUBLIC_IP}" http://127.0.0.1/ >/dev/null
}

certificate_is_reusable() {
  [[ -s "${CERT_CERT}" && -s "${CERT_FULLCHAIN}" && -s "${CERT_PRIVATE_KEY}" ]] || return 1
  openssl x509 -in "${CERT_CERT}" -noout -checkend 43200 >/dev/null 2>&1 || return 1
  openssl x509 -in "${CERT_CERT}" -noout -ext subjectAltName 2>/dev/null | grep -Fq "IP Address:${PUBLIC_IP}"
}

verify_acme_webroot() {
  local f="${ACME_DIR}/.well-known/acme-challenge/ttdd-acme-test-${RANDOM}"
  printf 'acme-ok\n' > "$f"; chmod 0644 "$f"
  [[ "$(curl -fsS --max-time 5 -H "Host: ${PUBLIC_IP}" "http://127.0.0.1/.well-known/acme-challenge/$(basename "$f")")" == "acme-ok" ]] || die "Nginx ACME webroot test failed."
  rm -f "$f"
}

obtain_or_reuse_certificate() {
  [[ "${ENABLE_SSL}" == "1" ]] || return 0
  if certificate_is_reusable; then log "Reusing existing valid certificate; Certbot issuance is skipped."; return; fi
  log "Requesting a Let's Encrypt IP certificate."
  verify_acme_webroot
  local certbot_version args
  certbot_version="$(compose --profile tools run --rm certbot --version | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -n1)"
  dpkg --compare-versions "$certbot_version" ge 5.4 || die "Certbot ${certbot_version} is too old for IP certificates."
  args=(certonly --non-interactive --agree-tos --preferred-profile shortlived --webroot --webroot-path /var/www/certbot --ip-address "${PUBLIC_IP}" --cert-name "${CERT_NAME}" --keep-until-expiring)
  [[ -n "${LETSENCRYPT_EMAIL}" ]] && args+=(--email "${LETSENCRYPT_EMAIL}") || args+=(--register-unsafely-without-email)
  [[ "${LETSENCRYPT_STAGING}" == "1" ]] && args+=(--staging)
  rm -f "${CERTBOT_ISSUE_LOG}"
  compose --profile tools run --rm certbot "${args[@]}" 2>&1 | tee "${CERTBOT_ISSUE_LOG}"
  certificate_is_reusable || die "Certbot finished but the expected valid certificate was not found."
}

enable_https_and_renewal() {
  [[ "${ENABLE_SSL}" == "1" ]] || return 0
  log "Enabling HTTPS and renewal."
  write_nginx_https_config
  compose exec -T nginx nginx -t
  compose restart nginx
  local i
  for i in $(seq 1 45); do
    if [[ "${LETSENCRYPT_STAGING}" == "1" ]]; then curl -kfsS --max-time 2 --resolve "${PUBLIC_IP}:443:127.0.0.1" "https://${PUBLIC_IP}/" >/dev/null 2>&1 && break
    else curl -fsS --max-time 2 --resolve "${PUBLIC_IP}:443:127.0.0.1" "https://${PUBLIC_IP}/" >/dev/null 2>&1 && break; fi
    sleep 1
  done
  compose up -d certbot-renew
  if [[ "${RUN_RENEWAL_DRY_RUN}" == "1" ]]; then
    log "Running opt-in Certbot renewal dry-run."
    compose --profile tools run --rm certbot renew --dry-run 2>&1 | tee "${CERTBOT_RENEW_TEST_LOG}"
  fi
}

verify_direct_downloads() {
  log "Verifying direct download using one temporary visible file."
  local f="${DOWNLOAD_DIR}/ttdd-install-test-${RANDOM}.txt" expected="torrent-to-direct-download-ok"
  printf '%s\n' "$expected" > "$f"; chown "${QBT_PUID}:${QBT_PGID}" "$f"; chmod 0644 "$f"
  [[ "$(curl -fsS --max-time 5 -H "Host: ${PUBLIC_IP}" "http://127.0.0.1/$(basename "$f")")" == "$expected" ]] || die "HTTP direct-download test failed."
  if [[ "${ENABLE_SSL}" == "1" ]]; then
    if [[ "${LETSENCRYPT_STAGING}" == "1" ]]; then
      [[ "$(curl -kfsS --max-time 5 --resolve "${PUBLIC_IP}:443:127.0.0.1" "https://${PUBLIC_IP}/$(basename "$f")")" == "$expected" ]] || die "HTTPS direct-download test failed."
    else
      [[ "$(curl -fsS --max-time 5 --resolve "${PUBLIC_IP}:443:127.0.0.1" "https://${PUBLIC_IP}/$(basename "$f")")" == "$expected" ]] || die "HTTPS direct-download test failed."
    fi
  fi
  rm -f "$f"
}

find_trash_dirs() {
  [[ -d "${DATA_DIR}" ]] || return 0
  find "${DATA_DIR}" -xdev -maxdepth 5 -type d \( -name '.Trash-*' -o -name '.Trash' \) -print 2>/dev/null || true
}
report_trash_usage() {
  local found=0 d
  while IFS= read -r d; do [[ -n "$d" ]] || continue; found=1; du -sh "$d" 2>/dev/null || printf '%s\n' "$d"; done < <(find_trash_dirs)
  [[ "$found" == "1" ]] || printf 'No qBittorrent .Trash directories found under %s.\n' "${DATA_DIR}"
}

purge_trash() {
  require_root
  log "Finding qBittorrent trash directories."
  local dirs=() d
  while IFS= read -r d; do [[ -n "$d" ]] && dirs+=("$d"); done < <(find_trash_dirs)
  (( ${#dirs[@]} > 0 )) || { printf 'No .Trash directories found.\n'; return; }
  printf 'Space currently held by qBittorrent trash:\n'; for d in "${dirs[@]}"; do du -sh "$d" 2>/dev/null || printf '%s\n' "$d"; done
  if [[ "${FORCE}" != "1" ]] && ! ask_yes_no "Permanently delete ALL content in these trash directories?" "N"; then printf 'Nothing deleted.\n'; return; fi
  for d in "${dirs[@]}"; do rm -rf --one-file-system -- "$d"; done
  printf 'qBittorrent trash removed permanently.\n'
}

disk_check() {
  require_root
  printf 'torrent-to-direct-download disk check v%s\n\n' "${SCRIPT_VERSION}"
  df -hT "${DATA_DIR}" 2>/dev/null || df -hT
  printf '\nPersistent directory usage:\n'; du -sh "${DATA_DIR}" "${DOWNLOAD_DIR}" "${INCOMPLETE_DIR}" 2>/dev/null || true
  printf '\nqBittorrent hidden trash:\n'; report_trash_usage
  printf '\nDeleted files still held open by a process:\n'
  if command -v lsof >/dev/null 2>&1; then lsof +L1 2>/dev/null | { head -n1; grep -F "${DATA_DIR}" || true; } || true; else printf 'lsof not installed.\n'; fi
  if command -v docker >/dev/null 2>&1; then
    printf '\nDocker disk usage:\n'; docker system df 2>/dev/null || true
    printf '\nContainer mounts (to prove bind aliases are not copies):\n'
    docker inspect "${QBT_CONTAINER}" "${NGINX_CONTAINER}" --format '{{.Name}} {{range .Mounts}}{{.Type}}:{{.Source}}->{{.Destination}} {{end}}' 2>/dev/null || true
  fi
}

write_information_files() {
  cat > "${DOWNLOAD_INFO_FILE}" <<EOF
Direct Download Information
===========================
HTTP:  http://${PUBLIC_IP}/
$( [[ "${ENABLE_SSL}" == "1" ]] && printf 'HTTPS: https://%s/' "${PUBLIC_IP}" || printf 'HTTPS: disabled' )
Published host directory: ${DOWNLOAD_DIR}
Nginx uses a read-only bind mount of that same directory; no duplicate copy is created.
Installer version: ${SCRIPT_VERSION}
EOF
  if [[ "${ENABLE_SSL}" == "1" ]]; then
    cat > "${SSL_INFO_FILE}" <<EOF
Let's Encrypt IP Certificate
============================
IP: ${PUBLIC_IP}
Certificate name: ${CERT_NAME}
Not after: $(openssl x509 -in "${CERT_CERT}" -noout -enddate | cut -d= -f2-)
Renewal container: ${CERTBOT_RENEW_CONTAINER}
EOF
  else
    printf 'SSL/HTTPS is disabled. Re-run install.sh --enable-ssl to enable it.\n' > "${SSL_INFO_FILE}"
  fi
  chmod 0600 "${DOWNLOAD_INFO_FILE}" "${SSL_INFO_FILE}"
}

print_summary() {
  printf '\n============================================================\n'
  printf 'torrent-to-direct-download v%s completed successfully\n' "${SCRIPT_VERSION}"
  printf '============================================================\n'
  printf 'qBittorrent: http://%s:%s\nUsername: %s\nPassword: %s\n' "${PUBLIC_IP}" "${WEBUI_PORT}" "${QBT_USERNAME}" "${QBT_PASSWORD}"
  printf 'Direct HTTP: http://%s/\n' "${PUBLIC_IP}"
  [[ "${ENABLE_SSL}" == "1" ]] && printf 'Direct HTTPS: https://%s/\n' "${PUBLIC_IP}" || printf 'Direct HTTPS: disabled\n'
  printf 'Downloads: %s\nIncomplete: %s\n' "${DOWNLOAD_DIR}" "${INCOMPLETE_DIR}"
  printf '\nDeletion mode: permanent when qBittorrent "also delete files" is selected.\n'
  if [[ -n "$(find_trash_dirs)" ]]; then
    printf 'Old .Trash data detected. Inspect: sudo bash install.sh --disk-check\n'
    printf 'Purge after review: sudo bash install.sh --purge-trash\n'
  fi
}

reset_password_only() {
  require_root
  [[ -f "${ENV_FILE}" && -f "${COMPOSE_FILE}" ]] || die "Existing installation not found under ${STACK_DIR}."
  command -v docker >/dev/null 2>&1 || die "Docker is not installed."
  command -v openssl >/dev/null 2>&1 || die "openssl is required."
  command -v python3 >/dev/null 2>&1 || die "python3 is required."
  [[ -s "${QBT_CONFIG_FILE}" ]] || die "qBittorrent config not found: ${QBT_CONFIG_FILE}"
  # Recover the old URL for v2.x installations whose .env did not persist PUBLIC_IP.
  if [[ -z "${PUBLIC_IP}" && -r "${CREDENTIAL_FILE}" ]]; then
    PUBLIC_IP="$(sed -nE 's#^URL: http://([0-9.]+):[0-9]+.*#\1#p' "${CREDENTIAL_FILE}" | head -n1)"
  fi
  # Password mode intentionally does not read the old password.
  if [[ -z "${QBT_PASSWORD}" ]]; then QBT_PASSWORD="$(openssl rand -hex 18)"; fi
  (( ${#QBT_PASSWORD} >= 12 )) || die "QBT_PASSWORD must contain at least 12 characters."
  log "Resetting qBittorrent password only; no apt, pulls, Nginx, SSL or data changes."
  compose stop qbittorrent
  configure_qbittorrent_offline password
  compose up -d qbittorrent
  wait_for_qbittorrent
  verify_qbittorrent_authentication
  write_credentials_file
  printf '\nPassword reset completed. No reinstall was performed.\nUsername: %s\nPassword: %s\n' "${QBT_USERNAME}" "${QBT_PASSWORD}"
}

status_action() {
  require_root
  [[ -f "${ENV_FILE}" && -f "${COMPOSE_FILE}" ]] || die "Existing installation not found under ${STACK_DIR}."
  compose ps
  printf '\nDisk usage:\n'; du -sh "${DOWNLOAD_DIR}" "${INCOMPLETE_DIR}" 2>/dev/null || true
  printf '\nTrash usage:\n'; report_trash_usage
}

main_install() {
  require_root
  require_ubuntu
  validate_port "${WEBUI_PORT}" "WEBUI_PORT"; validate_port "${TORRENT_PORT}" "TORRENT_PORT"
  validate_uid_gid "${QBT_PUID}" "QBT_PUID"; validate_uid_gid "${QBT_PGID}" "QBT_PGID"
  validate_boolean "${LETSENCRYPT_STAGING}" "LETSENCRYPT_STAGING"
  validate_boolean "${RUN_RENEWAL_DRY_RUN}" "RUN_RENEWAL_DRY_RUN"
  validate_boolean "${SKIP_IMAGE_PULL}" "SKIP_IMAGE_PULL"
  [[ "${WEBUI_PORT}" != 80 && "${WEBUI_PORT}" != 443 ]] || die "WEBUI_PORT cannot be 80 or 443."
  [[ "${TORRENT_PORT}" != 80 && "${TORRENT_PORT}" != 443 ]] || die "TORRENT_PORT cannot be 80 or 443."
  [[ "${WEBUI_PORT}" != "${TORRENT_PORT}" ]] || die "WEBUI_PORT and TORRENT_PORT must be different."

  # The SSL decision occurs before apt, Docker image pulls, Certbot, or service changes.
  resolve_ssl_choice

  install_base_packages_if_needed
  install_official_docker_if_needed
  detect_public_ip
  initialize_certificate_paths

  backup_stack_metadata
  stop_previous_stack
  stop_legacy_native_qbt
  handle_host_nginx_safely
  check_tcp_port_free 80 "Nginx direct downloads"
  [[ "${ENABLE_SSL}" == "1" ]] && check_tcp_port_free 443 "Nginx HTTPS"
  check_tcp_port_free "${WEBUI_PORT}" "qBittorrent WebUI"
  check_tcp_port_free "${TORRENT_PORT}" "qBittorrent torrent traffic"
  check_udp_port_free "${TORRENT_PORT}" "qBittorrent torrent traffic"
  configure_ufw_if_active

  prepare_directories
  migrate_previous_native_data
  configure_qbittorrent_offline full
  write_environment_file
  write_compose_file
  write_nginx_main_config
  write_nginx_reload_script
  write_nginx_http_config
  validate_generated_stack
  pull_images
  start_http_stack
  obtain_or_reuse_certificate
  enable_https_and_renewal
  verify_direct_downloads
  write_information_files

  printf 'installer_version=%s\ncompleted_at=%s\nenable_ssl=%s\n' "${SCRIPT_VERSION}" "$(date --iso-8601=seconds)" "${ENABLE_SSL}" > "${STATE_FILE}"
  chmod 0600 "${STATE_FILE}"
  compose ps
  print_summary
}

if [[ "${TTDD_SOURCE_ONLY:-0}" != "1" ]]; then
  case "${ACTION}" in
    install) main_install ;;
    reset-password) reset_password_only ;;
    disk-check) disk_check ;;
    purge-trash) purge_trash ;;
    status) status_action ;;
  esac
fi
