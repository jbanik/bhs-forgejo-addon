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
assert "container is running" \
  bash -c '[[ "$(docker inspect -f "{{.State.Running}}" forgejo-smoke)" == "true" ]]'

echo ">>> SMOKE: basic startup assertions only (more added in later tasks)"
echo "ALL ASSERTIONS PASSED"
