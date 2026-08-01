#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# torrent-to-direct-download
# Fully containerized qBittorrent + Nginx + Certbot installer for Ubuntu.
#
# Runtime services:
#   - qBittorrent: official qbittorrentofficial/qbittorrent-nox image
#   - Nginx: official nginx stable Alpine image
#   - Certbot: official certbot/certbot image
#
# The installer itself runs on the Ubuntu host as root and creates a
# Docker Compose stack under /opt/torrent-to-direct-download.

SCRIPT_VERSION="2.1.0"
STACK_NAME="torrent-to-direct-download"
STACK_DIR="${STACK_DIR:-/opt/${STACK_NAME}}"
DATA_DIR="${DATA_DIR:-/srv/qbittorrent}"

QBT_CONFIG_DIR="${QBT_CONFIG_DIR:-${DATA_DIR}/config}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${DATA_DIR}/downloads}"
INCOMPLETE_DIR="${INCOMPLETE_DIR:-${DATA_DIR}/incomplete}"
LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-${DATA_DIR}/letsencrypt}"
ACME_DIR="${ACME_DIR:-${DATA_DIR}/acme}"

COMPOSE_FILE="${STACK_DIR}/compose.yaml"
ENV_FILE="${STACK_DIR}/.env"
NGINX_CONF_DIR="${STACK_DIR}/nginx/conf.d"
NGINX_ENTRYPOINT_DIR="${STACK_DIR}/nginx/entrypoint"

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

QBT_USERNAME="${QBT_USERNAME:-admin}"
QBT_PASSWORD="${QBT_PASSWORD:-}"
RESET_QBT_PASSWORD="${RESET_QBT_PASSWORD:-0}"

PUBLIC_IP="${PUBLIC_IP:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-0}"
RUN_RENEWAL_DRY_RUN="${RUN_RENEWAL_DRY_RUN:-1}"

CREDENTIAL_FILE="/root/qbittorrent-credentials.txt"
DOWNLOAD_INFO_FILE="/root/qbittorrent-download-info.txt"
SSL_INFO_FILE="/root/qbittorrent-ip-ssl-info.txt"
STATE_FILE="${STACK_DIR}/.installation-complete"
INSTALL_COMPLETE=0

CERT_NAME=""
CERT_LIVE_DIR=""
CERT_FULLCHAIN=""
CERT_PRIVATE_KEY=""
CERT_CERT=""
CERT_CHAIN=""

BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
QBT_CONFIG_FILE="${QBT_CONFIG_DIR}/qBittorrent/config/qBittorrent.conf"
QBT_DATA_DIR="${QBT_CONFIG_DIR}/qBittorrent/data"

compose() {
    docker compose \
        --project-name "${STACK_NAME}" \
        --env-file "${ENV_FILE}" \
        --file "${COMPOSE_FILE}" \
        "$@"
}

log() {
    printf '\n>>> %s\n' "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

on_error() {
    local exit_code=$?
    local line_number="${1:-unknown}"

    printf '\n============================================================\n' >&2
    printf 'Installation failed at line %s (exit code %s).\n' \
        "${line_number}" "${exit_code}" >&2
    printf '============================================================\n' >&2

    if command -v docker >/dev/null 2>&1 \
        && [[ -f "${COMPOSE_FILE}" ]] \
        && [[ -f "${ENV_FILE}" ]]; then
        printf '\nDocker Compose status:\n' >&2
        compose ps 2>/dev/null || true

        printf '\nRecent qBittorrent logs:\n' >&2
        compose logs --tail=100 qbittorrent 2>/dev/null || true

        printf '\nRecent Nginx logs:\n' >&2
        compose logs --tail=100 nginx 2>/dev/null || true

        printf '\nRecent Certbot renewal logs:\n' >&2
        compose logs --tail=100 certbot-renew 2>/dev/null || true

        if [[ "${INSTALL_COMPLETE:-0}" != "1" ]]; then
            printf '\nStopping the incomplete Compose stack. Persistent data is preserved.\n' >&2
            compose down --remove-orphans 2>/dev/null || true
            rm -f "${STATE_FILE}" 2>/dev/null || true
        fi
    fi

    exit "${exit_code}"
}

trap 'on_error "$LINENO"' ERR

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this installer as root."
}

validate_boolean() {
    local value="$1"
    local name="$2"

    [[ "${value}" == "0" || "${value}" == "1" ]] \
        || die "${name} must be 0 or 1."
}

validate_port() {
    local value="$1"
    local name="$2"

    [[ "${value}" =~ ^[0-9]+$ ]] \
        || die "${name} must be a number."

    (( value >= 1 && value <= 65535 )) \
        || die "${name} must be between 1 and 65535."
}

validate_ipv4() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

raise SystemExit(0 if ip.version == 4 else 1)
PY
}

validate_public_ipv4() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

raise SystemExit(0 if ip.version == 4 and ip.is_global else 1)
PY
}

