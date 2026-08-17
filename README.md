# Torrent to Direct Download — v3.0.2

Ubuntu installer for **qBittorrent + Nginx**, with optional Let's Encrypt IP SSL and a high-throughput direct-download profile.

This branch is a safety, storage and performance rewrite of upstream 2.2.1. Existing data under `/srv/qbittorrent` is preserved.

## What v3 fixes

- Password reset no longer reinstalls or rebuilds the whole system.
- SSL/HTTPS is optional and is decided before the expensive installation steps.
- Slow Certbot renewal dry-run is disabled by default.
- qBittorrent file deletion is configured for permanent deletion instead of hidden `.Trash-*` retention.
- Nginx reads the real completed-download directory through a read-only bind mount; it does **not** keep a second copy.
- Complete/incomplete downloads live below one primary `/data` mount to avoid cross-mount copy behavior.
- Nginx direct downloads use an explicit high-throughput/no-rate-limit profile in v3.0.2.

## Install / update

> **All management commands in this README run directly from the official Raw `main` installer**, so you do not need to download `install.sh` or clone the repository first. The URL used throughout is:
>
> `https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh`


```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash
```

On the first install, the first important question is whether SSL/HTTPS should be enabled. Choose **No** for a faster HTTP-only setup or **Yes** to configure Let's Encrypt IP SSL.

Non-interactive choices:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --disable-ssl
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --enable-ssl
```

Running the newer installer again is the supported update path. Existing downloads, qBittorrent resume data and configuration are preserved/backed up before mutation.

## High-speed direct downloads — v3.0.2

The generated Nginx configuration intentionally contains **no per-IP connection limit, no request-rate limit and no response bandwidth limit**.

Performance/capacity defaults:

- `worker_processes auto`
- `worker_connections 65535` per worker
- `worker_rlimit_nofile 262144`
- Docker `nofile` soft/hard limit: `262144`
- container `net.core.somaxconn=65535`
- `listen ... reuseport backlog=65535`
- `limit_rate 0`
- `sendfile on`
- `tcp_nopush on`
- `tcp_nodelay on`
- `multi_accept on`
- Nginx access log disabled to avoid unnecessary disk I/O during high-volume file serving
- byte-range downloads remain enabled, so IDM/aria2/other download managers can use parallel range requests/connections

There is no artificial Nginx speed cap. Actual throughput is therefore bounded by the server NIC, route/ISP, disk/filesystem throughput, CPU/TLS cost, Docker/host networking, and the client side.

The high numeric connection limits are capacity ceilings, not a promise that every server can sustain that many active file transfers. They avoid the small default ceilings while leaving the Linux kernel and available hardware as the practical limit.

Inspect the effective Nginx configuration after installation:

```bash
sudo docker exec ttdd-nginx nginx -T
```

Check the important limits:

```bash
sudo docker exec ttdd-nginx sh -c 'ulimit -n; nginx -T 2>&1 | grep -E "worker_connections|worker_rlimit_nofile|limit_rate|reuseport|sendfile|multi_accept"'
```

## Password reset — no reinstall

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --reset-password
```

To choose the new password yourself:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo env QBT_PASSWORD='your-strong-password' bash -s -- --reset-password
```

The reset path does not run apt, pull images, reinstall Docker, rewrite Nginx/SSL, or touch downloaded content.

The legacy form is also accepted:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo env RESET_QBT_PASSWORD=1 bash
```

## Disk-space diagnosis and old qBittorrent trash

Check where space is being used:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --disk-check
```

If old `.Trash-*` data is shown and it contains files you already intended to delete:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --purge-trash
```

Future qBittorrent deletes are configured for permanent removal with `Session\TorrentContentRemoveOption=Delete` when **also delete files** is selected.

## Why Nginx does not double disk usage

Nginx receives `/srv/qbittorrent/downloads` as a **read-only bind mount**. A bind mount exposes the same host files inside the Nginx container; it is not another storage copy.

New qBittorrent paths are:

```text
/data/downloads
/data/incomplete
```

Legacy `/downloads` and `/incomplete` mounts remain only as compatibility aliases for old resume data. They point to the same host directories.

## SSL behavior

A full Certbot renewal dry-run is no longer performed on every installation. It is opt-in:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo env RUN_RENEWAL_DRY_RUN=1 bash -s -- --enable-ssl
```

A still-valid existing certificate is reused. SSL-disabled installations do not create Certbot renewal services or expose port 443.

## Paths

- Persistent root: `/srv/qbittorrent`
- qBittorrent config: `/srv/qbittorrent/config`
- Completed downloads: `/srv/qbittorrent/downloads`
- Incomplete downloads: `/srv/qbittorrent/incomplete`
- Stack: `/opt/torrent-to-direct-download`
- Generated Nginx main config: `/opt/torrent-to-direct-download/nginx/nginx.conf`
- Generated Nginx site config: `/opt/torrent-to-direct-download/nginx/conf.d/default.conf`
- Credentials: `/root/qbittorrent-credentials.txt`
- Error report: `/root/torrent-to-direct-download-error.log`

## Status / diagnostics

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --status
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --disk-check
```

## Tests

```bash
sudo bash tests/static-tests.sh
```

The static suite validates Bash syntax, HTTP/HTTPS Compose generation, the high-throughput Nginx profile, raised `nofile`/backlog settings, absence of Nginx rate/connection limiting directives, qBittorrent permanent-delete behavior, password-only reset behavior, and persisted environment loading.

Real certificate issuance and a real internet throughput benchmark are intentionally not performed by the static test suite.

See `CHANGELOG.md`, `REVIEW.md`, and `TEST-RESULTS.md` for more detail.
