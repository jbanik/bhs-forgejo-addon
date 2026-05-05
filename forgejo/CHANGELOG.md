# Changelog

## 0.1.0 - 2026-05-05

- Initial release.
- Forgejo 12.0.1 + PostgreSQL 16 in a single container.
- Daily database backups via configurable cron expression.
- Persistent data under `/data/`, captured in HA snapshots.
- HTTPS push only (SSH disabled).
- Designed for use behind an external reverse proxy (Pangolin etc.).
