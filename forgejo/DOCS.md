# Forgejo Add-on — Documentation

## Setup

1. **Install** the add-on from this repository.
2. Open the **Configuration** tab and set:
   - `root_url` — the externally reachable URL, e.g. `https://git.example.com/`. Must end with a slash.
3. Open the **Network** section (also in the add-on settings) to set the host port that maps to Forgejo's container port `3000`. Default is `3000`.
4. **Start** the add-on. Watch the log for `Forgejo running on 0.0.0.0:3000`.
5. Open `http://homeassistant.local:<host-port>` in your browser, or click "OPEN WEB UI". The Forgejo Install page loads (one-time only). Walk through it — DB settings are pre-filled, you only need to create the **first admin user**.

## Migrating from v0.3.x

v0.4.0 changes the **default HTTP host port from 3000 to 3080**. This affects you only if:

- You let HA pick the host port (i.e. you never manually set it in the **Network** section), AND
- You have a reverse proxy or bookmark pointing at `<haos>:3000`.

Two mitigation paths after the update:

**Option 1 — keep using port 3000:** Open the add-on's **Network** tab, set the host port for `3000/tcp` back to `3000`. Save + restart. Reverse proxy keeps working unchanged.

**Option 2 — switch to 3080:** Update your reverse proxy upstream to `<haos>:3080`. The add-on serves on the new default.

If you've always set the port manually, your value is preserved through the update and nothing breaks.

## Reverse Proxy (Pangolin)

Point your Pangolin route from your public hostname to `<homeassistant-ip>:<host-port>`. Forgejo trusts the `X-Forwarded-*` headers Pangolin sets.

If Forgejo links/redirects use the wrong scheme/host: re-check `root_url` and restart the add-on.

## Sidebar Entry in Home Assistant

The add-on shows an "OPEN WEB UI" button in its detail page automatically. To get a permanent **Sidebar entry** in Home Assistant that opens Forgejo, edit your `configuration.yaml` (the main HA config, not the add-on config):

```yaml
panel_iframe:
  forgejo:
    title: Forgejo
    icon: mdi:git
    url: https://git.example.com   # use your Pangolin URL or http://homeassistant.local:3000 for LAN-only
    require_admin: false
```

Restart Home Assistant. A "Forgejo" item appears in the sidebar.

**Note on cross-origin:** Modern browsers block iframes from setting cookies on cross-origin URLs (third-party cookie restrictions). If login fails inside the iframe, open Forgejo in a new tab via the "OPEN WEB UI" button or directly.

## Backups

The add-on writes a `pg_dump` to `/addon_configs/<slug>/backups/forgejo-YYYY-MM-DD_HH-MM.sql.gz` according to the `backup_cron` schedule. The directory is visible in the **File Editor** add-on (under `addon_configs → <slug> → backups`) and via Samba/SSH. Files older than `backup_retention_days` are deleted automatically.

Both `/data/` (PostgreSQL data, repositories) AND `/config/` (backups + your overrides) are included in Home Assistant snapshots.

### Restore

**Standard restore (from a HA snapshot):**

1. Restore the snapshot in HA. The `/data/` and `/config/` content is brought back.
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
     bash -c 'gunzip -c /config/backups/forgejo-LATEST.sql.gz | su-exec postgres psql -h /tmp -U forgejo forgejo'
   ```

5. Start the add-on.

## Customizing Forgejo Beyond the Add-on Options

The add-on UI exposes a curated set of common Forgejo settings (`root_url`, `disable_registration`, etc.). Forgejo itself supports many more — anything from the [Forgejo cheat sheet](https://forgejo.org/docs/latest/admin/config-cheat-sheet/).

To set any setting that the add-on UI doesn't expose, drop a file at:

```
/addon_configs/<addon-slug>/forgejo/app.ini.override
```

(Visible in the **File Editor** add-on or via Samba/SSH — under `addon_configs → <slug>`.)

Its contents are appended to the auto-generated `app.ini` on every container start. Forgejo's INI parser is last-key-wins, so values in your override file take precedence over both the defaults and the HA-managed settings.

### Example: force every new repository to be private

Create the file with:

```ini
[repository]
FORCE_PRIVATE = true
DEFAULT_PRIVATE = private
```

Then restart the add-on. Every new repository is now created as private regardless of the user's choice.

### Inspecting what HA generated

The file `addon_configs/<slug>/forgejo/app.ini.generated` is updated on every start with the HA-options-driven config (without your override). Use it as a starting point to see what's already managed and what you might want to add to your override file.

### What you CANNOT override

- Database settings (`[database]`) — those are wired to the in-container PostgreSQL with a generated password.
- The signing keys (`SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET`, `LFS_JWT_SECRET`) — those are restored from the secrets cache on every restart and would re-generate sessions if changed.
- `[server] HTTP_PORT` — Forgejo always listens on `3000` inside the container; map a different host port via the **Network** section in the add-on UI.

## SSH Push

Optional. Off by default. To enable:

1. **Complete the Forgejo install wizard first.** Forgejo's built-in SSH server only starts after the wizard is finished — open the Web UI and walk through it before enabling SSH, otherwise step 5 will hit `Connection refused` with no obvious cause.
2. In the add-on **Configuration** tab set `enable_ssh: true`. Optionally set `ssh_port` (default `3022`) — this is the port shown in clone URLs.
3. **Restart** the add-on. The Forgejo log shows a line starting with `SSH server: enabled` (it includes the advertised port, listen port `3022`, and the domain).
4. Make the SSH port reachable. Two scenarios:
   - **LAN-only:** Done. Forgejo listens on the host port mapped in the **Network** section (default `3022`). Clone URLs become `ssh://git@<haos-ip>:3022/user/repo.git`.
   - **External (via reverse proxy):** Set up a TCP-stream forward from the public hostname to `<haos-ip>:<host-port>`. See the Pangolin instructions below for one example. Then set `ssh_port` to the externally accessible port (the front-port your reverse proxy listens on). Clone URLs become `ssh://git@<external-host>:<external-port>/user/repo.git`.
