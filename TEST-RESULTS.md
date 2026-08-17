# Test Results — v3.0.0

Date: 2026-08-17

Passed checks:

- `bash -n install.sh`
- `install.sh --help`
- HTTP-only Compose YAML generation and parse
- HTTPS/Certbot Compose YAML generation and parse
- qBittorrent full-mode config generation
- Permanent-delete key: `Session\TorrentContentRemoveOption=Delete`
- Same-root v3 paths: `/data/downloads` and `/data/incomplete`
- Password-only config mutation preserves existing storage path and does not inject full-install storage settings
- Persisted `.env` values load correctly
- Explicit environment overrides take priority over persisted `.env`

Not executed in the build environment:

- A live production Ubuntu Docker deployment
- A real public Let's Encrypt IP-certificate issuance/renewal
- Real BitTorrent traffic and a multi-gigabyte delete test

The installer performs its own Compose/Nginx/qBittorrent runtime verification when run on the target Ubuntu server.
