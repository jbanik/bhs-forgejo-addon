# Forgejo SSH-Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in SSH-push support to the Forgejo HA add-on (Forgejo's built-in SSH server, in-process, no separate daemon). Release as v0.4.0 from `feature/ssh-support` branch after merging to `main`.

**Architecture:** Forgejo's built-in Go SSH server is enabled via two `app.ini` keys (`DISABLE_SSH=false`, `START_SSH_SERVER=true`). Container internal port is fixed at 3022 (matches `ports:` declaration in `config.yaml`). `ssh_port` add-on option is the **advertised port** in clone URLs and is decoupled from the container's internal listen port. External access is via Pangolin TCP-stream forwarding (user-side configuration). Web-UI HTTP port default changes from 3000 to **3080** in the same release (breaking change for users with hardcoded Pangolin routes on 3000).

**Tech Stack:** Bash + bashio (HA add-on init scripts), Forgejo 12.x app.ini config, Docker port mapping, Python (smoke test SSH banner probe), Pangolin (user-side reverse proxy).

**Working files (in `C:\Users\jbani\claude\Projekte\BHS - Forgejo`):**

```
forgejo/
├── config.yaml                                   ← ports defaults + 2 new options
├── CHANGELOG.md                                  ← v0.4.0 entry, ⚠️ BREAKING note
├── README.md                                     ← short-form SSH note update
├── DOCS.md                                       ← new SSH section + Pangolin TCP-stream guide
├── translations/
│   ├── en.yaml                                   ← 2 new option translations
│   └── de.yaml                                   ← 2 new option translations
└── rootfs/etc/cont-init.d/
    └── 20-forgejo-config.sh                      ← SSH conditional block (enable/disable)
tests/
└── smoke.sh                                      ← SSH-enabled assertions + SSH-disabled toggle
```

**Versions to pin / verify at impl time:** Forgejo 12.0.1 + Postgres 16 + addon-base 15.0.9 (unchanged from v0.3.x).

**Branch:** `feature/ssh-support` (already created, head at `9dba78f` — spec commit). All work commits land here. Tag + push come AFTER merge to main (separate task outside this plan).

**Test strategy:** TDD — extend `tests/smoke.sh` with SSH assertions FIRST (red), then implement config + script changes (green). Smoke test runs full lifecycle: enabled state initially, then a toggle-to-disabled restart phase asserting the off-path. SSH banner reachability is verified via Python socket connect (cross-platform).

---

## Task 1: TDD red — extend smoke test with SSH assertions

**Files:**
- Modify: `tests/smoke.sh`

This task adds the failing assertions FIRST. After this task the smoke test should fail at the new SSH assertions (because no implementation exists yet). The next task implements and turns it green.

- [ ] **Step 1: Update test options.json (write SSH-enabled config)**

In `tests/smoke.sh`, find the existing options.json heredoc:

```bash
cat > "$DATA_DIR/options.json" <<'JSON'
{
  "http_port": 13000,
  "root_url": "http://localhost:13000/",
  "site_name": "Forgejo Test",
  "disable_registration": true,
  "require_signin_view": false,
  "log_level": "Info",
  "backup_cron": "*/1 * * * *",
  "backup_retention_days": 1
}
JSON
```

Note: `http_port` was removed in v0.2.0 — leave whatever is there. If the heredoc still has `http_port` from a stale state, leave it (bashio tolerates unknown keys) but the variables we DO need below must be present.

Replace with the same heredoc PLUS two new keys:

```bash
cat > "$DATA_DIR/options.json" <<'JSON'
{
  "root_url": "http://localhost:13000/",
  "site_name": "Forgejo Test",
  "disable_registration": true,
  "require_signin_view": false,
  "log_level": "Info",
  "backup_cron": "*/1 * * * *",
  "backup_retention_days": 1,
  "enable_ssh": true,
  "ssh_port": 3022
}
JSON
```

