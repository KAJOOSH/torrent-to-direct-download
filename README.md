# Torrent to Direct Download

[راهنمای فارسی](README.fa.md)

Turn an Ubuntu server into a simple torrent-to-direct-download server.

Add a torrent or magnet link in qBittorrent. The server downloads it, and completed files become available to users through direct HTTP and trusted HTTPS links.

## What runs in Docker

- Official qBittorrent-nox image using the latest stable tag
- Official Nginx image for direct file downloads
- Official Certbot image for trusted Let's Encrypt IP certificates
- Automatic certificate renewal

The installer also installs Docker Engine and Docker Compose from Docker's official Ubuntu repository when they are missing.

## Requirements

- Ubuntu 22.04, 24.04, 25.10, or 26.04
- Root access
- A public IPv4 address
- Public TCP ports `80`, `443`, and `8080`
- Public TCP/UDP torrent port `49160`
- Port forwarding when the server is behind NAT

The provider or cloud firewall must allow the same ports.

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/main/install.sh \
  -o /tmp/install.sh \
  && sudo bash /tmp/install.sh
```

Recommended installation with an email address:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/main/install.sh \
  -o /tmp/install.sh \
  && sudo env \
    LETSENCRYPT_EMAIL=admin@example.com \
    bash /tmp/install.sh
```

For a server behind NAT, provide the public IP explicitly:

```bash
sudo env \
  PUBLIC_IP=YOUR_PUBLIC_IP \
  LETSENCRYPT_EMAIL=admin@example.com \
  bash /tmp/install.sh
```

## Addresses after installation

```text
qBittorrent WebUI:
http://PUBLIC_IP:8080

Direct downloads:
http://PUBLIC_IP/
https://PUBLIC_IP/
```

The qBittorrent username and generated password are saved here:

```bash
sudo cat /root/qbittorrent-credentials.txt
```

## Update

Run the same installer again. It pulls the current official images and preserves downloads, torrent state, and the existing password.

## Reset the qBittorrent password

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/main/install.sh \
  -o /tmp/install.sh \
  && sudo env RESET_QBT_PASSWORD=1 bash /tmp/install.sh
```

## Important

- If installation fails, a complete diagnostic report is saved to `/root/torrent-to-direct-download-error.log`.
- Failed containers remain running so their logs and mounts can be inspected. Rerunning the installer replaces them safely.
- Completed files on ports `80` and `443` are public and have no password.
- Port `80` must remain publicly reachable for certificate renewal.
- The qBittorrent WebUI is protected with a generated password but is served over HTTP on port `8080`.
- Use the project only for content you are legally allowed to download and share.

## Project goal

This project is intended for people who want a small self-hosted server that receives files from the BitTorrent network and then offers those completed files as ordinary direct downloads for users, browsers, media players, or download managers.