require_ubuntu() {
    [[ -r /etc/os-release ]] || die "/etc/os-release was not found."

    # shellcheck disable=SC1091
    . /etc/os-release

    [[ "${ID:-}" == "ubuntu" ]] \
        || die "This installer supports Ubuntu only."

    case "${VERSION_ID:-}" in
        22.04|24.04|25.10|26.04)
            ;;
        *)
            die "Unsupported Ubuntu release: ${VERSION_ID:-unknown}"
            ;;
    esac
}

install_base_packages() {
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        openssl \
        python3 \
        python3-yaml \
        iproute2
}

install_official_docker_if_needed() {
    if command -v docker >/dev/null 2>&1; then
        systemctl enable --now docker.service 2>/dev/null || true

        if docker info >/dev/null 2>&1 \
            && docker compose version >/dev/null 2>&1; then
            log "Docker Engine and Docker Compose are already available."
            return
        fi
    fi

    log "Installing Docker Engine and Compose from Docker's official repository."

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
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

    apt-get update

    # Remove only conflicting packages that are actually installed.
    local conflicting_packages=()
    local package

    for package in \
        docker.io \
        docker-compose \
        docker-compose-v2 \
        docker-doc \
        docker-buildx \
        podman-docker \
        containerd \
        runc; do

        if dpkg-query -W -f='${db:Status-Status}' "${package}" 2>/dev/null \
            | grep -q '^installed$'; then
            conflicting_packages+=("${package}")
        fi
    done

    if (( ${#conflicting_packages[@]} > 0 )); then
        apt-get remove -y "${conflicting_packages[@]}"
    fi

    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    docker info >/dev/null
    docker compose version >/dev/null
}

detect_public_ip() {
    local endpoint
    local detected=""

    if [[ -n "${PUBLIC_IP}" ]]; then
        validate_public_ipv4 "${PUBLIC_IP}" \
            || die "PUBLIC_IP is not a globally routable IPv4 address: ${PUBLIC_IP}"
        return
    fi

    log "Detecting the server's public IPv4 address."

    for endpoint in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://ifconfig.co/ip"; do

        detected="$(
            curl -4fsS --max-time 10 "${endpoint}" 2>/dev/null \
                | tr -d '[:space:]' \
                || true
        )"

        if [[ -n "${detected}" ]] \
            && validate_public_ipv4 "${detected}"; then
            PUBLIC_IP="${detected}"
            break
        fi
    done

    [[ -n "${PUBLIC_IP}" ]] \
        || die "Could not detect a public IPv4. Set PUBLIC_IP explicitly."

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

stop_previous_native_services() {
    log "Stopping previous installer-managed native services."

    if systemctl list-unit-files 2>/dev/null \
        | grep -q '^qbittorrent-root\.service'; then
        systemctl disable --now qbittorrent-root.service 2>/dev/null || true

        if [[ -f /etc/systemd/system/qbittorrent-root.service ]]; then
            cp -a \
                /etc/systemd/system/qbittorrent-root.service \
                "/etc/systemd/system/qbittorrent-root.service.backup.${BACKUP_STAMP}"
        fi
    fi

    if systemctl list-unit-files 2>/dev/null \
        | grep -q '^nginx\.service'; then

        if systemctl is-active --quiet nginx.service \
            || systemctl is-enabled --quiet nginx.service 2>/dev/null; then

            install -d -m 0700 /root/torrent-to-direct-download-backups

            if [[ -d /etc/nginx ]]; then
                tar -czf \
                    "/root/torrent-to-direct-download-backups/host-nginx.${BACKUP_STAMP}.tar.gz" \
                    -C /etc nginx
            fi

            systemctl disable --now nginx.service 2>/dev/null || true
            printf 'Disabled the host Nginx service; its configuration was backed up.\n'
        fi
    fi

    pkill -TERM -x qbittorrent-nox 2>/dev/null || true
    sleep 1
    pkill -KILL -x qbittorrent-nox 2>/dev/null || true

    systemctl daemon-reload
}

stop_previous_containers() {
    log "Stopping previous qBittorrent/Nginx containers from earlier installer versions."

    if [[ -f "${COMPOSE_FILE}" && -f "${ENV_FILE}" ]]; then
        compose down --remove-orphans 2>/dev/null || true
    fi

    local container
    for container in \
        qbittorrent-nox \
        "${QBT_CONTAINER}" \
        "${NGINX_CONTAINER}" \
        "${CERTBOT_RENEW_CONTAINER}"; do

        if docker container inspect "${container}" >/dev/null 2>&1; then
            docker rm -f "${container}" >/dev/null
        fi
    done
}

check_port_is_free() {
    local port="$1"
    local description="$2"
    local listeners=""

    listeners="$(
        ss -H -lntp 2>/dev/null \
            | awk -v p=":${port}" '$4 ~ (p "$") {print}' \
            || true
    )"

    [[ -z "${listeners}" ]] || {
        printf '\nPort %s is already in use:\n%s\n' "${port}" "${listeners}" >&2
        die "${description} requires TCP port ${port}."
    }
}

check_udp_port_is_free() {
    local port="$1"
    local description="$2"
    local listeners=""

    listeners="$(
        ss -H -lunp 2>/dev/null \
            | awk -v p=":${port}" '$5 ~ (p "$") || $4 ~ (p "$") {print}' \
            || true
    )"

    [[ -z "${listeners}" ]] || {
        printf '\nUDP port %s is already in use:\n%s\n' "${port}" "${listeners}" >&2
        die "${description} requires UDP port ${port}."
    }
}

configure_ufw_if_active() {
    if ! command -v ufw >/dev/null 2>&1; then
        return
    fi

    if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
        return
    fi

    log "Opening the required ports in the active UFW firewall."

    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow "${WEBUI_PORT}/tcp" >/dev/null
    ufw allow "${TORRENT_PORT}/tcp" >/dev/null
    ufw allow "${TORRENT_PORT}/udp" >/dev/null
}

prepare_directories() {
    log "Preparing persistent data and stack directories."

    install -d -m 0755 "${STACK_DIR}"
    install -d -m 0755 "${NGINX_CONF_DIR}"
    install -d -m 0755 "${NGINX_ENTRYPOINT_DIR}"

    install -d -m 0755 "${DATA_DIR}"
    install -d -m 0755 "${QBT_CONFIG_DIR}"
    install -d -m 0755 "${DOWNLOAD_DIR}"
    install -d -m 0755 "${INCOMPLETE_DIR}"
    install -d -m 0755 "${LETSENCRYPT_DIR}"
    install -d -m 0755 "${ACME_DIR}/.well-known/acme-challenge"

    install -d -m 0755 "$(dirname "${QBT_CONFIG_FILE}")"
    install -d -m 0755 "${QBT_DATA_DIR}"
}

migrate_previous_data() {
    log "Checking for data from previous native installations."

    if [[ ! -s "${QBT_CONFIG_FILE}" \
          && -s /root/.config/qBittorrent/qBittorrent.conf ]]; then
        cp -a \
            /root/.config/qBittorrent/qBittorrent.conf \
            "${QBT_CONFIG_FILE}"
        printf 'Migrated native qBittorrent configuration.\n'
    fi

    if [[ -d /root/.local/share/qBittorrent \
          && -z "$(find "${QBT_DATA_DIR}" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        cp -a /root/.local/share/qBittorrent/. "${QBT_DATA_DIR}/"
        printf 'Migrated native torrent state and resume data.\n'
    fi

}

read_existing_password() {
    local existing=""

    if [[ "${RESET_QBT_PASSWORD}" == "1" ]]; then
        return
    fi

    if [[ -r "${CREDENTIAL_FILE}" ]]; then
        existing="$(
            awk -F': ' '/^Password: / {print $2; exit}' \
                "${CREDENTIAL_FILE}" \
                || true
        )"
    fi

    if [[ -n "${existing}" \
          && "${existing}" != "unchanged" \
          && "${existing}" != "temporary" ]]; then
        QBT_PASSWORD="${existing}"
    fi
}

generate_qbittorrent_password_hash() {
    local password="$1"

    python3 - "${password}" <<'PY'
import base64
import hashlib
import os
import sys

password = sys.argv[1].encode("utf-8")

# Verify the implementation against qBittorrent's known adminadmin vector.
known_salt = base64.b64decode("ARQ77eY1NUZaQsuDHbIMCA==")
known_expected = base64.b64decode(
    "0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gur2hmQCvCDpm39Q+PsJRJPaCU51dEiz+dTzh8qbPsL8WkFljQYFQ=="
)
known_actual = hashlib.pbkdf2_hmac(
    "sha512", b"adminadmin", known_salt, 100000
)
if known_actual != known_expected:
    raise SystemExit("PBKDF2 self-test failed")

salt = os.urandom(16)
derived = hashlib.pbkdf2_hmac("sha512", password, salt, 100000)

print(
    "@ByteArray("
    + base64.b64encode(salt).decode("ascii")
    + ":"
    + base64.b64encode(derived).decode("ascii")
    + ")"
)
PY
}

configure_qbittorrent_offline() {
    local password_hash=""

    log "Creating a deterministic qBittorrent WebUI login without using its Web API."

    read_existing_password

    if [[ -z "${QBT_PASSWORD}" ]]; then
        QBT_PASSWORD="$(openssl rand -hex 18)"
    fi

    (( ${#QBT_PASSWORD} >= 12 )) \
        || die "QBT_PASSWORD must contain at least 12 characters."

    password_hash="$(generate_qbittorrent_password_hash "${QBT_PASSWORD}")"

    if [[ -s "${QBT_CONFIG_FILE}" ]]; then
        cp -a \
            "${QBT_CONFIG_FILE}" \
            "${QBT_CONFIG_FILE}.backup.${BACKUP_STAMP}"
    fi

    python3 - \
        "${QBT_CONFIG_FILE}" \
        "${QBT_USERNAME}" \
        "${password_hash}" \
        "${WEBUI_PORT}" \
        "${TORRENT_PORT}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
username = sys.argv[2]
password_hash = sys.argv[3]
webui_port = sys.argv[4]
torrent_port = sys.argv[5]

text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
lines = text.splitlines()

def set_value(section: str, key: str, value: str) -> None:
    global lines

    section_header = f"[{section}]"
    start = None
    end = len(lines)

    for index, line in enumerate(lines):
        if line.strip() == section_header:
            start = index
            break

    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend([section_header, f"{key}={value}"])
        return

    for index in range(start + 1, len(lines)):
        if lines[index].startswith("[") and lines[index].endswith("]"):
            end = index
            break

    prefix = f"{key}="
    for index in range(start + 1, end):
        if lines[index].startswith(prefix):
            lines[index] = f"{key}={value}"
            return

    lines.insert(end, f"{key}={value}")

set_value("LegalNotice", "Accepted", "true")

set_value("BitTorrent", r"Session\DefaultSavePath", "/downloads")
set_value("BitTorrent", r"Session\TempPath", "/incomplete")
set_value("BitTorrent", r"Session\TempPathEnabled", "true")
set_value("BitTorrent", r"Session\Port", torrent_port)
set_value("BitTorrent", r"Session\QueueingSystemEnabled", "false")

# Compatibility keys retained for installations migrated from older releases.
set_value("Preferences", r"Downloads\SavePath", "/downloads/")
set_value("Preferences", r"Downloads\TempPath", "/incomplete/")
set_value("Preferences", r"Downloads\TempPathEnabled", "true")

set_value("Preferences", r"WebUI\Address", "*")
set_value("Preferences", r"WebUI\Port", webui_port)
set_value("Preferences", r"WebUI\Username", username)
set_value(
    "Preferences",
    r"WebUI\Password_PBKDF2",
    f'"{password_hash}"',
)
set_value("Preferences", r"WebUI\LocalHostAuth", "true")
set_value("Preferences", r"WebUI\AuthSubnetWhitelistEnabled", "false")
set_value("Preferences", r"WebUI\AuthSubnetWhitelist", "@Invalid()")
set_value("Preferences", r"WebUI\HostHeaderValidation", "false")
set_value("Preferences", r"WebUI\CSRFProtection", "true")
set_value("Preferences", r"WebUI\ClickjackingProtection", "true")
set_value("Preferences", r"WebUI\SecureCookie", "false")
set_value("Preferences", r"WebUI\ServerDomains", "*")
set_value("Preferences", r"WebUI\UseUPnP", "false")

path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY

    chown -R 1000:1000 \
        "${QBT_CONFIG_DIR}" \
        "${DOWNLOAD_DIR}" \
        "${INCOMPLETE_DIR}"

    chmod -R a+rX "${DOWNLOAD_DIR}" "${INCOMPLETE_DIR}"

    cat > "${CREDENTIAL_FILE}" <<EOF
qBittorrent WebUI Credentials
==============================

URL: http://${PUBLIC_IP}:${WEBUI_PORT}
Username: ${QBT_USERNAME}
Password: ${QBT_PASSWORD}

Deployment: Docker Compose
Container: ${QBT_CONTAINER}
Image: ${QBT_IMAGE}
EOF

    chmod 0600 "${CREDENTIAL_FILE}"
}

write_environment_file() {
    cat > "${ENV_FILE}" <<EOF
QBT_IMAGE=${QBT_IMAGE}
NGINX_IMAGE=${NGINX_IMAGE}
CERTBOT_IMAGE=${CERTBOT_IMAGE}

QBT_CONFIG_DIR=${QBT_CONFIG_DIR}
DOWNLOAD_DIR=${DOWNLOAD_DIR}
INCOMPLETE_DIR=${INCOMPLETE_DIR}
LETSENCRYPT_DIR=${LETSENCRYPT_DIR}
ACME_DIR=${ACME_DIR}
NGINX_CONF_DIR=${NGINX_CONF_DIR}
NGINX_ENTRYPOINT_DIR=${NGINX_ENTRYPOINT_DIR}

WEBUI_BIND=${WEBUI_BIND}
WEBUI_PORT=${WEBUI_PORT}
TORRENT_PORT=${TORRENT_PORT}
TIMEZONE=${TIMEZONE}
EOF

    chmod 0600 "${ENV_FILE}"
}

write_compose_file() {
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
      PUID: "1000"
      PGID: "1000"
      UMASK: "022"
    ports:
      - "${WEBUI_BIND}:${WEBUI_PORT}:${WEBUI_PORT}/tcp"
      - "0.0.0.0:${TORRENT_PORT}:${TORRENT_PORT}/tcp"
      - "0.0.0.0:${TORRENT_PORT}:${TORRENT_PORT}/udp"
    volumes:
      - "${QBT_CONFIG_DIR}:/config"
      - "${DOWNLOAD_DIR}:/downloads"
      - "${INCOMPLETE_DIR}:/incomplete"
      # Preserve resumed torrents migrated from the former native setup.
      - "${DOWNLOAD_DIR}:${DOWNLOAD_DIR}"
      - "${INCOMPLETE_DIR}:${INCOMPLETE_DIR}"

  nginx:
    image: ${NGINX_IMAGE}
    container_name: ttdd-nginx
    restart: unless-stopped
    environment:
      CERT_RELOAD_INTERVAL: "60"
    ports:
      - "0.0.0.0:80:80/tcp"
      - "0.0.0.0:443:443/tcp"
    volumes:
      - "${DOWNLOAD_DIR}:/downloads:ro"
      - "${LETSENCRYPT_DIR}:/etc/letsencrypt:ro"
      - "${ACME_DIR}:/var/www/certbot"
      - "${NGINX_CONF_DIR}:/etc/nginx/conf.d:ro"
      - "${NGINX_ENTRYPOINT_DIR}:/docker-entrypoint.d:ro"

  certbot:
    image: ${CERTBOT_IMAGE}
    profiles:
      - tools
    volumes:
      - "${LETSENCRYPT_DIR}:/etc/letsencrypt"
      - "${ACME_DIR}:/var/www/certbot"

  certbot-renew:
    image: ${CERTBOT_IMAGE}
    container_name: ttdd-certbot-renew
    restart: unless-stopped
    entrypoint:
      - /bin/sh
      - -c
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
}

write_nginx_reload_script() {
    cat > "${NGINX_ENTRYPOINT_DIR}/99-cert-reload.sh" <<'SH'
#!/bin/sh
set -eu

interval="${CERT_RELOAD_INTERVAL:-60}"

(
    while :; do
        sleep "${interval}"

        if [ -f /var/www/certbot/.reload-nginx ]; then
            if nginx -t; then
                nginx -s reload
                rm -f /var/www/certbot/.reload-nginx
            fi
        fi
    done
) &
SH

    chmod 0755 "${NGINX_ENTRYPOINT_DIR}/99-cert-reload.sh"
}

write_nginx_http_config() {
    cat > "${NGINX_CONF_DIR}/default.conf" <<'NGINX'
server {
    listen 80 default_server;
    server_name _;

    root /downloads;
    charset utf-8;

    server_tokens off;
    sendfile on;
    tcp_nopush on;

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
        limit_except GET HEAD {
            deny all;
        }

        try_files $uri $uri/ =404;
    }

    location ~ /\. {
        deny all;
    }

    add_header X-Content-Type-Options "nosniff" always;
}
NGINX
}

write_nginx_https_config() {
    cat > "${NGINX_CONF_DIR}/default.conf" <<EOF
server {
    listen 80 default_server;
    server_name _;

    root /downloads;
    charset utf-8;

    server_tokens off;
    sendfile on;
    tcp_nopush on;

    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
        allow all;
        try_files \$uri =404;
    }

    location / {
        limit_except GET HEAD {
            deny all;
        }

        try_files \$uri \$uri/ =404;
    }

    location ~ /\. {
        deny all;
    }

    add_header X-Content-Type-Options "nosniff" always;
}

server {
    listen 443 ssl default_server;
    server_name ${PUBLIC_IP};

    root /downloads;
    charset utf-8;

    server_tokens off;
    sendfile on;
    tcp_nopush on;

    ssl_certificate /etc/letsencrypt/live/${CERT_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CERT_NAME}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:TTDD_SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;

    location / {
        limit_except GET HEAD {
            deny all;
        }

        try_files \$uri \$uri/ =404;
    }

    location ~ /\. {
        deny all;
    }

    add_header X-Content-Type-Options "nosniff" always;
}
EOF
}

validate_generated_files() {
    log "Validating the generated shell, Compose, and Nginx configuration."

    bash -n "$0"

    python3 - "${COMPOSE_FILE}" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    raise SystemExit("PyYAML is unavailable")

path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text())

required = {"qbittorrent", "nginx", "certbot", "certbot-renew"}
services = set(data.get("services", {}))
missing = required - services
if missing:
    raise SystemExit(f"Missing Compose services: {sorted(missing)}")
PY

    docker compose \
        --project-name "${STACK_NAME}" \
        --env-file "${ENV_FILE}" \
        --file "${COMPOSE_FILE}" \
        config --quiet

    compose --profile tools pull

    local certbot_version=""
    certbot_version="$(
        compose --profile tools run --rm certbot --version \
            | grep -oE '[0-9]+(\.[0-9]+){1,3}' \
            | head -n 1
    )"

    dpkg --compare-versions "${certbot_version}" ge "5.4" \
        || die "Certbot ${certbot_version} is too old; 5.4 or newer is required for IP certificates."

    printf 'Certbot version: %s\n' "${certbot_version}"
}

start_http_stack() {
    log "Starting qBittorrent and the HTTP-only Nginx container."

    compose up -d qbittorrent nginx

    local attempt
    for attempt in $(seq 1 90); do
        if curl -fsS --max-time 2 \
            "http://127.0.0.1:${WEBUI_PORT}/" \
            >/dev/null 2>&1; then
            break
        fi

        sleep 1
    done

    curl -fsS --max-time 5 \
        "http://127.0.0.1:${WEBUI_PORT}/" \
        >/dev/null \
        || die "qBittorrent WebUI did not become available."

    printf 'acme-ok\n' > "${ACME_DIR}/.well-known/acme-challenge/installer-test"

    [[ "$(
        curl -fsS --max-time 5 \
            -H "Host: ${PUBLIC_IP}" \
            "http://127.0.0.1/.well-known/acme-challenge/installer-test"
    )" == "acme-ok" ]] \
        || die "Nginx ACME webroot test failed."

    rm -f "${ACME_DIR}/.well-known/acme-challenge/installer-test"
}

verify_qbittorrent_authentication() {
    log "Testing qBittorrent with both an incorrect and the configured password."

    local wrong_password=""
    local wrong_cookie=""
    local correct_cookie=""
    local wrong_version_code=""
    local correct_version_code=""
    local version_body=""

    wrong_password="$(openssl rand -hex 20)"
    wrong_cookie="$(mktemp)"
    correct_cookie="$(mktemp)"

    curl -sS \
        --cookie-jar "${wrong_cookie}" \
        -H "Referer: http://127.0.0.1:${WEBUI_PORT}" \
        -H "Origin: http://127.0.0.1:${WEBUI_PORT}" \
        --data-urlencode "username=${QBT_USERNAME}" \
        --data-urlencode "password=${wrong_password}" \
        "http://127.0.0.1:${WEBUI_PORT}/api/v2/auth/login" \
        >/dev/null || true

    wrong_version_code="$(
        curl -sS \
            --output /dev/null \
            --write-out '%{http_code}' \
            --cookie "${wrong_cookie}" \
            "http://127.0.0.1:${WEBUI_PORT}/api/v2/app/version" \
            || true
    )"

    rm -f "${wrong_cookie}"

    [[ "${wrong_version_code}" != "200" ]] \
        || die "qBittorrent accepted an invalid password or authentication bypass is enabled."

    curl -sS \
        --cookie-jar "${correct_cookie}" \
        -H "Referer: http://127.0.0.1:${WEBUI_PORT}" \
        -H "Origin: http://127.0.0.1:${WEBUI_PORT}" \
        --data-urlencode "username=${QBT_USERNAME}" \
        --data-urlencode "password=${QBT_PASSWORD}" \
        "http://127.0.0.1:${WEBUI_PORT}/api/v2/auth/login" \
        >/dev/null

    version_body="$(mktemp)"

    correct_version_code="$(
        curl -sS \
            --output "${version_body}" \
            --write-out '%{http_code}' \
            --cookie "${correct_cookie}" \
            "http://127.0.0.1:${WEBUI_PORT}/api/v2/app/version"
    )"

    rm -f "${correct_cookie}"

    [[ "${correct_version_code}" == "200" ]] \
        || {
            cat "${version_body}" >&2 || true
            rm -f "${version_body}"
            die "qBittorrent rejected the configured permanent password."
        }

    grep -Eq '^v?[0-9]+\.[0-9]+' "${version_body}" \
        || {
            cat "${version_body}" >&2 || true
            rm -f "${version_body}"
            die "qBittorrent returned an unexpected application version."
        }

    printf 'Authenticated qBittorrent version: %s\n' \
        "$(cat "${version_body}")"

    rm -f "${version_body}"
}