(If `http_port` was still present from earlier, drop it — it's been deprecated since v0.2.0 anyway.)

- [ ] **Step 2: Add SSH host-port variable + Docker run mapping**

Near the top of `smoke.sh` where `HTTP_PORT="${HTTP_PORT:-13000}"` is defined, add:

```bash
SSH_PORT_HOST="${SSH_PORT_HOST:-13022}"
```

Find the `docker run` invocation:

```bash
docker run -d \
  --name "$CONTAINER" \
  -v "$DATA_DIR":/data \
  -v "$CONFIG_DIR":/config \
  -p "$HTTP_PORT":3000 \
  "$IMAGE" >/dev/null
```

Add the SSH port mapping:

```bash
docker run -d \
  --name "$CONTAINER" \
  -v "$DATA_DIR":/data \
  -v "$CONFIG_DIR":/config \
  -p "$HTTP_PORT":3000 \
  -p "$SSH_PORT_HOST":3022 \
  "$IMAGE" >/dev/null
```

- [ ] **Step 3: Add SSH-enabled assertions block**

Find the existing assertion block that checks `app.ini` content (the one with `assert "app.ini exists"` etc., right after the `>>> verifying app.ini generation` echo line). Insert AFTER the existing app.ini assertions but BEFORE the existing `wait_for_http "http://localhost:$HTTP_PORT/api/healthz" 90` line:

```bash
echo ">>> verifying SSH-enabled config (default test options)"
assert "app.ini has START_SSH_SERVER = true" \
  grep -q '^START_SSH_SERVER = true' "$DATA_DIR/forgejo/conf/app.ini"
assert "app.ini has DISABLE_SSH = false" \
  grep -q '^DISABLE_SSH = false' "$DATA_DIR/forgejo/conf/app.ini"
assert "app.ini has SSH_LISTEN_PORT = 3022" \
  grep -q '^SSH_LISTEN_PORT = 3022' "$DATA_DIR/forgejo/conf/app.ini"
assert "app.ini has SSH_PORT = 3022" \
  grep -q '^SSH_PORT = 3022' "$DATA_DIR/forgejo/conf/app.ini"
assert "app.ini has SSH_DOMAIN = localhost" \
  grep -q '^SSH_DOMAIN = localhost' "$DATA_DIR/forgejo/conf/app.ini"
```

- [ ] **Step 4: Add SSH-banner helper + reachability assertion**

First, define a helper near the existing `wait_for_http()` function. Insert AFTER `wait_for_http()`:

```bash
ssh_banner_ok() {
  local port="$1"
  python -c "
import socket
s = socket.socket()
s.settimeout(3)
try:
    s.connect(('localhost', $port))
    banner = s.recv(50).decode(errors='replace')
    s.close()
    exit(0 if banner.startswith('SSH-2.0-') else 1)
except Exception:
    exit(1)
" 2>/dev/null
}
```

Then insert AFTER the existing `wait_for_http /api/healthz` block and its assertions, BEFORE the backup-related assertions:

```bash
echo ">>> waiting up to 30s for SSH port to accept connections"
elapsed=0
until ssh_banner_ok "$SSH_PORT_HOST"; do
  sleep 2
  elapsed=$((elapsed + 2))
  if [[ $elapsed -ge 30 ]]; then
    echo "  Timeout waiting for SSH banner on localhost:$SSH_PORT_HOST"
    docker logs "$CONTAINER" | tail -50
    exit 1
  fi
done
assert "SSH port responds with SSH-2.0 banner" ssh_banner_ok "$SSH_PORT_HOST"
```

- [ ] **Step 5: Add SSH-disabled toggle test (after the existing persistence-restart block)**

Find the existing block that does `docker stop "$CONTAINER" >/dev/null` followed by `docker start "$CONTAINER" >/dev/null` and the persistence assertions. AFTER that block but BEFORE the final `>>> SMOKE: postgres assertions passed` line, insert:

```bash
echo ">>> toggling SSH off and verifying disable path"
docker stop "$CONTAINER" >/dev/null

cat > "$DATA_DIR/options.json" <<'JSON'
{
  "root_url": "http://localhost:13000/",
  "site_name": "Forgejo Test",
  "disable_registration": true,
  "require_signin_view": false,
  "log_level": "Info",
  "backup_cron": "*/1 * * * *",
  "backup_retention_days": 1,
  "enable_ssh": false,
  "ssh_port": 3022
}
JSON

docker start "$CONTAINER" >/dev/null
echo ">>> waiting up to 60s for Forgejo to come back up after SSH-disable toggle"
wait_for_http "http://localhost:$HTTP_PORT/api/healthz" 60

assert "app.ini has DISABLE_SSH = true after toggle" \
  bash -c "docker exec $CONTAINER grep -q '^DISABLE_SSH = true' /data/forgejo/conf/app.ini"
assert "app.ini has START_SSH_SERVER = false after toggle" \
  bash -c "docker exec $CONTAINER grep -q '^START_SSH_SERVER = false' /data/forgejo/conf/app.ini"
echo ">>> verifying SSH port refuses connection when disabled"
if ssh_banner_ok "$SSH_PORT_HOST"; then
  echo "  FAIL: SSH port should NOT respond with banner when enable_ssh=false"
  exit 1
fi
echo "  PASS: SSH port refuses connection when disabled"
```

(Direct if-then-fail pattern instead of going through the `assert` helper — assert checks success, and we want to assert failure-of-connection, which inverts the helper's contract.)

- [ ] **Step 6: Run smoke test — expected to FAIL on SSH assertions**

```bash
docker build --build-arg BUILD_FROM=ghcr.io/hassio-addons/base:15.0.9 -t bhs/forgejo-addon-test:amd64 forgejo/
bash tests/smoke.sh bhs/forgejo-addon-test:amd64
```

Expected failures:
- "app.ini has START_SSH_SERVER = true" → FAIL (current app.ini still has START_SSH_SERVER = false)
- "app.ini has DISABLE_SSH = false" → FAIL (current has DISABLE_SSH = true)
- "app.ini has SSH_LISTEN_PORT = 3022" → FAIL (line absent)
- "app.ini has SSH_PORT = 3022" → FAIL (line absent)
- "app.ini has SSH_DOMAIN = localhost" → FAIL (line absent)
- "SSH banner reachability" → FAIL or timeout (port not listening)
- The disable-toggle assertions probably pass coincidentally because current state is always "disabled", but the timing might differ

This is the TDD red state. Commit as failing.

- [ ] **Step 7: Commit**

```bash
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik add tests/smoke.sh
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik commit -m "test(ssh): add SSH-enabled and SSH-disabled smoke assertions (red)"
```

---

## Task 2: Implement config + init script (turn smoke green)

**Files:**
- Modify: `forgejo/config.yaml`
- Modify: `forgejo/translations/en.yaml`
- Modify: `forgejo/translations/de.yaml`
- Modify: `forgejo/rootfs/etc/cont-init.d/20-forgejo-config.sh`

- [ ] **Step 1: Update `forgejo/config.yaml`**

Find the `ports:` block:

```yaml
ports:
  3000/tcp: 3000
ports_description:
  3000/tcp: Forgejo HTTP
```

Replace with:

```yaml
ports:
  3000/tcp: 3080
  3022/tcp: 3022
ports_description:
  3000/tcp: Forgejo HTTP
  3022/tcp: Forgejo SSH (only used when enable_ssh option is true)
```

Find the `options:` block. Append the two new options at the end:

```yaml
options:
  root_url: "https://git.banik-haustechnik-schwabach.de/"
  site_name: "Forgejo"
  disable_registration: true
  require_signin_view: false
  log_level: "Info"
  backup_cron: "0 3 * * *"
  backup_retention_days: 7
  enable_ssh: false
  ssh_port: 3022
```

Find the `schema:` block. Append the two new schema entries:

```yaml
schema:
  root_url: url
  site_name: str
  disable_registration: bool
  require_signin_view: bool
  log_level: list(Trace|Debug|Info|Warn|Error|Critical|Fatal)
  backup_cron: "match(^([0-9*,/-]+\\s+){4}[0-9*,/-]+$)"
  backup_retention_days: int(1,365)
  enable_ssh: bool
  ssh_port: port
```

(Leave the rest of `config.yaml` — `image:`, `webui:`, `arch:`, etc. — untouched.)

- [ ] **Step 2: Update `forgejo/translations/en.yaml`**

Append at the end of the `configuration:` block (after the `backup_retention_days:` entry):

```yaml
  enable_ssh:
    name: Enable SSH server
    description: Turn on Forgejo's built-in SSH server for git push/clone over SSH. Default off.
  ssh_port:
    name: SSH port (advertised in clone URLs)
    description: Port shown in clone URLs (e.g. git@host:3022/user/repo.git). Must match the externally accessible port — Host-Port directly (LAN) or the Pangolin/reverse-proxy front port (external). Container internal port is fixed at 3022.
```

- [ ] **Step 3: Update `forgejo/translations/de.yaml`**

Append at the end of the `configuration:` block:

```yaml
  enable_ssh:
    name: SSH-Server aktivieren
    description: Aktiviert Forgejos eingebauten SSH-Server für git push/clone via SSH. Standard aus.
  ssh_port:
    name: SSH-Port (in Clone-URLs)
    description: Port der in Clone-URLs erscheint (z. B. git@host:3022/user/repo.git). Muss dem extern erreichbaren Port entsprechen — Host-Port direkt (LAN) oder dem Pangolin/Reverse-Proxy-Front-Port (extern). Container-interner Port ist fest 3022.
```

- [ ] **Step 4: Update `forgejo/rootfs/etc/cont-init.d/20-forgejo-config.sh`**

Find the existing block that reads HA options (after the `get_option` helper definition):

```bash
HTTP_PORT=$(get_option http_port)
ROOT_URL=$(get_option root_url)
SITE_NAME=$(get_option site_name)
DISABLE_REGISTRATION=$(get_option disable_registration)
REQUIRE_SIGNIN_VIEW=$(get_option require_signin_view)
LOG_LEVEL=$(get_option log_level)
```

(The line `HTTP_PORT=$(get_option http_port)` may have been removed in v0.2.0 — if it's still there, leave it; if not, don't add it back.)

Add two more lines at the end of that block:

```bash
ENABLE_SSH=$(get_option enable_ssh)
SSH_PORT=$(get_option ssh_port)
```

Then find the existing sanitize block:

```bash
sanitize_ini() { tr -d '\n\r`' <<< "$1" | tr -d '\\'; }
SITE_NAME=$(sanitize_ini "$SITE_NAME")
ROOT_URL=$(sanitize_ini "$ROOT_URL")
LOG_LEVEL=$(sanitize_ini "$LOG_LEVEL")
```

Add a sanitize step for ENABLE_SSH (defensive — bashio bools come as `true`/`false` strings, but normalize anyway):

```bash
case "$ENABLE_SSH" in
  true|True|TRUE|1|yes) ENABLE_SSH=true ;;
  *) ENABLE_SSH=false ;;
