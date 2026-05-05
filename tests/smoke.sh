#!/usr/bin/env bash
# Integration smoke test for the forgejo add-on.
# Builds the image (if needed), runs it, and asserts behavior.

set -euo pipefail

IMAGE="${1:-bhs/forgejo-addon-test:amd64}"
CONTAINER="forgejo-smoke"
HTTP_PORT="${HTTP_PORT:-13000}"

# DATA_DIR must be a path Docker Desktop can bind-mount AND that this shell
# can read back. On Linux/macOS, the POSIX path works for both. On Windows
# Git Bash / MSYS2, Docker Desktop needs a Windows-style path (C:/...) and
# MSYS will rewrite Unix-looking arguments unless we disable it.
HOST_DATA_DIR="$(pwd)/test-data"
case "${OSTYPE:-}" in
  msys*|cygwin*)
    # Use Windows-style path so Docker Desktop's bind mount points to the
    # actual Windows directory the shell can also read from. Also disable
    # MSYS path conversion so "/data" stays "/data" inside docker args.
    HOST_DATA_DIR="$(pwd -W)/test-data"
    export MSYS_NO_PATHCONV=1
    ;;
esac
DATA_DIR="$HOST_DATA_DIR"

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
assert "Forgejo /api/healthz responds 200" \
  bash -c "[[ \"$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$HTTP_PORT/api/healthz)\" == \"200\" ]]"
assert "Forgejo HTML home page reachable" \
  bash -c "curl -fsS http://localhost:$HTTP_PORT/ | grep -q 'Forgejo'"

echo ">>> SMOKE: postgres assertions passed"
echo "ALL ASSERTIONS PASSED"
