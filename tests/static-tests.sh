#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

bash -n "${SCRIPT}"
"${SCRIPT}" --help >/dev/null

# HTTP Compose + high-throughput Nginx generation.
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/http-stack" DATA_DIR="${TMP}/http-data" PUBLIC_IP=8.8.8.8 ENABLE_SSL=0 \
bash -c 'set --; source "$SCRIPT"; mkdir -p "$STACK_DIR" "$NGINX_CONF_DIR" "$NGINX_ENTRYPOINT_DIR" "$QBT_CONFIG_DIR/qBittorrent/config" "$QBT_DATA_DIR" "$DOWNLOAD_DIR" "$INCOMPLETE_DIR"; write_environment_file; write_compose_file; write_nginx_main_config; write_nginx_http_config; python3 - "$COMPOSE_FILE" "$NGINX_MAIN_CONF" "$NGINX_CONF_DIR/default.conf" <<"PY"
import yaml,sys
compose,main,site=sys.argv[1:]
x=yaml.safe_load(open(compose))
assert set(x["services"]) == {"qbittorrent","nginx"}
ng=x["services"]["nginx"]
assert ng["ports"] == ["0.0.0.0:80:80/tcp"]
assert ng["ulimits"]["nofile"]["soft"] == 262144
assert ng["ulimits"]["nofile"]["hard"] == 262144
assert str(ng["sysctls"]["net.core.somaxconn"]) == "65535"
mc=open(main).read()
sc=open(site).read()
assert "worker_processes auto;" in mc
assert "worker_connections 65535;" in mc
assert "worker_rlimit_nofile 262144;" in mc
assert "multi_accept on;" in mc
assert "sendfile on;" in mc
assert "tcp_nopush on;" in mc
assert "tcp_nodelay on;" in mc
assert "limit_rate 0;" in mc
assert "access_log off;" in mc
assert "limit_conn" not in mc and "limit_req" not in mc
assert "reuseport backlog=65535" in sc
assert "limit_rate 0;" in sc
assert "limit_conn" not in sc and "limit_req" not in sc
PY'

# HTTPS Compose generation uses the same high-throughput profile.
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/ssl-stack" DATA_DIR="${TMP}/ssl-data" PUBLIC_IP=8.8.8.8 ENABLE_SSL=1 \
bash -c 'set --; source "$SCRIPT"; mkdir -p "$STACK_DIR" "$NGINX_CONF_DIR" "$NGINX_ENTRYPOINT_DIR" "$QBT_CONFIG_DIR/qBittorrent/config" "$QBT_DATA_DIR" "$DOWNLOAD_DIR" "$INCOMPLETE_DIR" "$LETSENCRYPT_DIR" "$ACME_DIR/.well-known/acme-challenge"; CERT_NAME=8.8.8.8; write_environment_file; write_compose_file; write_nginx_main_config; write_nginx_https_config; python3 - "$COMPOSE_FILE" "$NGINX_CONF_DIR/default.conf" <<"PY"
import yaml,sys
x=yaml.safe_load(open(sys.argv[1]))
assert set(x["services"]) == {"qbittorrent","nginx","certbot","certbot-renew"}
ng=x["services"]["nginx"]
assert len(ng["ports"]) == 2
assert len(ng["volumes"]) == 6
assert ng["ulimits"]["nofile"]["hard"] == 262144
sc=open(sys.argv[2]).read()
assert "listen 443 ssl default_server reuseport backlog=65535;" in sc
assert sc.count("limit_rate 0;") >= 2
PY'

# Full qBittorrent config must enforce permanent deletion and same-root paths.
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/qbt-stack" DATA_DIR="${TMP}/qbt-data" PUBLIC_IP=8.8.8.8 ENABLE_SSL=0 \
QBT_PASSWORD='StaticTestPassword-123456' CREDENTIAL_FILE="${TMP}/creds.txt" \
bash -c 'set --; source "$SCRIPT"; mkdir -p "$STACK_DIR" "$QBT_CONFIG_DIR/qBittorrent/config" "$DOWNLOAD_DIR" "$INCOMPLETE_DIR"; configure_qbittorrent_offline full; grep -Fq "Session\\TorrentContentRemoveOption=Delete" "$QBT_CONFIG_FILE"; grep -Fq "Session\\DefaultSavePath=/data/downloads" "$QBT_CONFIG_FILE"; grep -Fq "Session\\TempPath=/data/incomplete" "$QBT_CONFIG_FILE"'

# Password-only mode must not rewrite storage behavior.
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/reset-stack" DATA_DIR="${TMP}/reset-data" PUBLIC_IP=8.8.8.8 ENABLE_SSL=0 \
QBT_PASSWORD='StaticResetPassword-123456' CREDENTIAL_FILE="${TMP}/reset-creds.txt" \
bash -c 'set --; source "$SCRIPT"; mkdir -p "$STACK_DIR" "$QBT_CONFIG_DIR/qBittorrent/config" "$DOWNLOAD_DIR" "$INCOMPLETE_DIR"; printf "%s\n" "[BitTorrent]" "Session\\DefaultSavePath=/legacy/custom" > "$QBT_CONFIG_FILE"; configure_qbittorrent_offline password; grep -Fq "Session\\DefaultSavePath=/legacy/custom" "$QBT_CONFIG_FILE"; ! grep -Fq "TorrentContentRemoveOption" "$QBT_CONFIG_FILE"'

# Previous .env values load, but explicit caller values win; main Nginx config path persists too.
mkdir -p "${TMP}/env-stack"
cat > "${TMP}/env-stack/.env" <<ENV
DATA_DIR=${TMP}/persisted-data
PUBLIC_IP=1.1.1.1
ENABLE_SSL=1
WEBUI_PORT=8181
NGINX_MAIN_CONF=${TMP}/custom-nginx.conf
ENV
TTDD_SOURCE_ONLY=1 SCRIPT="${SCRIPT}" STACK_DIR="${TMP}/env-stack" WEBUI_PORT=8282 \
bash -c 'set --; source "$SCRIPT"; [[ "$DATA_DIR" == *persisted-data ]]; [[ "$PUBLIC_IP" == 1.1.1.1 ]]; [[ "$ENABLE_SSL" == 1 ]]; [[ "$WEBUI_PORT" == 8282 ]]; [[ "$NGINX_MAIN_CONF" == *custom-nginx.conf ]]'

printf 'All static tests passed for v3.0.1.\n'
