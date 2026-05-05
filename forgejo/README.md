# Home Assistant Add-on: Forgejo

Self-hosted Forgejo Git server with bundled PostgreSQL 16 and scheduled database backups. Designed to run behind an external reverse proxy (Pangolin, Nginx Proxy Manager, Caddy, …) which handles TLS.

## About

- Forgejo 12.x runs alongside PostgreSQL 16 in a single container.
- Database is dumped daily to `/data/backups/` (configurable schedule + retention).
- All persistent data lives under `/data/`, included in Home Assistant snapshots.
- HTTP only — TLS is the reverse proxy's job.
- SSH push is disabled by default. Use HTTPS push with personal access tokens.

See `DOCS.md` for setup details.