obtain_certificate() {
    log "Obtaining or reusing a trusted Let's Encrypt certificate for ${PUBLIC_IP}."

    local args=(
        certonly
        --non-interactive
        --agree-tos
        --preferred-profile
        shortlived
        --webroot
        --webroot-path
        /var/www/certbot
        --ip-address
        "${PUBLIC_IP}"
        --cert-name
        "${CERT_NAME}"
        --keep-until-expiring
    )

    if [[ -n "${LETSENCRYPT_EMAIL}" ]]; then
        args+=(--email "${LETSENCRYPT_EMAIL}")
    else
        args+=(--register-unsafely-without-email)
    fi

    if [[ "${LETSENCRYPT_STAGING}" == "1" ]]; then
        args+=(--staging)
    fi

    compose --profile tools run --rm certbot "${args[@]}"

    [[ -s "${CERT_FULLCHAIN}" && -s "${CERT_PRIVATE_KEY}" ]] \
        || die "Certbot completed without creating the expected certificate files."

    openssl x509 \
        -in "${CERT_CERT}" \
        -noout \
        -ext subjectAltName \
        | grep -Fq "IP Address:${PUBLIC_IP}" \
        || die "The issued certificate does not contain ${PUBLIC_IP} in its SAN."

    openssl x509 \
        -in "${CERT_CERT}" \
        -noout \
        -checkend 3600 \
        || die "The issued certificate is not currently valid."

    if [[ "${LETSENCRYPT_STAGING}" == "0" ]]; then
        openssl verify \
            -CAfile /etc/ssl/certs/ca-certificates.crt \
            -untrusted "${CERT_CHAIN}" \
            "${CERT_CERT}"
    fi
}

