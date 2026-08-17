# Test Results — v3.0.1

Date: 2026-08-17

Passed checks:

- `bash -n install.sh`
- `install.sh --help`
- HTTP-only Compose YAML generation and parse
- HTTPS/Certbot Compose YAML generation and parse
- Generated main Nginx performance config exists and is mounted into the container
- `worker_processes auto`
- `worker_connections 65535`
- `worker_rlimit_nofile 262144`
- Docker Nginx `nofile` soft/hard = `262144`
- Nginx container `net.core.somaxconn=65535`
- `listen ... reuseport backlog=65535`
- `sendfile on`, `tcp_nopush on`, `tcp_nodelay on`, `multi_accept on`
- `limit_rate 0`
- No generated `limit_conn` or `limit_req` directives
- Nginx access logging disabled for high-volume direct-download traffic
- HTTP Nginx configuration syntax test succeeded with local Nginx 1.26.3 after adapting only the image-specific `user nginx` and include path for the build host
- qBittorrent full-mode config generation
- Permanent-delete key: `Session\TorrentContentRemoveOption=Delete`
- Same-root v3 paths: `/data/downloads` and `/data/incomplete`
- Password-only config mutation preserves existing storage path and does not inject full-install storage settings
- Persisted `.env` values load correctly, including `NGINX_MAIN_CONF`
- Explicit environment overrides take priority over persisted `.env`

Not executed in the build environment:

- A live production Ubuntu Docker deployment
- A real public Let's Encrypt IP-certificate issuance/renewal
- Real BitTorrent traffic
- A real multi-gigabyte delete test
- A real WAN/NIC saturation benchmark with IDM/aria2 parallel ranges

The installer performs Compose/Nginx/qBittorrent runtime verification when run on the target Ubuntu server.
