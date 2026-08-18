#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

bash -n "${SCRIPT}"
"${SCRIPT}" --help >/dev/null

# Regression: on a fresh install PUBLIC_IP is not supplied and there is no .env.
# It must still be a defined empty variable under `set -u`, then auto-detection
# must be able to populate it without an unbound-variable crash.
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/fresh-stack" \
bash -c '
  set --
  unset PUBLIC_IP || true
  source "$SCRIPT"
  [[ -v PUBLIC_IP ]]
  [[ -z "$PUBLIC_IP" ]]
  curl() { printf "8.8.8.8\n"; }
  detect_public_ip >/dev/null
  [[ "$PUBLIC_IP" == "8.8.8.8" ]]
'

# HTTP Compose + high-throughput Nginx generation.
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/http-stack" DATA_DIR="${TMP}/http-data" PUBLIC_IP=8.8.8.8 ENABLE_SSL=0 \
bash -c '
  set --
  source "$SCRIPT"
  mkdir -p "$STACK_DIR" "$NGINX_CONF_DIR" "$NGINX_ENTRYPOINT_DIR" "$QBT_CONFIG_DIR/qBittorrent/config" "$QBT_DATA_DIR" "$DOWNLOAD_DIR" "$INCOMPLETE_DIR"
  write_environment_file
  write_compose_file
  write_nginx_main_config
  write_nginx_http_config

  grep -Fq -- '\''- "0.0.0.0:80:80/tcp"'\'' "$COMPOSE_FILE"
  ! grep -Fq '\''0.0.0.0:443:443/tcp'\'' "$COMPOSE_FILE"
  ! grep -Eq '\''^  certbot(-renew)?:'\'' "$COMPOSE_FILE"
  grep -Fq '\''soft: 262144'\'' "$COMPOSE_FILE"
  grep -Fq '\''hard: 262144'\'' "$COMPOSE_FILE"
  grep -Fq '\''net.core.somaxconn: "65535"'\'' "$COMPOSE_FILE"

  grep -Fq '\''worker_processes auto;'\'' "$NGINX_MAIN_CONF"
  grep -Fq '\''worker_connections 65535;'\'' "$NGINX_MAIN_CONF"
  grep -Fq '\''worker_rlimit_nofile 262144;'\'' "$NGINX_MAIN_CONF"
  grep -Fq '\''multi_accept on;'\'' "$NGINX_MAIN_CONF"
  grep -Fq '\''sendfile on;'\'' "$NGINX_MAIN_CONF"
  grep -Fq '\''tcp_nopush on;'\'' "$NGINX_MAIN_CONF"
  grep -Fq '\''tcp_nodelay on;'\'' "$NGINX_MAIN_CONF"
  grep -Fq '\''limit_rate 0;'\'' "$NGINX_MAIN_CONF"
  grep -Fq '\''access_log off;'\'' "$NGINX_MAIN_CONF"
  ! grep -Eq '\''^[[:space:]]*limit_(conn|req)[[:space:]]'\'' "$NGINX_MAIN_CONF"

  SITE="$NGINX_CONF_DIR/default.conf"
  grep -Fq '\''reuseport backlog=65535'\'' "$SITE"
  grep -Fq '\''limit_rate 0;'\'' "$SITE"
  ! grep -Eq '\''^[[:space:]]*limit_(conn|req)[[:space:]]'\'' "$SITE"
'

# HTTPS Compose generation uses the same high-throughput profile.
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/ssl-stack" DATA_DIR="${TMP}/ssl-data" PUBLIC_IP=8.8.8.8 ENABLE_SSL=1 \
bash -c '
  set --
  source "$SCRIPT"
  mkdir -p "$STACK_DIR" "$NGINX_CONF_DIR" "$NGINX_ENTRYPOINT_DIR" "$QBT_CONFIG_DIR/qBittorrent/config" "$QBT_DATA_DIR" "$DOWNLOAD_DIR" "$INCOMPLETE_DIR" "$LETSENCRYPT_DIR" "$ACME_DIR/.well-known/acme-challenge"
  CERT_NAME=8.8.8.8
  write_environment_file
  write_compose_file
  write_nginx_main_config
  write_nginx_https_config

  grep -Fq '\''0.0.0.0:80:80/tcp'\'' "$COMPOSE_FILE"
  grep -Fq '\''0.0.0.0:443:443/tcp'\'' "$COMPOSE_FILE"
  grep -Eq '\''^  certbot:'\'' "$COMPOSE_FILE"
  grep -Eq '\''^  certbot-renew:'\'' "$COMPOSE_FILE"
  grep -Fq '\''hard: 262144'\'' "$COMPOSE_FILE"

  SITE="$NGINX_CONF_DIR/default.conf"
  grep -Fq '\''listen 443 ssl default_server reuseport backlog=65535;'\'' "$SITE"
  [[ "$(grep -Fc '\''limit_rate 0;'\'' "$SITE")" -ge 2 ]]
