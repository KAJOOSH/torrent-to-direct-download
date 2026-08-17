# Torrent to Direct Download

Run qBittorrent behind Nginx and download completed torrents directly over HTTP or HTTPS.

[فارسی](README.fa.md)

## Features

- qBittorrent WebUI
- Direct file downloads through Nginx
- Optional Let's Encrypt HTTPS
- High-throughput Nginx configuration with no application-level download rate limit
- Persistent qBittorrent configuration and torrent resume data
- Permanent file deletion support to avoid hidden `.Trash-*` disk usage
- Safe password reset without reinstalling the stack
- Built-in status, disk check, trash cleanup and self-update commands

## Quick install

Run this once on the server:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh -o /tmp/ttdd && sudo install -m 0755 /tmp/ttdd /usr/local/bin/ttdd && rm -f /tmp/ttdd && sudo ttdd
```

The installer is saved as:

```text
/usr/local/bin/ttdd
```

After the first installation, you do not need to download `install.sh` again. Use the local `ttdd` command for all management tasks.

During the first setup, the installer asks whether HTTPS should be enabled. Choosing HTTP-only skips certificate issuance and Certbot setup.

## Common commands

```bash
# Show service and storage status
sudo ttdd --status

# Reset the qBittorrent WebUI password only
sudo ttdd --reset-password

# Check disk usage, hidden qBittorrent trash and deleted-but-open files
sudo ttdd --disk-check

# Permanently remove old qBittorrent .Trash-* directories after confirmation
sudo ttdd --purge-trash

# Enable HTTPS
sudo ttdd --enable-ssl

# Disable HTTPS
sudo ttdd --disable-ssl

# Check for a newer release and update the installation
sudo ttdd --update
```

To set a specific password during reset:

```bash
sudo env QBT_PASSWORD='your-strong-password' ttdd --reset-password
```

## Updating

Update with:

```bash
sudo ttdd --update
```

The updater downloads the current `main` installer from GitHub to a temporary file, validates its Bash syntax and version, and only then replaces `/usr/local/bin/ttdd`.

When a newer version is available:

- the current local installer is backed up as `/usr/local/bin/ttdd.bak`;
- the new installer replaces it atomically;
- an older remote version is never used as a downgrade;
- if an existing stack is detected, the new installer is immediately applied to it;
- downloads, qBittorrent configuration and resume data are preserved.

If the installed version is already current, no stack reinstall is performed.

## Direct-download performance

The generated Nginx configuration is intended for large static downloads and parallel download-manager connections.

Default capacity settings include:

- `worker_processes auto`
- `worker_connections 65535`
- `worker_rlimit_nofile 262144`
- Docker `nofile` soft/hard limit `262144`
- `net.core.somaxconn=65535`
- `reuseport` with a large listen backlog
- `sendfile on`
- `tcp_nopush on`
- `tcp_nodelay on`
- `multi_accept on`
- `limit_rate 0`
- no generated `limit_conn`
- no generated `limit_req`
- Nginx access log disabled to avoid unnecessary disk writes during large transfers

Byte-range requests remain available, so IDM, aria2 and similar clients can use multiple connections for the same file.

Actual speed still depends on the server disk, network interface, route, CPU/TLS overhead, host networking and the client connection.

Inspect the effective Nginx configuration:

```bash
sudo docker exec ttdd-nginx nginx -T
```

## Storage

Default persistent paths:

```text
/srv/qbittorrent/config       qBittorrent configuration and state
/srv/qbittorrent/downloads    completed downloads
/srv/qbittorrent/incomplete   incomplete downloads
/opt/torrent-to-direct-download
                              generated Compose and Nginx files
```

Nginx receives the completed-download directory as a read-only bind mount. It serves the same host files and does not create a second copy.

qBittorrent uses:

```text
/data/downloads
/data/incomplete
```

inside the container. Legacy `/downloads` and `/incomplete` mounts remain available for older torrent resume data and point to the same host directories.

## Deleted files still using disk space

New qBittorrent configuration uses:

```text
Session\TorrentContentRemoveOption=Delete
```

When torrent content is deleted, qBittorrent is configured for permanent removal instead of moving it into hidden `.Trash-*` directories.

To inspect existing disk usage:

```bash
sudo ttdd --disk-check
```

To remove old `.Trash-*` data after reviewing it:

```bash
sudo ttdd --purge-trash
```

The cleanup command asks for confirmation before permanent deletion.

## HTTPS

Enable HTTPS at any time:

```bash
sudo ttdd --enable-ssl
```

Disable it and return to HTTP-only mode:

```bash
sudo ttdd --disable-ssl
```

A valid existing certificate is reused when possible. Certbot renewal dry-run is not executed on every installation.

To run the renewal dry-run manually while applying HTTPS configuration:

```bash
sudo env RUN_RENEWAL_DRY_RUN=1 ttdd --enable-ssl
```

## Important files

```text
/usr/local/bin/ttdd                         local management command
/root/qbittorrent-credentials.txt          qBittorrent login details
/root/qbittorrent-download-info.txt        direct-download information
/root/qbittorrent-ip-ssl-info.txt          HTTPS certificate information
/root/torrent-to-direct-download-error.log last installer diagnostic report
```

## Help

```bash
sudo ttdd --help
```
