# Forgejo Add-on — Documentation

## Setup

1. **Install** the add-on from this repository.
2. Open the **Configuration** tab and set:
   - `root_url` — the externally reachable URL, e.g. `https://git.example.com/`. Must end with a slash.
   - `http_port` — host port to bind (default 3000). Pangolin connects here.
3. **Start** the add-on. Watch the log for `Forgejo running on 0.0.0.0:3000`.
4. Open `http://homeassistant.local:<http_port>` in your browser. The Forgejo Install page loads (one-time only). Walk through it — DB settings are pre-filled, you only need to create the **first admin user**.

## Reverse Proxy (Pangolin)

Point your Pangolin route from your public hostname to `<homeassistant-ip>:<http_port>`. Forgejo trusts the `X-Forwarded-*` headers Pangolin sets.

If Forgejo links/redirects use the wrong scheme/host: re-check `root_url` and restart the add-on.

## Backups

The add-on writes a `pg_dump` to `/data/backups/forgejo-YYYY-MM-DD_HH-MM.sql.gz` according to the `backup_cron` schedule. Files older than `backup_retention_days` are deleted automatically.

`/data/` is included in Home Assistant snapshots, so both the live database files AND the SQL dumps are captured.

### Restore

**Standard restore (from a HA snapshot):**

1. Restore the snapshot in HA. The `/data/` content is brought back.
2. Start the add-on. In most cases Postgres comes up cleanly and Forgejo starts.

**Notfall restore from a `.sql.gz` dump (if Postgres files are corrupted):**

1. Stop the add-on.
2. Open the add-on container's filesystem (e.g. via the `SSH & Web Terminal` add-on or `docker exec`):

   ```bash
   rm -rf /data/postgres
   ```

3. Start the add-on. The init script will create a fresh empty database.
4. Once Forgejo is up, stop it again and import the dump:

   ```bash
   docker exec -i addon_forgejo \
     bash -c 'gunzip -c /data/backups/forgejo-LATEST.sql.gz | su-exec postgres psql -h /tmp -U forgejo forgejo'
   ```

5. Start the add-on.

## SSH Push

Disabled in this add-on. Use HTTPS push with a personal access token:

1. In Forgejo: *Settings → Applications → Generate New Token*. Save the token securely.
2. Clone/push using the token:

   ```bash
   git clone https://<username>:<token>@git.example.com/your/repo.git
   ```

   Or store the token via `git credential` helpers.

## Updating

When a new add-on version is published, HA shows an Update banner. Click Update — HA pulls/builds the new image and restarts the container. `/data/` content is preserved.

**PostgreSQL major-version upgrades** (e.g. 16 → 17) are NOT in-place safe. The release notes will warn explicitly and link to a dedicated migration guide.

## Troubleshooting

| Problem | Check |
|---|---|
| Add-on stays "starting" forever | Logs — likely Postgres init failed. Check disk space and `/data/postgres` permissions. |
| Forgejo `502` from Pangolin | Add-on running? `http_port` matches Pangolin upstream? |
| Wrong URL in emails / clone buttons | `root_url` setting; restart add-on after changing. |
| No backups appearing | Logs of `crond`; verify `backup_cron` is a valid 5-field cron expression. |

## What lives where

| Path | Content |
|---|---|
| `/data/postgres/` | PostgreSQL data files |
| `/data/forgejo/conf/app.ini` | Generated Forgejo config (regenerated each start) |
| `/data/forgejo/repos/` | Git repositories |
| `/data/forgejo/lfs/` | Git LFS objects |
| `/data/forgejo/attachments/` | Issue/PR attachments |
| `/data/backups/` | `pg_dump` dumps |
| `/data/.db_password` | Generated DB password (do not change manually) |
| `/data/forgejo/conf/.secrets` | Cached SECRET_KEY/INTERNAL_TOKEN/JWT_SECRET (do not change manually) |