enable_https_and_renewal() {
    log "Enabling HTTPS and the Certbot renewal container."

    write_nginx_https_config

    compose exec -T nginx nginx -t
    compose restart nginx

    local attempt
    for attempt in $(seq 1 60); do
        if [[ "${LETSENCRYPT_STAGING}" == "1" ]]; then
            if curl -kfsS --max-time 3 \
                --resolve "${PUBLIC_IP}:443:127.0.0.1" \
                "https://${PUBLIC_IP}/" \
                >/dev/null 2>&1; then
                break
            fi
        else
            if curl -fsS --max-time 3 \
                --resolve "${PUBLIC_IP}:443:127.0.0.1" \
                "https://${PUBLIC_IP}/" \
                >/dev/null 2>&1; then
                break
            fi
        fi

        sleep 1
    done

    if [[ "${LETSENCRYPT_STAGING}" == "1" ]]; then
        curl -kfsS --max-time 5 \
            --resolve "${PUBLIC_IP}:443:127.0.0.1" \
            "https://${PUBLIC_IP}/" \
            >/dev/null
    else
        curl -fsS --max-time 5 \
            --resolve "${PUBLIC_IP}:443:127.0.0.1" \
            "https://${PUBLIC_IP}/" \
            >/dev/null
    fi

    compose up -d certbot-renew

    if [[ "${RUN_RENEWAL_DRY_RUN}" == "1" ]]; then
        log "Running a complete Certbot renewal dry-run."
        compose --profile tools run --rm certbot \
            renew \
            --dry-run
    fi
}