5. In Forgejo: *Settings → SSH/GPG Keys → Add Key*. Paste your public key.
6. Verify:

   ```bash
   ssh -p <ssh_port> -T git@<host>
   ```

   Forgejo answers with `Hi there, <your-username>! You've successfully authenticated, but Forgejo does not provide shell access.` That message means SSH+key auth works; you can now `git clone/push` over SSH. If you see `Permission denied (publickey)`, re-check that the key was saved under the correct account in *Settings → SSH/GPG Keys*.

### HTTPS push (still works either way)

If you don't want to set up SSH, HTTPS push with a personal access token also works:

1. In Forgejo: *Settings → Applications → Generate New Token* with `write:repository` scope.
2. Clone/push using the token:
   ```bash
   git clone https://<username>:<token>@git.example.com/your/repo.git
   ```

### Pangolin TCP-Stream Setup (for external SSH)

Pangolin handles HTTP routing for the Web-UI, but SSH needs a separate **Raw TCP** resource:

1. Pangolin admin → **Resources → Add Resource**
2. **Resource Type:** *Raw TCP* (NOT HTTP — that's for the Web-UI route, which already exists)
3. **External Hostname:** the public hostname you want SSH on (typically the same as your Forgejo Web-UI hostname, e.g. `git.example.com`)
4. **External Port:** pick one. Common choices:
   - `22` — matches the SSH default; clone URLs use the standard form `git@git.example.com:user/repo.git` (no port needed when 22). Only works if Pangolin's host has port 22 free.
   - `3022` — same number as inside; clone URLs show `ssh://git@git.example.com:3022/user/repo.git`. Free of conflicts.
5. **Target:** the LAN IP/hostname of your HAOS host (e.g. `192.168.1.10`)
6. **Target Port:** the host-side port from HA's Network section (default `3022`)
7. **Authentication:** *None* (Forgejo's SSH does its own public-key auth)
8. **Save**, then verify externally:
   ```bash
   nc -v <external-hostname> <external-port>
   ```
   You should see the SSH banner `SSH-2.0-...`.

After Pangolin is set up, set the add-on's `ssh_port` option to whatever **External Port** you picked (so Forgejo's clone URLs match). Restart the add-on.

### Generic reverse proxy (Nginx, Caddy, …)

Same idea: forward TCP without TLS termination. Nginx's `stream` module example:

```nginx
stream {
    server {
        listen 3022;
        proxy_pass <haos-ip>:3022;
    }
}
```

For **Caddy**, install the [caddy-l4](https://github.com/mholt/caddy-l4) plugin and configure a `layer4` block — see the plugin's README for current syntax.

### Other reverse proxy (NPM, plain TCP forwarder, etc.)

Anything that does plain TCP-stream forwarding works — SSH does not need any HTTP layer. For Nginx Proxy Manager, use a **Stream** entry rather than a Proxy Host.

## Updating

When a new add-on version is published, HA shows an Update banner. Click Update — HA pulls/builds the new image and restarts the container. `/data/` content is preserved.

**PostgreSQL major-version upgrades** (e.g. 16 → 17) are NOT in-place safe. The release notes will warn explicitly and link to a dedicated migration guide.

## Troubleshooting

| Problem | Check |
|---|---|
| Add-on stays "starting" forever | Logs — likely Postgres init failed. Check disk space and `/data/postgres` permissions. |
| Forgejo `502` from Pangolin | Add-on running? Host-port (Network section) matches Pangolin upstream? |
| Wrong URL in emails / clone buttons | `root_url` setting; restart add-on after changing. |
| No backups appearing | Logs of `crond`; verify `backup_cron` is a valid 5-field cron expression. |

## What lives where

| Path | Content |
|---|---|
| `/data/postgres/` | PostgreSQL data files |
| `/data/forgejo/conf/app.ini` | Generated Forgejo config (regenerated each start; includes user override) |
| `/data/forgejo/ssh/` | Forgejo SSH server host keys (only present when `enable_ssh: true`; persists across restarts) |
| `/data/forgejo/repos/` | Git repositories |
| `/data/forgejo/lfs/` | Git LFS objects |
| `/data/forgejo/attachments/` | Issue/PR attachments |
| `/data/.db_password` | Generated DB password (do not change manually) |
| `/data/forgejo/conf/.secrets` | Cached SECRET_KEY/INTERNAL_TOKEN/JWT_SECRET (do not change manually) |
| `/config/backups/` | `pg_dump` dumps (visible as `addon_configs/<slug>/backups/` in HA File Editor) |
| `/config/forgejo/app.ini.override` | Optional user overlay appended to `app.ini` on every start |
| `/config/forgejo/app.ini.generated` | Read-only snapshot of the HA-generated config (without override) |
