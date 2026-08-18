# Test Results — v3.0.4

Date: 2026-08-17

Passed checks:

- `bash -n install.sh`
- `install.sh --help`
- HTTP-only Compose generation
- HTTPS/Certbot Compose generation
- High-throughput Nginx settings and absence of generated `limit_conn` / `limit_req`
- qBittorrent permanent-delete configuration
- Same-root download paths: `/data/downloads` and `/data/incomplete`
- Password-only configuration change preserves existing storage paths
- Persisted `.env` values load correctly and explicit environment overrides still win
- Local installer persistence to the `ttdd` command path
- Self-update validation and replacement using a simulated newer installer
- Static test suite no longer requires the external Python `PyYAML` module

Not executed in the build environment:

- A live production Ubuntu Docker deployment
- Real public Let's Encrypt certificate issuance/renewal
- Real BitTorrent traffic and multi-gigabyte file deletion
- Internet throughput benchmarking

The installer performs additional Compose, Nginx and qBittorrent runtime checks on the target Ubuntu server during installation.

## v3.0.4 regression

- Fresh install with no persisted `.env` and no caller-supplied `PUBLIC_IP`: passed.
- Automatic public IPv4 detection after empty initialization: passed with a local stub.
- `bash -n install.sh`: passed.