verify_direct_downloads() {
    log "Testing a file download over both HTTP and HTTPS."

    local test_file="${DOWNLOAD_DIR}/ttdd-install-test.txt"
    local expected="torrent-to-direct-download-ok"

    printf '%s\n' "${expected}" > "${test_file}"
    chown 1000:1000 "${test_file}"
    chmod 0644 "${test_file}"

    [[ "$(
        curl -fsS --max-time 5 \
            -H "Host: ${PUBLIC_IP}" \
            "http://127.0.0.1/ttdd-install-test.txt"
    )" == "${expected}" ]] \
        || die "HTTP direct-download test failed."

    if [[ "${LETSENCRYPT_STAGING}" == "1" ]]; then
        [[ "$(
            curl -kfsS --max-time 5 \
                --resolve "${PUBLIC_IP}:443:127.0.0.1" \
                "https://${PUBLIC_IP}/ttdd-install-test.txt"
        )" == "${expected}" ]] \
            || die "HTTPS direct-download test failed."
    else
        [[ "$(
            curl -fsS --max-time 5 \
                --resolve "${PUBLIC_IP}:443:127.0.0.1" \
                "https://${PUBLIC_IP}/ttdd-install-test.txt"
        )" == "${expected}" ]] \
            || die "HTTPS direct-download test failed."
    fi

    rm -f "${test_file}"
}

write_information_files() {
    local not_before=""
    local not_after=""
    local fingerprint=""
    local qbt_version=""
    local nginx_version=""
    local certbot_version=""

    not_before="$(
        openssl x509 -in "${CERT_CERT}" -noout -startdate \
            | cut -d= -f2-
    )"

    not_after="$(
        openssl x509 -in "${CERT_CERT}" -noout -enddate \
            | cut -d= -f2-
    )"

    fingerprint="$(
        openssl x509 -in "${CERT_CERT}" -noout -fingerprint -sha256 \
            | cut -d= -f2-
    )"

    qbt_version="$(
        compose exec -T qbittorrent qbittorrent-nox --version \
            | tr -d '\r'
    )"

    nginx_version="$(
        compose exec -T nginx nginx -v 2>&1 \
            | tr -d '\r'
    )"

    certbot_version="$(
        compose --profile tools run --rm certbot --version \
            | tr -d '\r'
    )"

    cat > "${DOWNLOAD_INFO_FILE}" <<EOF
