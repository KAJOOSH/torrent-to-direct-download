# Review Notes — Upstream 2.2.1 to 3.0.1

The upstream installer was reviewed as a complete installation flow, not only for the three reported symptoms.

## High-impact findings

1. **Password reset was not an isolated action.** `RESET_QBT_PASSWORD=1` only changed how the previous password was read; execution still continued through the normal `main()` installation pipeline. That meant package operations, container teardown/recreation, config regeneration, Certbot, Nginx, and verification could all run during what should have been a small credential change.

2. **SSL was mandatory and expensive.** Certbot/Nginx HTTPS services were always generated and the normal path always requested/reused a certificate and enabled renewal. The default `RUN_RENEWAL_DRY_RUN=1` also launched a complete Certbot renewal dry-run after installation.

3. **The disk-space symptom is primarily a qBittorrent v5 trash behavior, not an Nginx copy.** qBittorrent v5 can move content to a hidden `.Trash-*` directory when the user removes a torrent and chooses to remove its content. On a headless server this looks like deletion in WebUI while the bytes remain on disk. Nginx serves the download directory through a read-only bind mount, so that mount itself is not another physical copy.

4. **Large recursive permission operations were unsafe/slow.** The old installer recursively ran ownership and permission changes across config, completed downloads, and incomplete downloads every time. On large stores this can take a long time and creates unnecessary I/O.

5. **Mount layout was unnecessarily complex.** The old qBittorrent service mounted completed/incomplete directories both as `/downloads`/`/incomplete` and again at their absolute host paths for compatibility. This does not itself duplicate data, but it makes path behavior harder to reason about. v3 uses one `/data` root for new paths and retains only compatibility aliases needed by old resume data.

6. **Host Nginx handling was too invasive.** The old flow could disable an active host Nginx service. v3 refuses to stop an unrelated Nginx and only migrates a legacy Nginx when its configuration clearly references this project's old paths.

7. **Installation repeated avoidable work.** Host package update/install and SSL preparation were part of every main run. v3 installs only missing packages and avoids all SSL work when SSL is disabled.

## Storage behavior in v3

New qBittorrent defaults are:

```ini
[BitTorrent]
Session\DefaultSavePath=/data/downloads
Session\TempPath=/data/incomplete
Session\TempPathEnabled=true
Session\TorrentContentRemoveOption=Delete
```

The qBittorrent container gets `/srv/qbittorrent` mounted at `/data`. Nginx gets `/srv/qbittorrent/downloads` mounted read-only at `/downloads`. Therefore Nginx reads the same host file and does not maintain a second copy.

Old hidden trash is intentionally not erased automatically during an upgrade. Inspect it first:

```bash
sudo bash install.sh --disk-check
```

Then remove it permanently if it is the data you already intended to delete:

```bash
sudo bash install.sh --purge-trash
```


## Nginx direct-download performance review — v3.0.1

The v3.0.0 site configuration did not contain `limit_rate`, `limit_conn`, or `limit_req`, so it did not intentionally throttle download bandwidth. However, it still relied on the official image main `nginx.conf` and process limits. Under high concurrency, the default worker/file-descriptor ceilings can become the first artificial bottleneck before disk or network capacity is reached.

v3.0.1 therefore owns the main Nginx configuration and explicitly raises capacity while avoiding per-client throttles:

```nginx
worker_processes auto;
worker_rlimit_nofile 262144;

events {
    worker_connections 65535;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    limit_rate 0;
    access_log off;
}
```

The Nginx container also receives a Docker `nofile` soft/hard limit of `262144`, `net.core.somaxconn=65535`, and `listen ... reuseport backlog=65535`. No `limit_conn` or `limit_req` zone/directive is generated. Byte-range support remains enabled for segmented download managers.

`open_file_cache` is intentionally not enabled in this performance profile: caching open descriptors can delay final disk-space release after a file is unlinked, which conflicts with the project's storage/deletion goals.

The large numerical limits are ceilings, not guaranteed sustainable throughput. The effective limit remains the NIC, disk/filesystem, CPU/TLS cost, kernel/network path, Docker networking, and the remote client.
