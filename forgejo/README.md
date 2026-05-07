# Home Assistant Add-on: Forgejo

Self-hosted Forgejo Git server with bundled PostgreSQL 16 and scheduled database backups. Designed to run behind an external reverse proxy (Pangolin, Nginx Proxy Manager, Caddy, …) which handles TLS.

## About

- Forgejo 12.x runs alongside PostgreSQL 16 in a single container.
- Database is dumped daily to `/config/backups/` (configurable schedule + retention).
- All persistent data lives under `/data/`, included in Home Assistant snapshots.
- HTTP only — TLS is the reverse proxy's job.
- SSH push is opt-in (`enable_ssh: true` in the add-on config). HTTPS push with a personal access token also works.
- "OPEN WEB UI" button in the add-on opens Forgejo in a new tab.

See `DOCS.md` for setup details.