Direct Download Information
===========================

HTTP:  http://${PUBLIC_IP}/
HTTPS: https://${PUBLIC_IP}/

Published directory:
${DOWNLOAD_DIR}

Authentication:
None
EOF

    cat > "${SSL_INFO_FILE}" <<EOF
Let's Encrypt IP Certificate
============================

IP: ${PUBLIC_IP}
Certificate name: ${CERT_NAME}
Not before: ${not_before}
Not after: ${not_after}
SHA-256 fingerprint: ${fingerprint}

Certificate directory:
${CERT_LIVE_DIR}

Renewal container:
${CERTBOT_RENEW_CONTAINER}
EOF

    chmod 0600 \
        "${DOWNLOAD_INFO_FILE}" \
        "${SSL_INFO_FILE}"

    printf '\nRuntime versions:\n'
    printf '  %s\n' "${qbt_version}"
    printf '  %s\n' "${nginx_version}"
    printf '  %s\n' "${certbot_version}"
}

print_summary() {
    printf '\n============================================================\n'
    printf 'Installation completed and all verification checks passed.\n'
    printf 'Installer version: %s\n' "${SCRIPT_VERSION}"
    printf '============================================================\n\n'

    printf 'qBittorrent WebUI:\n'
    printf '  URL:      http://%s:%s\n' "${PUBLIC_IP}" "${WEBUI_PORT}"
    printf '  Username: %s\n' "${QBT_USERNAME}"
    printf '  Password: %s\n\n' "${QBT_PASSWORD}"

    printf 'Direct downloads:\n'
    printf '  HTTP:  http://%s/\n' "${PUBLIC_IP}"
    printf '  HTTPS: https://%s/\n\n' "${PUBLIC_IP}"

    printf 'Persistent data:\n'
    printf '  Config:     %s\n' "${QBT_CONFIG_DIR}"
    printf '  Downloads:  %s\n' "${DOWNLOAD_DIR}"
    printf '  Incomplete: %s\n\n' "${INCOMPLETE_DIR}"

    printf 'Compose stack:\n'
    printf '  Directory: %s\n' "${STACK_DIR}"
    printf '  Status:    cd %s && docker compose ps\n\n' "${STACK_DIR}"

    printf 'Saved information:\n'
    printf '  %s\n' "${CREDENTIAL_FILE}"
    printf '  %s\n' "${DOWNLOAD_INFO_FILE}"
    printf '  %s\n' "${SSL_INFO_FILE}"

    printf '\nSecurity warning:\n'
    printf '  Files on ports 80 and 443 are public and have no password.\n'
}