esac
```

(Add this AFTER the existing sanitize_ini calls.)

Now find the SSH-related lines in the heredoc that writes app.ini. Currently they look like:

```
DISABLE_SSH = true
START_SSH_SERVER = false
LFS_START_SERVER = true
```

Replace with a placeholder that we'll substitute via sed AFTER the heredoc — because heredoc can't do conditionals cleanly. Change to:

```
__SSH_BLOCK__
LFS_START_SERVER = true
```

(Just the two original SSH lines become the single sentinel `__SSH_BLOCK__`. LFS line stays.)

Then AFTER the heredoc closes (the `EOF` line) and BEFORE the secrets-cache restore block, insert:

```bash
# Build the SSH block based on enable_ssh option, then substitute into app.ini.
if [[ "$ENABLE_SSH" == "true" ]]; then
  bashio::log.info "SSH server: enabled (advertised port $SSH_PORT, listen 3022, domain $DOMAIN)"
  SSH_BLOCK="DISABLE_SSH = false
START_SSH_SERVER = true
SSH_LISTEN_PORT = 3022
SSH_PORT = $SSH_PORT
SSH_DOMAIN = $DOMAIN"
else
  bashio::log.info "SSH server: disabled"
  SSH_BLOCK="DISABLE_SSH = true
START_SSH_SERVER = false"
fi

