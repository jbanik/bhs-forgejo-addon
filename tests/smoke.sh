#!/usr/bin/env bash
# Integration smoke test for the forgejo add-on.
# Builds the image (if needed), runs it, and asserts behavior.

set -euo pipefail

IMAGE="${1:-bhs/forgejo-addon-test:amd64}"
CONTAINER="forgejo-smoke"
HTTP_PORT="${HTTP_PORT:-13000}"

# DATA_DIR / CONFIG_DIR must be paths Docker Desktop can bind-mount AND that
# this shell can read back. On Linux/macOS, the POSIX path works for both. On
# Windows Git Bash / MSYS2, Docker Desktop needs a Windows-style path (C:/...)
# and MSYS will rewrite Unix-looking arguments unless we disable it.
HOST_DATA_DIR="$(pwd)/test-data"
HOST_CONFIG_DIR="$(pwd)/test-config"
case "${OSTYPE:-}" in
  msys*|cygwin*)
    # Use Windows-style path so Docker Desktop's bind mount points to the
    # actual Windows directory the shell can also read from. Also disable
    # MSYS path conversion so "/data" stays "/data" inside docker args.
    HOST_DATA_DIR="$(pwd -W)/test-data"
    HOST_CONFIG_DIR="$(pwd -W)/test-config"
    export MSYS_NO_PATHCONV=1
    ;;
esac
DATA_DIR="$HOST_DATA_DIR"
CONFIG_DIR="$HOST_CONFIG_DIR"

cleanup() {
  echo ">>> cleanup"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR"
  rm -rf "$CONFIG_DIR"
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
mkdir -p "$CONFIG_DIR"

echo ">>> writing minimal /data/options.json (HA passes this to the add-on)"
cat > "$DATA_DIR/options.json" <<'JSON'
{
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
  -v "$CONFIG_DIR":/config \
  -p "$HTTP_PORT":3000 \
  "$IMAGE" >/dev/null

echo ">>> waiting up to 60s for container to be running"
sleep 5
running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER")
assert "container is running" test "$running" = "true"

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
# NOTE: Check perms inside the container, not on the host bind mount.
# Docker Desktop on Windows/macOS doesn't preserve POSIX modes through its
# filesharing layer, so a host-side stat returns the wrong value even though
# inside the container the file is correctly chmod 600.
assert "postgres password file is mode 600" \
  bash -c "[[ \"\$(docker exec '$CONTAINER' stat -c %a /data/.db_password)\" == \"600\" ]]"

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

echo ">>> waiting up to 30s for app.ini to appear on host bind mount"
elapsed=0
until [[ -f "$DATA_DIR/forgejo/conf/app.ini" ]]; do
  sleep 2
  elapsed=$((elapsed + 2))
  if [[ $elapsed -ge 30 ]]; then
    echo "  Timeout waiting for app.ini"
    docker logs "$CONTAINER" | tail -50
    exit 1
  fi
done

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

echo ">>> waiting up to 90s for Forgejo HTTP healthz"
wait_for_http "http://localhost:$HTTP_PORT/api/healthz" 90
# shellcheck disable=SC2086
assert "Forgejo /api/healthz responds 200" \
  bash -c "[[ \"$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$HTTP_PORT/api/healthz)\" == \"200\" ]]"
assert "Forgejo HTML home page reachable" \
  bash -c "curl -fsS http://localhost:$HTTP_PORT/ | grep -q 'Forgejo'"

echo ">>> waiting up to 90s for first backup dump (cron is */1 in test config)"
elapsed=0
backup_count=0
until [[ "$backup_count" -gt 0 ]]; do
  sleep 5
  elapsed=$((elapsed + 5))
  backup_count=$(find "$CONFIG_DIR/backups" -name 'forgejo-*.sql.gz' 2>/dev/null | wc -l)
  if [[ $elapsed -ge 90 ]]; then
    echo "  Timeout waiting for backup dump"
    docker logs "$CONTAINER" | tail -50
    ls -la "$CONFIG_DIR/backups" || true
    exit 1
  fi
done
assert "at least one backup dump was created" test "$backup_count" -gt 0

echo ">>> validating dump is a valid gzip + sql"
DUMP_FILE=$(find "$CONFIG_DIR/backups" -name 'forgejo-*.sql.gz' | head -1)
assert "dump file is non-empty" test -s "$DUMP_FILE"
assert "dump is valid gzip" gzip -t "$DUMP_FILE"
assert "dump contains forgejo schema" \
  bash -c "gunzip -c '$DUMP_FILE' | head -20 | grep -q 'PostgreSQL database dump'"

echo ">>> verifying app.ini.generated snapshot exists in /config"
assert "app.ini.generated copy in /config" test -f "$CONFIG_DIR/forgejo/app.ini.generated"

echo ">>> placing app.ini override before restart to verify pickup"
mkdir -p "$CONFIG_DIR/forgejo"
cat > "$CONFIG_DIR/forgejo/app.ini.override" <<'OVERRIDE'
[repository]
FORCE_PRIVATE = true
OVERRIDE

echo ">>> stopping and restarting container to verify data persistence"
docker stop "$CONTAINER" >/dev/null
docker start "$CONTAINER" >/dev/null

echo ">>> waiting up to 60s for Forgejo to come back up"
wait_for_http "http://localhost:$HTTP_PORT/api/healthz" 60
# shellcheck disable=SC2086
assert "Forgejo healthz responds 200 after restart" \
  bash -c "[[ \"$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$HTTP_PORT/api/healthz)\" == \"200\" ]]"
assert "DB password file persisted" test -f "$DATA_DIR/.db_password"
assert "Postgres data dir persisted" test -f "$DATA_DIR/postgres/PG_VERSION"
assert "Forgejo secrets cache persisted" test -f "$DATA_DIR/forgejo/conf/.secrets"
assert "override FORCE_PRIVATE applied after restart" \
  bash -c "docker exec $CONTAINER grep -q '^FORCE_PRIVATE = true' /data/forgejo/conf/app.ini"

echo ">>> SMOKE: postgres assertions passed"
echo "ALL ASSERTIONS PASSED"