'

# Full qBittorrent config must enforce permanent deletion and same-root paths.
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/qbt-stack" DATA_DIR="${TMP}/qbt-data" PUBLIC_IP=8.8.8.8 ENABLE_SSL=0 \
QBT_PASSWORD='StaticTestPassword-123456' CREDENTIAL_FILE="${TMP}/creds.txt" \
bash -c '
  set --
  source "$SCRIPT"
  mkdir -p "$STACK_DIR" "$QBT_CONFIG_DIR/qBittorrent/config" "$DOWNLOAD_DIR" "$INCOMPLETE_DIR"
  configure_qbittorrent_offline full
  grep -Fq "Session\\TorrentContentRemoveOption=Delete" "$QBT_CONFIG_FILE"
  grep -Fq "Session\\DefaultSavePath=/data/downloads" "$QBT_CONFIG_FILE"
  grep -Fq "Session\\TempPath=/data/incomplete" "$QBT_CONFIG_FILE"
'

# Password-only mode must not rewrite storage behavior.
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/reset-stack" DATA_DIR="${TMP}/reset-data" PUBLIC_IP=8.8.8.8 ENABLE_SSL=0 \
QBT_PASSWORD='StaticResetPassword-123456' CREDENTIAL_FILE="${TMP}/reset-creds.txt" \
bash -c '
  set --
  source "$SCRIPT"
  mkdir -p "$STACK_DIR" "$QBT_CONFIG_DIR/qBittorrent/config" "$DOWNLOAD_DIR" "$INCOMPLETE_DIR"
  printf "%s\n" "[BitTorrent]" "Session\\DefaultSavePath=/legacy/custom" > "$QBT_CONFIG_FILE"
  configure_qbittorrent_offline password
  grep -Fq "Session\\DefaultSavePath=/legacy/custom" "$QBT_CONFIG_FILE"
  ! grep -Fq "TorrentContentRemoveOption" "$QBT_CONFIG_FILE"
'

# Previous .env values load, but explicit caller values win.
mkdir -p "${TMP}/env-stack"
cat > "${TMP}/env-stack/.env" <<ENV
DATA_DIR=${TMP}/persisted-data
PUBLIC_IP=1.1.1.1
ENABLE_SSL=1
WEBUI_PORT=8181
NGINX_MAIN_CONF=${TMP}/custom-nginx.conf
ENV
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/env-stack" WEBUI_PORT=8282 \
bash -c '
  set --
  source "$SCRIPT"
  [[ "$DATA_DIR" == *persisted-data ]]
  [[ "$PUBLIC_IP" == 1.1.1.1 ]]
  [[ "$ENABLE_SSL" == 1 ]]
  [[ "$WEBUI_PORT" == 8282 ]]
  [[ "$NGINX_MAIN_CONF" == *custom-nginx.conf ]]
'

# The installer must persist itself as a local ttdd command when executed from a file.
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/local-stack" LOCAL_INSTALLER="${TMP}/bin/ttdd" \
bash -c '
  set --
  source "$SCRIPT"
  install_local_command
  [[ -x "$LOCAL_INSTALLER" ]]
  grep -Fq '\''SCRIPT_VERSION="3.0.4"'\'' "$LOCAL_INSTALLER"
'

# Self-update validates and installs a newer remote script without an existing stack.
cat > "${TMP}/remote-installer.sh" <<'REMOTE'
#!/usr/bin/env bash
SCRIPT_VERSION="9.9.9"
STACK_NAME="torrent-to-direct-download"
# https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh
printf 'fake newer installer\n'
REMOTE
chmod 0755 "${TMP}/remote-installer.sh"
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/update-stack" LOCAL_INSTALLER="${TMP}/update-bin/ttdd" INSTALLER_URL="file://${TMP}/remote-installer.sh" \
bash -c '
  set --
  source "$SCRIPT"
  update_action >/dev/null
  [[ -x "$LOCAL_INSTALLER" ]]
  grep -Fq '\''SCRIPT_VERSION="9.9.9"'\'' "$LOCAL_INSTALLER"
'

printf 'All static tests passed for v3.0.4.\n'