# Substitute the placeholder. Use a temp file to avoid sed-on-multiline-replacement
# pain — write a fresh app.ini through awk.
awk -v block="$SSH_BLOCK" '
  /^__SSH_BLOCK__$/ { print block; next }
  { print }
' "$CONF_FILE" > "$CONF_FILE.tmp" && mv "$CONF_FILE.tmp" "$CONF_FILE"
```

- [ ] **Step 5: Run smoke test — should now pass SSH assertions**

```bash
docker build --build-arg BUILD_FROM=ghcr.io/hassio-addons/base:15.0.9 -t bhs/forgejo-addon-test:amd64 forgejo/
bash tests/smoke.sh bhs/forgejo-addon-test:amd64
```

Expected: ALL assertions pass, including:
- All 5 SSH-enabled app.ini grep assertions
- SSH banner reachability assertion
- SSH-disabled toggle assertions (after the toggle restart)
- All previously-passing assertions still pass

- [ ] **Step 6: Verify shellcheck still clean**

```bash
export MSYS_NO_PATHCONV=1
docker run --rm -v "$(pwd -W):/mnt" -w //mnt koalaman/shellcheck:stable \
  forgejo/rootfs/etc/cont-init.d/20-forgejo-config.sh tests/smoke.sh
echo "exit=$?"
```

Expected exit code 0.

- [ ] **Step 7: Commit**

```bash
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik add \
  forgejo/config.yaml \
  forgejo/translations/en.yaml \
  forgejo/translations/de.yaml \
  forgejo/rootfs/etc/cont-init.d/20-forgejo-config.sh
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik commit -m "feat(ssh): conditional SSH server config + new HA options enable_ssh, ssh_port"
```

---

## Task 3: Documentation — DOCS.md SSH section + Pangolin TCP-stream guide

**Files:**
- Modify: `forgejo/DOCS.md`
- Modify: `forgejo/README.md`

- [ ] **Step 1: Update `forgejo/DOCS.md` — replace existing "SSH Push" section**

Find the existing section heading and content:

```markdown
## SSH Push

