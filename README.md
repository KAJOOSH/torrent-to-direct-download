# qBittorrent Direct Download Server

[فارسی](README.fa.md)

A simple Ubuntu installer that downloads files through qBittorrent and makes completed files available to users as direct HTTP and HTTPS downloads.

## Project goal

The goal of this project is to turn an Ubuntu server into a simple download server:

1. Add a torrent or magnet link to qBittorrent.
2. Let the server download the files.
3. Share the completed files with users through direct download links.

No domain name is required. The installer can obtain a trusted Let's Encrypt certificate directly for a public IPv4 address.

## Main features

- Installs and configures qBittorrent-nox
- Reuses an existing `qbittorrent-root` service when available
- Installs and configures Nginx
- Publishes completed downloads over HTTP and HTTPS
- Uses ports `80` and `443`
- Obtains a trusted SSL certificate for a public IPv4
- Enables automatic SSL renewal
- Keeps the installation safe to run again

## Requirements

- Ubuntu server
- Root or sudo access
- A public IPv4 address
- Public access to TCP ports `80` and `443`
- Port forwarding when the server is behind NAT

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh   -o /tmp/install.sh   && sudo bash /tmp/install.sh
```

Install with a specific public IP and email:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh   -o /tmp/install.sh   && sudo env     PUBLIC_IP=YOUR_PUBLIC_IP     LETSENCRYPT_EMAIL=admin@example.com     bash /tmp/install.sh
```

For a server behind NAT:

```bash
sudo env   PUBLIC_IP=YOUR_PUBLIC_IP   BIND_ADDRESS=0.0.0.0   LETSENCRYPT_EMAIL=admin@example.com   bash /tmp/install.sh
```

## Addresses after installation

```text
qBittorrent Web UI:
http://PUBLIC_IP:8080

Direct download:
http://PUBLIC_IP/
https://PUBLIC_IP/
```

## Useful commands

View qBittorrent credentials:

```bash
sudo cat /root/qbittorrent-credentials.txt
```

View SSL information:

```bash
sudo cat /root/qbittorrent-ip-ssl-info.txt
```

Check services:

```bash
sudo systemctl status qbittorrent-root
sudo systemctl status nginx
```

## Important notes

- TCP port `80` must remain publicly accessible for SSL renewal.
- The public IP must remain assigned or forwarded to the server.
- The download directory is public and has no password by default.
- Anyone who can access ports `80` or `443` can list and download completed files.
- Use this project only for files you are legally allowed to download and share.

## Repository description

```text
Download torrents on Ubuntu and serve completed files as direct HTTP/HTTPS downloads with qBittorrent, Nginx, and trusted IP SSL.
```

## License

Use and modify this project at your own responsibility.
