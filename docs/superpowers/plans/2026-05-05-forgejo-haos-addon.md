# Forgejo HAOS Add-on Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Home Assistant Add-on that runs Forgejo + bundled PostgreSQL + scheduled DB backups in a single container, deployable via the public GitHub repo `https://github.com/jbanik/bhs-forgejo-addon`.

**Architecture:** Single-container add-on on the official HA add-on base image (Alpine + s6-overlay + bashio). s6-overlay supervises three long-running services (postgres, forgejo, crond) and runs three init scripts before service startup. All persistent data lives under `/data` (HA-snapshotted). HA add-on options are translated to Forgejo's `app.ini` and to `crontab` on every container start.

**Tech Stack:** Docker, s6-overlay v3, bashio, Alpine 3.19+, PostgreSQL 16 (Alpine package), Forgejo 12.x (binary download from codeberg), GitHub Actions, hadolint + shellcheck + yamllint, bash-based integration smoke test.

**Working directory layout (target — what we're building):**

```
bhs-forgejo-addon/                                    # Repo root, pushed to github.com/jbanik/bhs-forgejo-addon
├── .gitignore
├── .github/workflows/
│   ├── lint.yml                                      # hadolint + shellcheck + yamllint
│   └── build.yml                                     # multi-arch image build on tag
├── README.md                                         # Repo top-level README
├── repository.yaml                                   # Marks repo as HA add-on store
├── Makefile                                          # Local dev targets
├── tests/
│   ├── smoke.sh                                      # Integration smoke test
│   └── README.md
└── forgejo/                                          # The add-on
    ├── CHANGELOG.md
    ├── DOCS.md
    ├── README.md
    ├── build.yaml                                    # Multi-arch base image map
    ├── config.yaml                                   # Add-on manifest + options/schema
    ├── Dockerfile
    ├── icon.png                                      # 256x256
    ├── logo.png                                      # 250x100
    ├── translations/
    │   ├── en.yaml
    │   └── de.yaml
    └── rootfs/
        ├── etc/
        │   ├── cont-init.d/
        │   │   ├── 10-postgres-init.sh
        │   │   ├── 20-forgejo-config.sh
        │   │   └── 30-cron-setup.sh
        │   └── s6-overlay/s6-rc.d/
        │       ├── postgres/
        │       │   ├── type
        │       │   ├── run
        │       │   └── dependencies.d/base
        │       ├── postgres-ready/                   # one-shot: blocks forgejo until pg accepts conns
        │       │   ├── type
        │       │   ├── up
        │       │   └── dependencies.d/postgres
        │       ├── forgejo/
        │       │   ├── type
        │       │   ├── run
        │       │   └── dependencies.d/postgres-ready
        │       ├── crond/
        │       │   ├── type
        │       │   ├── run
        │       │   └── dependencies.d/base
        │       └── user/contents.d/                  # marks services as part of "user" bundle
        │           ├── postgres
        │           ├── postgres-ready
        │           ├── forgejo
        │           └── crond
        └── usr/local/bin/
            └── forgejo-backup.sh
```

**Versions to pin (verify "current stable" at implementation time, then update these constants):**

- `BASE_IMAGE_VERSION` = `15.0.10` (HA addon-base, latest stable)
- `FORGEJO_VERSION` = `12.0.1` (latest stable Forgejo 12.x release)
- `POSTGRES_MAJOR` = `16`

**Test strategy:** This add-on is mostly shell + Docker — there is no unit-test framework that fits naturally for every step. We use ONE growing **integration smoke test** (`tests/smoke.sh`) that exercises the real container behavior, plus static checks (shellcheck/hadolint/yamllint). For each task that adds behavior, we extend the smoke test FIRST with the assertion that should pass, run it (it fails), then implement, then the assertion passes, then commit. This is TDD adapted to infrastructure code.

**Test prerequisites:** Docker Desktop on the dev machine (or `docker` CLI on Linux/WSL). The smoke test runs on the dev machine, NOT inside HA. HA is the production target.

---

## Task 1: Repo Skeleton + License + Repository Manifest

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `repository.yaml`
- Create: `forgejo/.gitkeep`

- [ ] **Step 1: Create `.gitignore`**

```
# Build artifacts
*.tmp
*.bak
.DS_Store

# Local test data
test-data/
.smoke-cache/

# Editor
.vscode/
.idea/
*.swp
```

- [ ] **Step 2: Create `repository.yaml`**

```yaml
name: BHS Forgejo Add-ons
url: "https://github.com/jbanik/bhs-forgejo-addon"
maintainer: "jbanik <jb@banik-haustechnik-schwabach.de>"
```

- [ ] **Step 3: Create `README.md`**

````markdown
# BHS Forgejo Add-on Repository for Home Assistant

Self-hosted Forgejo Git server as a Home Assistant Add-on, with bundled PostgreSQL and automatic database backups.

## Add-ons in this repository

| Add-on | Description |
|---|---|
| **Forgejo** | A self-hosted Git server (Forgejo) bundled with PostgreSQL 16 and scheduled database backups. Designed to run behind an external reverse proxy (e.g. Pangolin). |

## Installation

1. In Home Assistant, navigate to **Settings → Add-ons → Add-on Store**.
2. Click the three-dots menu (top-right) → **Repositories**.
3. Add the repository URL:

   ```
   https://github.com/jbanik/bhs-forgejo-addon
   ```

4. Refresh the store. The "Forgejo" add-on appears under "BHS Forgejo Add-ons".
5. Install, configure (at minimum the `root_url` option), then start.

See the per-add-on README and DOCS for details.
````

- [ ] **Step 4: Create empty placeholder so `forgejo/` is committed**

```bash
touch forgejo/.gitkeep
```

- [ ] **Step 5: Initialize git repo and commit**

```bash
cd "C:/Users/jbani/claude/Projekte/BHS - Forgejo"
git init -b main
git add .gitignore README.md repository.yaml forgejo/.gitkeep
git commit -m "chore: initial repo skeleton with HA add-on store manifest"
```

---

## Task 2: Brand Assets (icon.png, logo.png)

**Files:**
- Create: `forgejo/icon.png` (256×256)
- Create: `forgejo/logo.png` (250×100)
- Delete: `forgejo/.gitkeep`

- [ ] **Step 1: Download official Forgejo brand assets**

Source: https://codeberg.org/forgejo/meta/raw/branch/readme/branding/logo.svg (full mark) and https://codeberg.org/forgejo/meta/raw/branch/readme/branding/wordmark.svg (wordmark).

```bash
mkdir -p .brand-tmp
curl -fsSL -o .brand-tmp/logo.svg https://codeberg.org/forgejo/meta/raw/branch/readme/branding/logo.svg
curl -fsSL -o .brand-tmp/wordmark.svg https://codeberg.org/forgejo/meta/raw/branch/readme/branding/wordmark.svg
```

- [ ] **Step 2: Convert/resize to required dimensions**

Requires `rsvg-convert` (Inkscape, ImageMagick `convert` with librsvg, or any SVG-to-PNG tool will work — pick one available locally). Example using `rsvg-convert`:

```bash
rsvg-convert -w 256 -h 256 .brand-tmp/logo.svg -o forgejo/icon.png
rsvg-convert -w 250 -h 100 -a .brand-tmp/wordmark.svg -o forgejo/logo.png
```

If `rsvg-convert` is not available, use ImageMagick:

```bash
magick -background none -density 300 .brand-tmp/logo.svg -resize 256x256 forgejo/icon.png
magick -background none -density 300 .brand-tmp/wordmark.svg -resize 250x100 forgejo/logo.png
```

- [ ] **Step 3: Verify dimensions**

```bash
file forgejo/icon.png   # Expected: PNG image data, 256 x 256
file forgejo/logo.png   # Expected: PNG image data, 250 x 100
```

- [ ] **Step 4: Cleanup and commit**

```bash
rm -rf .brand-tmp
rm forgejo/.gitkeep
git add forgejo/icon.png forgejo/logo.png
git rm forgejo/.gitkeep
git commit -m "feat(forgejo): add official Forgejo brand assets"
```

---

## Task 3: Add-on Manifest (`config.yaml`) + Translations

**Files:**
- Create: `forgejo/config.yaml`
- Create: `forgejo/build.yaml`
- Create: `forgejo/translations/en.yaml`
- Create: `forgejo/translations/de.yaml`
- Create: `forgejo/CHANGELOG.md`

- [ ] **Step 1: Create `forgejo/config.yaml`**

```yaml
name: Forgejo
version: "0.1.0"
slug: forgejo
description: Self-hosted Forgejo Git server with bundled PostgreSQL 16 and scheduled DB backups.
url: "https://github.com/jbanik/bhs-forgejo-addon"
arch:
  - aarch64
  - amd64
  - armv7
init: false
startup: application
boot: auto
host_network: false
hassio_api: false
hassio_role: default
homeassistant_api: false
ports:
  3000/tcp: 3000
ports_description:
  3000/tcp: Forgejo HTTP
map:
  - addon_config:rw
options:
  http_port: 3000
  root_url: "https://git.banik-haustechnik-schwabach.de/"
  site_name: "Forgejo"
  disable_registration: true
  require_signin_view: false
  log_level: "Info"
  backup_cron: "0 3 * * *"
  backup_retention_days: 7
schema:
  http_port: port
  root_url: url
  site_name: str
  disable_registration: bool
  require_signin_view: bool
  log_level: list(Trace|Debug|Info|Warn|Error|Critical|Fatal)
  backup_cron: "match(^([0-9*,/-]+\\s+){4}[0-9*,/-]+$)"
  backup_retention_days: int(1,365)
image: "ghcr.io/jbanik/{arch}-addon-forgejo"
```

Notes:
- `host_network: false` — host port mapping handles connectivity; Pangolin connects via the mapped port.
- `ports.3000/tcp: 3000` — declares the default; user can override the host port via the add-on UI.
- `image:` field enables HA to pull pre-built images from GHCR (we'll wire this up in Task 12). Without it, HA builds locally on each install.

- [ ] **Step 2: Create `forgejo/build.yaml` (multi-arch base map)**

```yaml
build_from:
  aarch64: "ghcr.io/hassio-addons/base:15.0.10"
  amd64: "ghcr.io/hassio-addons/base:15.0.10"
  armv7: "ghcr.io/hassio-addons/base:15.0.10"
labels:
  org.opencontainers.image.title: "Forgejo"
  org.opencontainers.image.description: "Self-hosted Forgejo Git server with bundled PostgreSQL"
  org.opencontainers.image.source: "https://github.com/jbanik/bhs-forgejo-addon"
  org.opencontainers.image.licenses: "MIT"
args:
  TEMPIO_VERSION: 2024.11.2
```

- [ ] **Step 3: Create `forgejo/translations/en.yaml`**

```yaml
configuration:
  http_port:
    name: HTTP port
    description: Host port mapped to Forgejo's internal port 3000.
  root_url:
    name: Root URL
    description: External URL Forgejo should advertise (e.g. https://git.example.com/). Must end with a slash.
  site_name:
    name: Site name
    description: Name shown in the Forgejo UI header.
  disable_registration:
    name: Disable self-registration
    description: When true, only admins can create users.
  require_signin_view:
    name: Require sign-in to view
    description: When true, anonymous users cannot browse repositories.
  log_level:
    name: Log level
    description: Forgejo log verbosity.
  backup_cron:
    name: Backup cron schedule
    description: Standard cron expression (5 fields). Default is daily at 03:00.
  backup_retention_days:
    name: Backup retention (days)
    description: How many days to keep .sql.gz dumps in /data/backups.
```

- [ ] **Step 4: Create `forgejo/translations/de.yaml`**

```yaml
configuration:
  http_port:
    name: HTTP-Port
    description: Host-Port, der auf Forgejos internen Port 3000 gemappt wird.
  root_url:
    name: Root-URL
    description: Externe URL, die Forgejo angeben soll (z. B. https://git.example.com/). Muss mit Schrägstrich enden.
  site_name:
    name: Seitenname
    description: Im Forgejo-Header angezeigter Name.
  disable_registration:
    name: Selbstregistrierung deaktivieren
    description: Wenn true, können nur Admins Benutzer anlegen.
  require_signin_view:
    name: Anmeldung zum Anzeigen erforderlich
    description: Wenn true, können anonyme Benutzer keine Repositories einsehen.
  log_level:
    name: Log-Level
    description: Forgejo Log-Ausführlichkeit.
  backup_cron:
    name: Backup-Cron-Zeitplan
    description: Standard-Cron-Ausdruck (5 Felder). Standard ist täglich um 03:00.
  backup_retention_days:
    name: Backup-Aufbewahrung (Tage)
    description: Wie viele Tage .sql.gz-Dumps in /data/backups aufbewahrt werden.
```

- [ ] **Step 5: Create `forgejo/CHANGELOG.md`**

```markdown
# Changelog

## 0.1.0 (unreleased)

- Initial release.
- Forgejo 12.0.1 + PostgreSQL 16 in a single container.
- Daily database backups via configurable cron expression.
```

- [ ] **Step 6: Commit**

```bash
git add forgejo/config.yaml forgejo/build.yaml forgejo/translations/ forgejo/CHANGELOG.md
git commit -m "feat(forgejo): add HA add-on manifest with options schema and translations"
```

---

## Task 4: Smoke Test Skeleton (test runner + first failing assertion)

**Files:**
- Create: `tests/smoke.sh`
- Create: `tests/README.md`
- Create: `Makefile`

- [ ] **Step 1: Create `Makefile`**

```makefile
.PHONY: lint build smoke clean

ARCH ?= amd64
IMAGE ?= bhs/forgejo-addon-test:$(ARCH)

lint:
	@command -v hadolint >/dev/null && hadolint forgejo/Dockerfile || echo "hadolint not installed, skipping"
	@command -v shellcheck >/dev/null && shellcheck $$(find forgejo/rootfs tests -name '*.sh' -o -name 'run' -o -name 'up') || echo "shellcheck not installed, skipping"
	@command -v yamllint >/dev/null && yamllint forgejo/ repository.yaml || echo "yamllint not installed, skipping"

build:
	docker build \
		--build-arg BUILD_FROM=ghcr.io/hassio-addons/base:15.0.10 \
		-t $(IMAGE) \
		forgejo/

smoke: build
	bash tests/smoke.sh $(IMAGE)

clean:
	-docker rm -f forgejo-smoke 2>/dev/null
	-docker rmi $(IMAGE) 2>/dev/null
	rm -rf test-data
```

- [ ] **Step 2: Create `tests/smoke.sh` with the very first assertion (image builds and starts)**

```bash
#!/usr/bin/env bash
# Integration smoke test for the forgejo add-on.
# Builds the image (if needed), runs it, and asserts behavior.

set -euo pipefail

IMAGE="${1:-bhs/forgejo-addon-test:amd64}"
CONTAINER="forgejo-smoke"
DATA_DIR="$(pwd)/test-data"
HTTP_PORT="${HTTP_PORT:-13000}"

cleanup() {
  echo ">>> cleanup"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR"
}
trap cleanup EXIT

assert() {
  local description="$1"; shift
  if "$@"; then
    echo "  PASS: $description"
  else
    echo "  FAIL: $description"
    exit 1
  fi
}

wait_for_http() {
  local url="$1"
  local timeout="${2:-60}"
  local elapsed=0
  until curl -fsS "$url" >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [[ $elapsed -ge $timeout ]]; then
      echo "  Timeout waiting for $url after ${timeout}s"
      docker logs "$CONTAINER" | tail -50
      return 1
    fi
  done
}

mkdir -p "$DATA_DIR"

echo ">>> writing minimal /data/options.json (HA passes this to the add-on)"
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

echo ">>> starting container"
docker run -d \
  --name "$CONTAINER" \
  -v "$DATA_DIR":/data \
  -p "$HTTP_PORT":3000 \
  "$IMAGE" >/dev/null

echo ">>> waiting up to 60s for container to be running"
sleep 5
assert "container is running" docker inspect -f '{{.State.Running}}' "$CONTAINER" | grep -q true

echo ">>> SMOKE: basic startup assertions only (more added in later tasks)"
echo "ALL ASSERTIONS PASSED"
```

- [ ] **Step 3: Make smoke.sh executable**

```bash
chmod +x tests/smoke.sh
```

- [ ] **Step 4: Create `tests/README.md`**

```markdown
# Tests

## Integration smoke test

Builds the image and exercises real container behavior.

```bash
make smoke
```

Requires Docker. On Windows, run from WSL or Git Bash.

## Linting

```bash
make lint
```

Requires `hadolint`, `shellcheck`, and `yamllint` to be installed locally.
```

- [ ] **Step 5: Run smoke test — expected to FAIL because no Dockerfile exists yet**

```bash
make smoke
```

Expected: `docker build` fails with "Cannot locate specified Dockerfile" or similar.

- [ ] **Step 6: Commit**

```bash
git add Makefile tests/
git commit -m "test: add integration smoke test runner (failing — no Dockerfile yet)"
```

---

## Task 5: Minimal Dockerfile (build succeeds, container runs)

**Files:**
- Create: `forgejo/Dockerfile`

- [ ] **Step 1: Create `forgejo/Dockerfile`**

```dockerfile
ARG BUILD_FROM
FROM ${BUILD_FROM}

# hadolint ignore=DL3008,DL3018
RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      dcron \
      git \
      gnupg \
      jq \
      openssh-client \
      postgresql16 \
      postgresql16-client \
      postgresql16-contrib \
      su-exec \
      tini \
      tzdata

# Forgejo binary
ARG FORGEJO_VERSION=12.0.1
ARG TARGETARCH
# Map docker TARGETARCH to forgejo release arch: amd64 -> amd64, arm64 -> arm64, arm/v7 -> arm-6
# When BuildKit isn't passing TARGETARCH (local docker build), fall back to uname -m mapping.
RUN set -eux; \
    arch="${TARGETARCH:-$(uname -m)}"; \
    case "$arch" in \
      amd64|x86_64)   forgejo_arch=amd64 ;; \
      arm64|aarch64)  forgejo_arch=arm64 ;; \
      arm/v7|armv7l)  forgejo_arch=arm-6 ;; \
      *) echo "unsupported arch: $arch"; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/forgejo \
      "https://codeberg.org/forgejo/forgejo/releases/download/v${FORGEJO_VERSION}/forgejo-${FORGEJO_VERSION}-linux-${forgejo_arch}"; \
    chmod 0755 /usr/local/bin/forgejo; \
    /usr/local/bin/forgejo --version

# Create system users with stable UIDs
RUN addgroup -S -g 1000 git \
 && adduser -S -D -H -h /data/forgejo -s /bin/bash -G git -u 1000 git \
 && mkdir -p /data \
 && chmod 0755 /data

# Copy rootfs (s6 service definitions, init scripts, helper binaries) over container root
COPY rootfs/ /

# Make sure all shell scripts are executable
RUN find /etc/cont-init.d -type f -exec chmod 0755 {} \; \
 && find /etc/s6-overlay -type f \( -name run -o -name up -o -name finish \) -exec chmod 0755 {} \; \
 && find /usr/local/bin -type f -exec chmod 0755 {} \;
```

- [ ] **Step 2: Run smoke test — expected to FAIL because rootfs/ doesn't exist yet**

```bash
make smoke
```

Expected: `docker build` succeeds for early layers, then **FAILS** at `COPY rootfs/ /` because the directory doesn't exist.

- [ ] **Step 3: Create empty rootfs structure so build passes**

```bash
mkdir -p forgejo/rootfs/etc/cont-init.d
mkdir -p forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d
mkdir -p forgejo/rootfs/usr/local/bin
touch forgejo/rootfs/etc/cont-init.d/.gitkeep
touch forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/.gitkeep
touch forgejo/rootfs/usr/local/bin/.gitkeep
```

- [ ] **Step 4: Run smoke test — should now PASS through the "container is running" assertion**

```bash
make smoke
```

Expected output ends with:
```
PASS: container is running
ALL ASSERTIONS PASSED
```

(The container will actually be running idle — base image's s6-init is alive. We add real services in later tasks.)

- [ ] **Step 5: Commit**

```bash
git add forgejo/Dockerfile forgejo/rootfs/
git commit -m "feat(forgejo): minimal Dockerfile installs postgres16 + forgejo binary; smoke test passes"
```

---

## Task 6: Postgres Init Script + Postgres Service

**Files:**
- Create: `forgejo/rootfs/etc/cont-init.d/10-postgres-init.sh`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres/type`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres/run`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres/dependencies.d/base`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/postgres`
- Modify: `tests/smoke.sh` (add postgres assertions)

- [ ] **Step 1: Extend `tests/smoke.sh` — add assertion that postgres data dir is initialized**

Replace the final block (`echo ">>> SMOKE: basic startup assertions only..."`) with:

```bash
echo ">>> waiting up to 60s for postgres to initialize"
elapsed=0
until [[ -f "$DATA_DIR/postgres/PG_VERSION" ]]; do
  sleep 2
  elapsed=$((elapsed + 2))
  if [[ $elapsed -ge 60 ]]; then
    echo "  Timeout waiting for postgres init"
    docker logs "$CONTAINER" | tail -50
    exit 1
  fi
done
assert "postgres data directory is initialized" test -f "$DATA_DIR/postgres/PG_VERSION"
assert "postgres password file is created" test -f "$DATA_DIR/.db_password"
assert "postgres password file is mode 600" \
  bash -c "[[ \"$(stat -c %a "$DATA_DIR/.db_password" 2>/dev/null || stat -f %A "$DATA_DIR/.db_password")\" == \"600\" ]]"

echo ">>> waiting up to 30s for postgres to accept connections"
elapsed=0
until docker exec "$CONTAINER" su-exec postgres pg_isready -h /tmp -q 2>/dev/null; do
  sleep 2
  elapsed=$((elapsed + 2))
  if [[ $elapsed -ge 30 ]]; then
    echo "  postgres not accepting connections"
    docker logs "$CONTAINER" | tail -50
    exit 1
  fi
done
assert "postgres accepts local connections" docker exec "$CONTAINER" su-exec postgres pg_isready -h /tmp -q

echo ">>> SMOKE: postgres assertions passed"
echo "ALL ASSERTIONS PASSED"
```

- [ ] **Step 2: Run smoke test — expected to FAIL on "postgres data directory is initialized"**

```bash
make smoke
```

Expected: PG_VERSION never appears, timeout fires.

- [ ] **Step 3: Create `forgejo/rootfs/etc/cont-init.d/10-postgres-init.sh`**

```bash
#!/usr/bin/env bashio
# shellcheck shell=bash
# Initialize PostgreSQL data directory and create the forgejo database/user on first run.

set -euo pipefail

PGDATA=/data/postgres
PG_BIN=/usr/libexec/postgresql16
PASSWORD_FILE=/data/.db_password

# Ensure /data exists and is writable
mkdir -p /data

# Generate DB password if missing
if [[ ! -f "$PASSWORD_FILE" ]]; then
  bashio::log.info "Generating PostgreSQL password for user 'forgejo'..."
  head -c 32 /dev/urandom | base64 | tr -d '+/=' | head -c 32 > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
fi

# Initialize PGDATA if missing
if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
  bashio::log.info "Initializing PostgreSQL data directory at $PGDATA..."
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"

  su-exec postgres "$PG_BIN/initdb" \
    --pgdata="$PGDATA" \
    --auth-local=trust \
    --auth-host=scram-sha-256 \
    --encoding=UTF8 \
    --locale=C

  # Configure postgres to bind only to 127.0.0.1 (and unix socket)
  cat > "$PGDATA/postgresql.auto.conf" <<'EOF'
listen_addresses = '127.0.0.1'
unix_socket_directories = '/tmp'
shared_buffers = '128MB'
EOF
  chown postgres:postgres "$PGDATA/postgresql.auto.conf"

  bashio::log.info "Starting temporary postgres to create database/user..."
  su-exec postgres "$PG_BIN/pg_ctl" -D "$PGDATA" -o "-h '' -k /tmp" -w start

  PASSWORD=$(cat "$PASSWORD_FILE")
  su-exec postgres psql -h /tmp -d postgres <<EOF
CREATE ROLE forgejo WITH LOGIN PASSWORD '$PASSWORD';
CREATE DATABASE forgejo OWNER forgejo ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0;
EOF

  bashio::log.info "Stopping temporary postgres..."
  su-exec postgres "$PG_BIN/pg_ctl" -D "$PGDATA" -m fast -w stop

  bashio::log.info "PostgreSQL initialization complete."
else
  bashio::log.info "PostgreSQL data directory already exists at $PGDATA — skipping init."
  chown -R postgres:postgres "$PGDATA"
fi

# Always ensure /data/forgejo and /data/backups exist
mkdir -p /data/forgejo /data/backups
chown -R git:git /data/forgejo
chown postgres:postgres /data/backups
chmod 0750 /data/backups
```

Note on `PG_BIN`: Alpine's `postgresql16` package places initdb/pg_ctl/postgres at `/usr/libexec/postgresql16/`. Verify with `apk info -L postgresql16` if path differs at implementation time.

- [ ] **Step 4: Create `forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres/type`**

```
longrun
```

- [ ] **Step 5: Create `forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres/run`**

```bash
#!/command/execlineb -P
# Run postgres as the postgres user with PGDATA=/data/postgres
fdmove -c 2 1
s6-setuidgid postgres
/usr/libexec/postgresql16/postgres -D /data/postgres
```

- [ ] **Step 6: Create dependency marker `forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres/dependencies.d/base`**

```
```

(Empty file — its presence declares the dependency.)

- [ ] **Step 7: Create `forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/postgres`**

```
```

(Empty file — declares postgres is part of the `user` bundle, which s6-overlay starts on container boot.)

- [ ] **Step 8: Remove old `.gitkeep` placeholders that are now superseded**

```bash
rm -f forgejo/rootfs/etc/cont-init.d/.gitkeep
rm -f forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/.gitkeep
```

- [ ] **Step 9: Run smoke test — should now PASS all postgres assertions**

```bash
make smoke
```

Expected: all four postgres-related assertions PASS.

- [ ] **Step 10: Commit**

```bash
git add forgejo/rootfs/etc/cont-init.d/10-postgres-init.sh \
        forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres/ \
        forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/postgres \
        tests/smoke.sh
git rm -f forgejo/rootfs/etc/cont-init.d/.gitkeep forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/.gitkeep 2>/dev/null || true
git commit -m "feat(forgejo): postgres init script + s6 service; smoke test verifies pg starts"
```

---

## Task 7: Forgejo Config Generator (`app.ini` from HA options)

**Files:**
- Create: `forgejo/rootfs/etc/cont-init.d/20-forgejo-config.sh`
- Modify: `tests/smoke.sh`

- [ ] **Step 1: Extend `tests/smoke.sh` — assert app.ini is generated correctly**

Insert before the final `echo ">>> SMOKE: postgres assertions passed"` line:

```bash
echo ">>> verifying app.ini generation"
assert "app.ini exists" test -f "$DATA_DIR/forgejo/conf/app.ini"
assert "app.ini contains correct ROOT_URL" \
  grep -q "^ROOT_URL = http://localhost:13000/" "$DATA_DIR/forgejo/conf/app.ini"
assert "app.ini configures postgres DB" \
  grep -q "^DB_TYPE = postgres" "$DATA_DIR/forgejo/conf/app.ini"
assert "app.ini sets DISABLE_REGISTRATION = true" \
  grep -q "^DISABLE_REGISTRATION = true" "$DATA_DIR/forgejo/conf/app.ini"
assert "app.ini starts with INSTALL_LOCK = false (first boot)" \
  grep -q "^INSTALL_LOCK = false" "$DATA_DIR/forgejo/conf/app.ini"
```

- [ ] **Step 2: Run smoke test — expected to FAIL on "app.ini exists"**

```bash
make smoke
```

- [ ] **Step 3: Create `forgejo/rootfs/etc/cont-init.d/20-forgejo-config.sh`**

```bash
#!/usr/bin/env bashio
# shellcheck shell=bash
# Generate /data/forgejo/conf/app.ini from HA add-on options on every container start.

set -euo pipefail

CONF_DIR=/data/forgejo/conf
CONF_FILE=$CONF_DIR/app.ini
PASSWORD_FILE=/data/.db_password

mkdir -p "$CONF_DIR"

HTTP_PORT=$(bashio::config 'http_port')
ROOT_URL=$(bashio::config 'root_url')
SITE_NAME=$(bashio::config 'site_name')
DISABLE_REGISTRATION=$(bashio::config 'disable_registration')
REQUIRE_SIGNIN_VIEW=$(bashio::config 'require_signin_view')
LOG_LEVEL=$(bashio::config 'log_level')

DB_PASSWORD=$(cat "$PASSWORD_FILE")

# Derive DOMAIN from ROOT_URL (strip scheme + path, keep host[:port])
DOMAIN=$(echo "$ROOT_URL" | sed -E 's#^https?://##; s#/.*##; s#:.*##')

bashio::log.info "Generating Forgejo config: ROOT_URL=$ROOT_URL, DOMAIN=$DOMAIN, HTTP_PORT=$HTTP_PORT"

cat > "$CONF_FILE" <<EOF
APP_NAME = $SITE_NAME
RUN_USER = git
RUN_MODE = prod
WORK_PATH = /data/forgejo

[server]
PROTOCOL = http
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
DOMAIN = $DOMAIN
ROOT_URL = $ROOT_URL
DISABLE_SSH = true
START_SSH_SERVER = false
LFS_START_SERVER = true
LFS_JWT_SECRET = $(openssl rand -base64 32 | tr -d '\n=' | head -c 43)
APP_DATA_PATH = /data/forgejo
OFFLINE_MODE = false

[database]
DB_TYPE = postgres
HOST = 127.0.0.1:5432
NAME = forgejo
USER = forgejo
PASSWD = $DB_PASSWORD
SSL_MODE = disable
LOG_SQL = false

[repository]
ROOT = /data/forgejo/repos

[security]
INSTALL_LOCK = false
SECRET_KEY = $(openssl rand -base64 32 | tr -d '\n=' | head -c 43)
INTERNAL_TOKEN = $(openssl rand -base64 64 | tr -d '\n=' | head -c 105)
PASSWORD_HASH_ALGO = pbkdf2_hi

[oauth2]
JWT_SECRET = $(openssl rand -base64 32 | tr -d '\n=' | head -c 43)

[service]
DISABLE_REGISTRATION = $DISABLE_REGISTRATION
REQUIRE_SIGNIN_VIEW = $REQUIRE_SIGNIN_VIEW
DEFAULT_KEEP_EMAIL_PRIVATE = true
DEFAULT_ALLOW_CREATE_ORGANIZATION = true
ENABLE_NOTIFY_MAIL = false

[session]
PROVIDER = file
PROVIDER_CONFIG = /data/forgejo/sessions

[picture]
AVATAR_UPLOAD_PATH = /data/forgejo/avatars
REPOSITORY_AVATAR_UPLOAD_PATH = /data/forgejo/repo-avatars

[attachment]
PATH = /data/forgejo/attachments

[log]
ROOT_PATH = /data/forgejo/log
MODE = console
LEVEL = $LOG_LEVEL

[lfs]
PATH = /data/forgejo/lfs

[indexer]
ISSUE_INDEXER_PATH = /data/forgejo/indexers/issues.bleve
REPO_INDEXER_ENABLED = true
REPO_INDEXER_PATH = /data/forgejo/indexers/repos.bleve

[mailer]
ENABLED = false

[other]
SHOW_FOOTER_VERSION = false
SHOW_FOOTER_TEMPLATE_LOAD_TIME = false
EOF

# IMPORTANT: regenerating SECRET_KEY/INTERNAL_TOKEN/JWT_SECRET on every start would
# invalidate sessions and 2FA tokens. So: only generate on first run, then stash a copy.
SECRETS_CACHE=/data/forgejo/conf/.secrets
if [[ -f "$SECRETS_CACHE" ]]; then
  bashio::log.info "Restoring cached Forgejo secrets..."
  # shellcheck disable=SC1090
  source "$SECRETS_CACHE"
  sed -i \
    -e "s|^SECRET_KEY = .*|SECRET_KEY = $SECRET_KEY|" \
    -e "s|^INTERNAL_TOKEN = .*|INTERNAL_TOKEN = $INTERNAL_TOKEN|" \
    -e "s|^JWT_SECRET = .*|JWT_SECRET = $JWT_SECRET|" \
    -e "s|^LFS_JWT_SECRET = .*|LFS_JWT_SECRET = $LFS_JWT_SECRET|" \
    "$CONF_FILE"
else
  bashio::log.info "Caching newly generated Forgejo secrets to $SECRETS_CACHE..."
  {
    echo "SECRET_KEY=$(grep -E '^SECRET_KEY ' "$CONF_FILE" | awk '{print $3}')"
    echo "INTERNAL_TOKEN=$(grep -E '^INTERNAL_TOKEN ' "$CONF_FILE" | awk '{print $3}')"
    echo "JWT_SECRET=$(grep -E '^JWT_SECRET ' "$CONF_FILE" | awk '{print $3}')"
    echo "LFS_JWT_SECRET=$(grep -E '^LFS_JWT_SECRET ' "$CONF_FILE" | awk '{print $3}')"
  } > "$SECRETS_CACHE"
  chmod 600 "$SECRETS_CACHE"
fi

chown -R git:git /data/forgejo/conf
chmod 0640 "$CONF_FILE"

bashio::log.info "Forgejo config written to $CONF_FILE."
```

- [ ] **Step 4: Run smoke test — should now PASS app.ini assertions**

```bash
make smoke
```

- [ ] **Step 5: Commit**

```bash
git add forgejo/rootfs/etc/cont-init.d/20-forgejo-config.sh tests/smoke.sh
git commit -m "feat(forgejo): generate app.ini from HA options with persistent secrets cache"
```

---

## Task 8: Forgejo Service + postgres-ready Gate

**Files:**
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres-ready/type`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres-ready/up`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres-ready/dependencies.d/postgres`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/forgejo/type`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/forgejo/run`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/forgejo/dependencies.d/postgres-ready`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/postgres-ready`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/forgejo`
- Modify: `tests/smoke.sh`

- [ ] **Step 1: Extend `tests/smoke.sh` — assert Forgejo HTTP is reachable**

Insert before the final `echo ">>> SMOKE: ..."` summary line:

```bash
echo ">>> waiting up to 90s for Forgejo HTTP healthz"
wait_for_http "http://localhost:$HTTP_PORT/api/healthz" 90
assert "Forgejo /api/healthz responds 200" \
  bash -c "[[ \"$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$HTTP_PORT/api/healthz)\" == \"200\" ]]"
assert "Forgejo HTML home page reachable" \
  bash -c "curl -fsS http://localhost:$HTTP_PORT/ | grep -q 'Forgejo'"
```

- [ ] **Step 2: Run smoke test — expected to FAIL on healthz timeout**

```bash
make smoke
```

- [ ] **Step 3: Create `postgres-ready` one-shot service (gates forgejo on actual pg readiness)**

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres-ready/type`:
```
oneshot
```

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres-ready/up`:
```
/usr/local/bin/wait-for-postgres.sh
```

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres-ready/dependencies.d/postgres`:
(empty file)

- [ ] **Step 4: Create the wait helper `forgejo/rootfs/usr/local/bin/wait-for-postgres.sh`**

This script also handles the INSTALL_LOCK toggle: 20-forgejo-config.sh always writes `INSTALL_LOCK = false`, and once Postgres is up, we check the user count and flip it to `true` if the system already has users. This way Forgejo's installer page is shown only on the very first start.

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "[postgres-ready] waiting for postgres on /tmp socket..."
for _ in $(seq 1 60); do
  if su-exec postgres pg_isready -h /tmp -q; then
    echo "[postgres-ready] postgres is ready"
    break
  fi
  sleep 1
done

if ! su-exec postgres pg_isready -h /tmp -q; then
  echo "[postgres-ready] postgres did not become ready within 60s" >&2
  exit 1
fi

# Toggle INSTALL_LOCK based on whether Forgejo already has users.
APP_INI=/data/forgejo/conf/app.ini
if [[ -f "$APP_INI" ]]; then
  USER_COUNT=$(su-exec postgres psql -h /tmp -U postgres -d forgejo -tAc \
    "SELECT COUNT(*) FROM \"user\";" 2>/dev/null || echo 0)
  USER_COUNT=${USER_COUNT//[!0-9]/}
  USER_COUNT=${USER_COUNT:-0}
  if [[ "$USER_COUNT" -gt 0 ]]; then
    echo "[postgres-ready] $USER_COUNT existing users — locking installer"
    sed -i 's/^INSTALL_LOCK = false$/INSTALL_LOCK = true/' "$APP_INI"
  else
    echo "[postgres-ready] no users yet — installer will be shown"
  fi
fi
```

Note: the query targets the `user` table (Forgejo/Gitea schema). On a freshly-initialized DB the table doesn't exist yet — `psql` errors and we fall back to `0`, which correctly leaves INSTALL_LOCK = false.

- [ ] **Step 5: Create the forgejo service**

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/forgejo/type`:
```
longrun
```

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/forgejo/run`:
```bash
#!/command/execlineb -P
fdmove -c 2 1
s6-setuidgid git
emptyenv -p
export USER git
export HOME /data/forgejo
export GITEA_WORK_DIR /data/forgejo
export GITEA_CUSTOM /data/forgejo/custom
/usr/local/bin/forgejo web --config /data/forgejo/conf/app.ini
```

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/forgejo/dependencies.d/postgres-ready`:
(empty file)

- [ ] **Step 6: Add to user bundle**

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/postgres-ready`:
(empty file)

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/forgejo`:
(empty file)

- [ ] **Step 7: Run smoke test — should now PASS healthz assertion**

```bash
make smoke
```

Expected: all assertions pass; output includes `PASS: Forgejo /api/healthz responds 200`.

- [ ] **Step 8: Commit**

```bash
git add forgejo/rootfs/etc/s6-overlay/s6-rc.d/postgres-ready/ \
        forgejo/rootfs/etc/s6-overlay/s6-rc.d/forgejo/ \
        forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/postgres-ready \
        forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/forgejo \
        forgejo/rootfs/usr/local/bin/wait-for-postgres.sh \
        tests/smoke.sh
git commit -m "feat(forgejo): add forgejo service gated on postgres-ready; smoke test reaches /api/healthz"
```

---

## Task 9: Backup Script + cron Setup

**Files:**
- Create: `forgejo/rootfs/usr/local/bin/forgejo-backup.sh`
- Create: `forgejo/rootfs/etc/cont-init.d/30-cron-setup.sh`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/crond/type`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/crond/run`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/crond/dependencies.d/base`
- Create: `forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/crond`
- Modify: `tests/smoke.sh`

- [ ] **Step 1: Extend `tests/smoke.sh` — assert backup runs and produces dump**

Insert before the final summary line (the smoke test config sets `backup_cron: "*/1 * * * *"` so a backup runs within ~70s):

```bash
echo ">>> waiting up to 90s for first backup dump (cron is */1 in test config)"
elapsed=0
backup_count=0
until [[ "$backup_count" -gt 0 ]]; do
  sleep 5
  elapsed=$((elapsed + 5))
  backup_count=$(find "$DATA_DIR/backups" -name 'forgejo-*.sql.gz' 2>/dev/null | wc -l)
  if [[ $elapsed -ge 90 ]]; then
    echo "  Timeout waiting for backup dump"
    docker logs "$CONTAINER" | tail -50
    ls -la "$DATA_DIR/backups" || true
    exit 1
  fi
done
assert "at least one backup dump was created" test "$backup_count" -gt 0

echo ">>> validating dump is a valid gzip + sql"
DUMP_FILE=$(find "$DATA_DIR/backups" -name 'forgejo-*.sql.gz' | head -1)
assert "dump file is non-empty" test -s "$DUMP_FILE"
assert "dump is valid gzip" gzip -t "$DUMP_FILE"
assert "dump contains forgejo schema" \
  bash -c "gunzip -c '$DUMP_FILE' | head -20 | grep -q 'PostgreSQL database dump'"
```

- [ ] **Step 2: Run smoke test — expected to FAIL on "at least one backup dump was created"**

```bash
make smoke
```

- [ ] **Step 3: Create `forgejo/rootfs/usr/local/bin/forgejo-backup.sh`**

```bash
#!/usr/bin/env bash
# Dumps the forgejo database to /data/backups/ and prunes old dumps.
# Reads retention from /data/options.json (HA writes this) — falls back to 7 days.

set -euo pipefail

BACKUP_DIR=/data/backups
RETENTION_DAYS=$(jq -r '.backup_retention_days // 7' /data/options.json 2>/dev/null || echo 7)

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%F_%H-%M)
DUMP_FILE="$BACKUP_DIR/forgejo-${TIMESTAMP}.sql.gz"

echo "[backup] starting dump to $DUMP_FILE"
if su-exec postgres pg_dump -h /tmp -U postgres -d forgejo | gzip > "$DUMP_FILE"; then
  SIZE=$(stat -c %s "$DUMP_FILE" 2>/dev/null || stat -f %z "$DUMP_FILE")
  echo "[backup] OK: $DUMP_FILE ($SIZE bytes)"
else
  echo "[backup] FAILED dumping forgejo database" >&2
  rm -f "$DUMP_FILE"
  exit 1
fi

echo "[backup] pruning dumps older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -maxdepth 1 -name 'forgejo-*.sql.gz' -mtime "+${RETENTION_DAYS}" -print -delete || true

echo "[backup] done"
```

- [ ] **Step 4: Create `forgejo/rootfs/etc/cont-init.d/30-cron-setup.sh`**

```bash
#!/usr/bin/env bashio
# shellcheck shell=bash
# Generate /etc/crontabs/root from HA add-on option backup_cron.

set -euo pipefail

BACKUP_CRON=$(bashio::config 'backup_cron')

mkdir -p /etc/crontabs
cat > /etc/crontabs/root <<EOF
# Auto-generated by 30-cron-setup.sh — DO NOT EDIT
$BACKUP_CRON /usr/local/bin/forgejo-backup.sh >> /data/backups/.backup.log 2>&1
EOF
chmod 0600 /etc/crontabs/root

bashio::log.info "Backup cron schedule installed: $BACKUP_CRON"
```

- [ ] **Step 5: Create the crond service**

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/crond/type`:
```
longrun
```

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/crond/run`:
```bash
#!/command/execlineb -P
fdmove -c 2 1
/usr/sbin/crond -f -l 8
```

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/crond/dependencies.d/base`:
(empty file)

`forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/crond`:
(empty file)

- [ ] **Step 6: Run smoke test — should now PASS backup assertions**

```bash
make smoke
```

Expected: dump file appears within 90s, all backup assertions PASS.

- [ ] **Step 7: Commit**

```bash
git add forgejo/rootfs/usr/local/bin/forgejo-backup.sh \
        forgejo/rootfs/etc/cont-init.d/30-cron-setup.sh \
        forgejo/rootfs/etc/s6-overlay/s6-rc.d/crond/ \
        forgejo/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/crond \
        tests/smoke.sh
git commit -m "feat(forgejo): scheduled DB backup via cron + retention pruning"
```

---

## Task 10: Persistence Across Restart

**Files:**
- Modify: `tests/smoke.sh`

This task adds NO new code — it adds a regression test verifying that data survives a container restart. If it fails, we have a real bug to fix.

- [ ] **Step 1: Extend `tests/smoke.sh` — restart container, verify data persists**

Insert before the final `echo ">>> SMOKE: ..."` summary line:

```bash
echo ">>> stopping and restarting container to verify data persistence"
docker stop "$CONTAINER" >/dev/null
docker start "$CONTAINER" >/dev/null

echo ">>> waiting up to 60s for Forgejo to come back up"
wait_for_http "http://localhost:$HTTP_PORT/api/healthz" 60
assert "Forgejo healthz responds 200 after restart" \
  bash -c "[[ \"$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$HTTP_PORT/api/healthz)\" == \"200\" ]]"
assert "DB password file persisted" test -f "$DATA_DIR/.db_password"
assert "Postgres data dir persisted" test -f "$DATA_DIR/postgres/PG_VERSION"
assert "Forgejo secrets cache persisted" test -f "$DATA_DIR/forgejo/conf/.secrets"
```

- [ ] **Step 2: Run smoke test**

```bash
make smoke
```

If anything fails on restart (e.g. permissions get re-applied destructively, secrets get regenerated, etc.) — that's a real bug. Fix in `10-postgres-init.sh` or `20-forgejo-config.sh` and re-run until green.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke.sh
git commit -m "test: verify data persistence and Forgejo recovery across container restart"
```

---

## Task 11: Documentation (DOCS.md, per-add-on README)

**Files:**
- Create: `forgejo/README.md`
- Create: `forgejo/DOCS.md`

- [ ] **Step 1: Create `forgejo/README.md` (short — shown in HA store list)**

```markdown
# Home Assistant Add-on: Forgejo

Self-hosted Forgejo Git server with bundled PostgreSQL 16 and scheduled database backups. Designed to run behind an external reverse proxy (Pangolin, Nginx Proxy Manager, Caddy, …) which handles TLS.

## About

- Forgejo 12.x runs alongside PostgreSQL 16 in a single container.
- Database is dumped daily to `/data/backups/` (configurable schedule + retention).
- All persistent data lives under `/data/`, included in Home Assistant snapshots.
- HTTP only — TLS is the reverse proxy's job.
- SSH push is disabled by default. Use HTTPS push with personal access tokens.

See `DOCS.md` for setup details.
```

- [ ] **Step 2: Create `forgejo/DOCS.md` (long — shown in HA UI Documentation tab)**

````markdown
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
````

- [ ] **Step 3: Commit**

```bash
git add forgejo/README.md forgejo/DOCS.md
git commit -m "docs(forgejo): per-add-on README and detailed user docs"
```

---

## Task 12: GitHub Actions — Lint Workflow

**Files:**
- Create: `.github/workflows/lint.yml`

- [ ] **Step 1: Create `.github/workflows/lint.yml`**

```yaml
name: Lint

on:
  push:
    branches: [main]
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Hadolint
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: forgejo/Dockerfile

      - name: ShellCheck
        uses: ludeeus/action-shellcheck@2.0.0
        with:
          scandir: ./forgejo/rootfs
          additional_files: tests/smoke.sh

      - name: Yamllint
        uses: ibiqlik/action-yamllint@v3
        with:
          file_or_dir: forgejo/ repository.yaml
          config_data: |
            extends: default
            rules:
              line-length: disable
              document-start: disable
              truthy:
                check-keys: false
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "ci: lint workflow (hadolint, shellcheck, yamllint)"
```

---

## Task 13: GitHub Actions — Multi-Arch Build & Publish

**Files:**
- Create: `.github/workflows/build.yml`

- [ ] **Step 1: Create `.github/workflows/build.yml`**

```yaml
name: Build

on:
  push:
    tags: ["v*"]
  workflow_dispatch:
    inputs:
      version:
        description: "Version tag to build (e.g. v0.1.0)"
        required: true

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        arch: [amd64, aarch64, armv7]
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build add-on image
        uses: home-assistant/builder@2024.08.2
        with:
          args: |
            --${{ matrix.arch }} \
            --target /data/forgejo \
            --image "ghcr.io/jbanik/{arch}-addon-forgejo" \
            --docker-hub ghcr.io/jbanik
        env:
          CAS_API_KEY: ${{ secrets.GITHUB_TOKEN }}
```

Note: the official HA builder action handles QEMU + buildx + tag generation. The `--image` value matches the `image:` field in `forgejo/config.yaml`. Verify the latest builder action version at implementation time (current pinned: `2024.08.2`).

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: multi-arch build & publish to GHCR on tag"
```

---

## Task 14: Pre-Release Sanity, Push to GitHub, Tag v0.1.0

**Files:**
- Modify: `forgejo/CHANGELOG.md` (un-mark "unreleased")
- Modify: `forgejo/config.yaml` (final version check)

- [ ] **Step 1: Run all local tests one more time**

```bash
make lint
make smoke
```

Both must pass.

- [ ] **Step 2: Update `forgejo/CHANGELOG.md`**

```markdown
# Changelog

## 0.1.0 - 2026-05-05

- Initial release.
- Forgejo 12.0.1 + PostgreSQL 16 in a single container.
- Daily database backups via configurable cron expression.
- Persistent data under `/data/`, captured in HA snapshots.
- HTTPS push only (SSH disabled).
- Designed for use behind an external reverse proxy (Pangolin etc.).
```

- [ ] **Step 3: Verify `forgejo/config.yaml` `version: "0.1.0"`**

```bash
grep '^version:' forgejo/config.yaml
# Expected: version: "0.1.0"
```

- [ ] **Step 4: Add the GitHub remote and push**

```bash
git remote add origin https://github.com/jbanik/bhs-forgejo-addon.git
git push -u origin main
```

(User must have created the empty repo at GitHub beforehand, as noted in the spec.)

- [ ] **Step 5: Tag and push tag (triggers the build workflow)**

```bash
git tag -a v0.1.0 -m "Forgejo add-on v0.1.0"
git push origin v0.1.0
```

- [ ] **Step 6: Verify the build workflow succeeds**

```bash
gh run watch --workflow=build.yml
```

If `gh` CLI isn't authenticated, open the Actions tab in the GitHub UI and watch the run.

- [ ] **Step 7: Manual end-to-end test on actual HAOS**

This last step CANNOT be automated and must be done manually by the user:

1. In HA: *Settings → Add-ons → Add-on Store → ⋮ → Repositories* → add `https://github.com/jbanik/bhs-forgejo-addon`
2. Refresh store, install Forgejo add-on.
3. In add-on Configuration: confirm `root_url = https://git.banik-haustechnik-schwabach.de/`, leave the rest at defaults.
4. Start the add-on. Watch the log for `Forgejo running`.
5. Configure Pangolin route: `git.banik-haustechnik-schwabach.de` → `<haos-ip>:3000`.
6. Open `https://git.banik-haustechnik-schwabach.de/` in browser → install screen → create admin user.
7. Create a test repository, push a commit via HTTPS, verify it shows up in Forgejo UI.
8. Wait for the next scheduled backup window (or trigger manually via add-on terminal: `docker exec addon_forgejo /usr/local/bin/forgejo-backup.sh`). Verify a `.sql.gz` appears in `/data/backups/`.
9. Trigger a HA snapshot. Verify it includes `/data/forgejo/`, `/data/postgres/`, and `/data/backups/`.

If all steps pass: ship it.

---

## Out-of-scope reminders (NOT in this plan, deferred to future versions)

- SMTP/E-Mail notifications
- SSH push support
- HA Sidebar (Ingress) integration
- Forgejo MCP server (separate project)
- Postgres major-version upgrade tooling