main() {
    require_root
    require_ubuntu

    validate_port "${WEBUI_PORT}" "WEBUI_PORT"
    validate_port "${TORRENT_PORT}" "TORRENT_PORT"
    validate_boolean "${RESET_QBT_PASSWORD}" "RESET_QBT_PASSWORD"
    validate_boolean "${LETSENCRYPT_STAGING}" "LETSENCRYPT_STAGING"
    validate_boolean "${RUN_RENEWAL_DRY_RUN}" "RUN_RENEWAL_DRY_RUN"

    [[ "${WEBUI_PORT}" != "80" && "${WEBUI_PORT}" != "443" ]] \
        || die "WEBUI_PORT cannot be 80 or 443."

    [[ "${TORRENT_PORT}" != "80" && "${TORRENT_PORT}" != "443" ]] \
        || die "TORRENT_PORT cannot be 80 or 443."

    [[ "${WEBUI_PORT}" != "${TORRENT_PORT}" ]] \
        || die "WEBUI_PORT and TORRENT_PORT must be different."

    rm -f "${STATE_FILE}" 2>/dev/null || true

    install_base_packages
    install_official_docker_if_needed
    detect_public_ip
    initialize_certificate_paths

    stop_previous_native_services
    stop_previous_containers

    check_port_is_free 80 "Docker Nginx"
    check_port_is_free 443 "Docker Nginx"
    check_port_is_free "${WEBUI_PORT}" "qBittorrent WebUI"
    check_port_is_free "${TORRENT_PORT}" "qBittorrent torrent traffic"
    check_udp_port_is_free "${TORRENT_PORT}" "qBittorrent torrent traffic"

    configure_ufw_if_active
    prepare_directories
    migrate_previous_data
    configure_qbittorrent_offline

    write_environment_file
    write_compose_file
    write_nginx_reload_script
    write_nginx_http_config

    validate_generated_files
    start_http_stack
    verify_qbittorrent_authentication
    obtain_certificate
    enable_https_and_renewal
    verify_direct_downloads
    write_information_files

    compose ps
    install -m 0600 /dev/null "${STATE_FILE}"
    printf 'installer_version=%s\ncompleted_at=%s\n' \
        "${SCRIPT_VERSION}" "$(date --iso-8601=seconds)" \
        > "${STATE_FILE}"
    INSTALL_COMPLETE=1
    print_summary
}

if [[ "${TTDD_SOURCE_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
