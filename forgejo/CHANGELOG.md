# Changelog

## 0.1.1 - 2026-05-06

- Fix CI lint: silence hadolint DL3006 by pinning a default BUILD_FROM.
- Fix CI build: switch GitHub Actions builder args to a YAML folded scalar so all flags reach docker run (the previous block-literal broke the command after the first arg, so --target was never passed and the build failed at config.json lookup).

## 0.1.0 - 2026-05-05

- Initial release.
- Forgejo 12.0.1 + PostgreSQL 16 in a single container.
- Daily database backups via configurable cron expression.
- Persistent data under `/data/`, captured in HA snapshots.
- HTTPS push only (SSH disabled).
- Designed for use behind an external reverse proxy (Pangolin etc.).