Disabled in this add-on. Use HTTPS push with a personal access token:

1. In Forgejo: *Settings → Applications → Generate New Token*. Save the token securely.
2. Clone/push using the token:

   ```bash
   git clone https://<username>:<token>@git.example.com/your/repo.git
   ```

   Or store the token via `git credential` helpers.
```

Replace with:

````markdown
## SSH Push

Optional. Off by default. To enable:

1. In the add-on **Configuration** tab set `enable_ssh: true`. Optionally set `ssh_port` (default `3022`) — this is the port shown in clone URLs.
2. **Restart** the add-on. The Forgejo log shows `SSH server: enabled (advertised port 3022, listen 3022, domain ...)`.
3. Make the SSH port reachable. Two scenarios:
   - **LAN-only:** Done. Forgejo listens on the host port mapped in the **Network** section (default `3022`). Clone URLs become `git@<haos-ip>:3022/user/repo.git`.
   - **External (via reverse proxy):** Set up a TCP-stream forward from the public hostname to `<haos-ip>:<host-port>`. See the Pangolin instructions below for one example. Then set `ssh_port` to the externally accessible port (the front-port your reverse proxy listens on). Clone URLs become `git@<external-host>:<external-port>/user/repo.git`.
4. In Forgejo: *Settings → SSH/GPG Keys → Add Key*. Paste your public key.
5. Verify:
   ```bash
   ssh -p <ssh_port> -T git@<host>
   ```
   Forgejo answers with `Hi there, jbanik! You've successfully authenticated, but Forgejo does not provide shell access.` That message means SSH+key auth works; you can now `git clone/push` over SSH.

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
   - `22` — matches the SSH default; clone URLs hide the port (`git@git.example.com/...`). Only works if Pangolin's host has port 22 free.
   - `3022` — same number as inside; clone URLs show `:3022`. Free of conflicts.
5. **Target:** the LAN IP/hostname of your HAOS host (e.g. `192.168.1.10`)
6. **Target Port:** the host-side port from HA's Network section (default `3022`)
7. **Authentication:** *None* (Forgejo's SSH does its own public-key auth)
8. **Save**, then verify externally:
   ```bash
   nc -v <external-hostname> <external-port>
   ```
   You should see the SSH banner `SSH-2.0-...`.

After Pangolin is set up, set the add-on's `ssh_port` option to whatever **External Port** you picked (so Forgejo's clone URLs match). Restart the add-on.

### Generic reverse proxy (Caddy, Nginx, NPM, …)

Same idea. Caddy example: in `Caddyfile` add a stream block (requires the L4 plugin):

```
:3022 {
    reverse_proxy <haos-ip>:3022
}
```

Or with Nginx's `stream` module:

```nginx
stream {
    server {
        listen 3022;
        proxy_pass <haos-ip>:3022;
    }
}
```

