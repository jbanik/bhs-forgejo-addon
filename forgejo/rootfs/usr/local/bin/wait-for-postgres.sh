#!/usr/bin/env bash
# Block until postgres is ready on the local /tmp socket, then optionally
# flip INSTALL_LOCK to true if Forgejo's user table already has rows.
# 20-forgejo-config.sh always writes INSTALL_LOCK = false; the toggle here
# ensures the installer is shown only on the very first start.

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
