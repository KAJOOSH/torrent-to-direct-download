# Changelog

## 3.0.2 — 2026-08-17

Documentation / copy-paste command release.

### Changed
- Updated both Persian and English READMEs so installation and all installer management actions run directly from the official Raw `main` URL.
- Standardized the exact installer URL as `https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh`.
- Added ready-to-copy commands for install/update, SSL enable/disable, password reset, disk check, trash purge, status, and Certbot renewal dry-run.
- No runtime behavior or Nginx/qBittorrent configuration was changed from v3.0.1.

## 3.0.1 — 2026-08-17

High-throughput direct-download release.

### Changed
- Added a generated main `nginx.conf` dedicated to high-volume static file serving.
- Raised Nginx connection capacity to `worker_connections 65535` per automatic worker.
- Raised Nginx/Docker open-file ceilings to `262144` (`worker_rlimit_nofile` + Compose `ulimits`).
- Raised the container accept queue with `net.core.somaxconn=65535` and `listen ... reuseport backlog=65535`.
- Explicitly set `limit_rate 0`; no `limit_conn` or `limit_req` is generated.
- Enabled `sendfile`, `tcp_nopush`, `tcp_nodelay`, and `multi_accept` for the static-download workload.
- Disabled Nginx access logging by default to remove high-volume log-write I/O; warn/error logging remains enabled.
- Persisted and mounted the generated `NGINX_MAIN_CONF` so standalone Compose runs use the same performance profile after reboot.
- Updated English/Persian READMEs with performance behavior, verification commands, and practical bottleneck notes.
- Extended static tests to verify the new Nginx capacity settings and absence of rate/connection limiting directives.

## 3.0.0 — 2026-08-17

Major safety and storage release based on upstream 2.2.1.

### Fixed
- Password reset is now a dedicated `--reset-password` action. It only stops qBittorrent, updates the WebUI password offline, starts qBittorrent again, and verifies authentication. It does not run apt, reinstall Docker, pull images, rewrite Nginx/SSL, or delete data.
- SSL is optional. On the first normal installation the script asks about SSL before package updates, image pulls, Certbot, firewall changes, or service changes. `--enable-ssl` and `--disable-ssl` are also available.
- The slow Certbot renewal dry-run is disabled by default (`RUN_RENEWAL_DRY_RUN=0`) and is now opt-in.
- Existing valid IP certificates are reused. If the Certbot image is already present, a normal reinstall with a reusable certificate skips the Certbot pull too.
- qBittorrent is configured with `Session\TorrentContentRemoveOption=Delete` so selecting “also delete files” permanently removes torrent content rather than moving it into hidden `.Trash-*` directories.
- New complete and incomplete paths use `/data/downloads` and `/data/incomplete`, both below one primary bind mount. This avoids cross-mount copy behavior during incomplete-to-complete moves.
- Legacy `/downloads` and `/incomplete` aliases remain available for existing torrent resume data. They are bind aliases to the same host directories and do not create duplicate file copies.
- Removed recursive ownership/permission changes over the potentially huge download tree. Password reset no longer walks downloaded files at all.
- Added APT/dpkg lock waiting to avoid failing immediately while unattended upgrades or another apt process holds a lock.
- Host packages are installed only when missing instead of running a full package install on every invocation.
- Host Nginx handling is conservative: an unrelated active Nginx is never disabled automatically.
- Port 443, Certbot services, ACME storage, renewal service, and HTTPS checks are only enabled when SSL is selected.
- Persisted `.env` now includes the SSL state, public IP, PUID/PGID, Nginx paths, and all paths needed by standalone Compose commands after reboot.
- Previous Compose/`.env`/Nginx metadata is backed up under the stack `backups/` directory before an update overwrites generated files.

### Added
- `--disk-check`: reports filesystem usage, download/incomplete size, hidden qBittorrent trash, deleted-but-open files, Docker disk usage, and current bind mounts.
- `--purge-trash`: displays old `.Trash-*` usage and permanently removes it only after confirmation (or with `FORCE=1`).
- `--status`: shows Compose state plus download/incomplete/trash usage.
- Static tests for HTTP/HTTPS Compose generation, persistent environment loading, permanent-delete configuration, and password-only behavior.

### Preserved
- Existing `/srv/qbittorrent` data is not deleted.
- Existing qBittorrent config/resume state is preserved and backed up before mutation.
- Existing torrent paths from v2.x remain mount-compatible.
- Running the installer again remains the update path.