### Other reverse proxy (NPM, plain TCP forwarder, etc.)

Anything that does plain TCP-stream forwarding works — SSH does not need any HTTP layer.
````

- [ ] **Step 2: Update `forgejo/DOCS.md` — adjust the "What lives where" table**

Find the table:

```markdown
| `/data/forgejo/conf/app.ini` | Generated Forgejo config (regenerated each start; includes user override) |
```

Add a new row immediately after that one:

```markdown
| `/data/forgejo/ssh/` | Forgejo SSH server host keys (only present when `enable_ssh: true`; persists across restarts) |
```

- [ ] **Step 3: Update `forgejo/README.md` — adjust the SSH-disabled mention**

Find:

```markdown
- SSH push is disabled by default. Use HTTPS push with personal access tokens.
```

Replace with:

```markdown
- SSH push is opt-in (`enable_ssh: true` in the add-on config). HTTPS push with a personal access token also works.
```

- [ ] **Step 4: Commit**

```bash
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik add forgejo/DOCS.md forgejo/README.md
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik commit -m "docs(ssh): SSH setup section + Pangolin TCP-stream guide"
```

---

## Task 4: Version bump + CHANGELOG (with ⚠️ BREAKING for HTTP port default)

**Files:**
- Modify: `forgejo/config.yaml` (version bump)
- Modify: `forgejo/CHANGELOG.md`
- Modify: `forgejo/DOCS.md` (add migration section)

- [ ] **Step 1: Bump version**

In `forgejo/config.yaml`, change:

```yaml
version: "0.3.2"
```

to:

```yaml
version: "0.4.0"
```

- [ ] **Step 2: Add CHANGELOG entry**

Insert at the top of `forgejo/CHANGELOG.md`, above `## 0.3.2`:

```markdown
## 0.4.0 - 2026-05-06

### ⚠️ Breaking

- **Default HTTP host port mapping changes from `3000` to `3080`.** This is a HA Network-section default; users who rely on `3000` (e.g. with a reverse proxy route hardcoded to `<haos>:3000`) will lose external connectivity unless they either:
  1. Update their reverse proxy upstream to `<haos>:3080`, or
  2. Manually set the host port back to `3000` in the add-on's **Network** section after updating.
- See `DOCS.md` → "Migrating from v0.3.x" for step-by-step.

### Added

- **Optional SSH push.** New options `enable_ssh` (default `false`) and `ssh_port` (default `3022`). When enabled, Forgejo's built-in SSH server runs alongside HTTP — no separate daemon, no extra container service.
- New container port `3022/tcp` exposed for SSH (only used when `enable_ssh: true`).
- DOCS.md: full SSH setup section including Pangolin TCP-stream forwarding steps.
```

- [ ] **Step 3: Add migration section to `forgejo/DOCS.md`**

Insert near the top (after the **Setup** section, before **Reverse Proxy (Pangolin)**):

```markdown
## Migrating from v0.3.x

v0.4.0 changes the **default HTTP host port from 3000 to 3080**. This affects you only if:

- You let HA pick the host port (i.e. you never manually set it in the **Network** section), AND
- You have a reverse proxy or bookmark pointing at `<haos>:3000`.

Two mitigation paths after the update:

**Option 1 — keep using port 3000:** Open the add-on's **Network** tab, set the host port for `3000/tcp` back to `3000`. Save + restart. Reverse proxy keeps working unchanged.

**Option 2 — switch to 3080:** Update your reverse proxy upstream to `<haos>:3080`. The add-on serves on the new default.

If you've always set the port manually, your value is preserved through the update and nothing breaks.
```

- [ ] **Step 4: Commit**

```bash
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik add forgejo/config.yaml forgejo/CHANGELOG.md forgejo/DOCS.md
git -c user.email=jb@banik-haustechnik-schwabach.de -c user.name=jbanik commit -m "release: prep v0.4.0 (CHANGELOG + migration docs)"
```

---

## Task 5: Final verification + push to feature branch (no merge yet)

**Files:**
- (no changes — verification + push only)

- [ ] **Step 1: Run final smoke test**

```bash
docker build --build-arg BUILD_FROM=ghcr.io/hassio-addons/base:15.0.9 -t bhs/forgejo-addon-test:amd64 forgejo/
bash tests/smoke.sh bhs/forgejo-addon-test:amd64
```

Expected: ALL assertions pass, last line `ALL ASSERTIONS PASSED`. Should be 5 (SSH-enabled app.ini) + 1 (SSH banner) + 2 (SSH-disabled after toggle) = 8 new assertions on top of the existing ~22.

- [ ] **Step 2: Run shellcheck and yamllint locally**

```bash
export MSYS_NO_PATHCONV=1
docker run --rm -v "$(pwd -W):/mnt" -w //mnt koalaman/shellcheck:stable \
  forgejo/rootfs/etc/cont-init.d/10-postgres-init.sh \
  forgejo/rootfs/etc/cont-init.d/20-forgejo-config.sh \
  forgejo/rootfs/etc/cont-init.d/30-cron-setup.sh \
  forgejo/rootfs/usr/local/bin/forgejo-backup.sh \
  forgejo/rootfs/usr/local/bin/wait-for-postgres.sh \
  tests/smoke.sh
echo "exit=$?"

python -c "import yaml; yaml.safe_load(open('forgejo/config.yaml'))" && echo "config.yaml: ok"
python -c "import yaml; yaml.safe_load(open('forgejo/translations/en.yaml'))" && echo "en.yaml: ok"
python -c "import yaml; yaml.safe_load(open('forgejo/translations/de.yaml'))" && echo "de.yaml: ok"
```

All exit 0. shellcheck has no findings.

- [ ] **Step 3: Push feature branch to GitHub (no tag yet — merge happens separately)**

```bash
git push -u origin feature/ssh-support
```

Expected: branch published. CI workflows fire only on tagged pushes (build) and pushes to main (lint). Feature branch push triggers neither — that's fine, we already validated locally.

- [ ] **Step 4: Print summary for the user**

After this task completes, the user should:
1. Test on real HA via a Local Add-on copy (or wait for merge + v0.4.0 tag)
2. When ready to merge:
   ```bash
   git checkout main
   git merge --no-ff feature/ssh-support -m "Merge feature/ssh-support: v0.4.0"
   git push origin main
   git tag -a v0.4.0 -m "Forgejo add-on v0.4.0 (SSH support, default port change)"
   git push origin v0.4.0
   ```
   The tag push triggers the multi-arch build workflow → publishes images for v0.4.0.
3. After GHCR publish: in HA settings, update the add-on. Check if HA Network section keeps the user's port choice or resets to 3080 default.

## Self-review against spec

Spec coverage check (`docs/superpowers/specs/2026-05-06-forgejo-ssh-design.md`):

- ✅ Forgejo built-in SSH server (Task 2 step 4)
- ✅ Two new options: enable_ssh, ssh_port (Task 2 steps 1, 4)
- ✅ Port architecture: container fixed 3022, HA host mapping default 3022, advertised port = ssh_port (Task 2 step 1 ports block, Task 2 step 4 SSH_LISTEN_PORT=3022 hardcoded)
- ✅ HTTP host port default 3000 → 3080 (Task 2 step 1)
- ✅ SSH_DOMAIN derived from root_url (Task 2 step 4 — uses existing `$DOMAIN` from earlier in the script)
- ✅ Persistence under `/data/forgejo/ssh/` (Task 3 step 2 — documented in "What lives where")
- ✅ Smoke test for SSH-enabled (Task 1 steps 3-4, made green in Task 2)
- ✅ Smoke test for SSH-disabled toggle (Task 1 step 5, made green in Task 2)
- ✅ DOCS for both generic + Pangolin-specific (Task 3 step 1)
- ✅ Breaking-change handling (Task 4 steps 2-3 — CHANGELOG + migration section)
- ✅ Manual end-to-end test plan (Task 5 step 4 user instructions)

No spec gaps.

## Out-of-scope reminders (NOT in this plan)

- OpenSSH-server install (Forgejo's built-in is sufficient)
- SSH key upload UI (Forgejo's web does this)
- LFS-via-SSH (HTTPS LFS works; SSH-LFS not requested)
- Custom SSH banner (overridable via app.ini.override if needed later)
- Rate limiting (public-key-only auth blocks brute force)
- Tag + push v0.4.0 (deferred to user-driven merge; covered as instructions in Task 5 step 4)
