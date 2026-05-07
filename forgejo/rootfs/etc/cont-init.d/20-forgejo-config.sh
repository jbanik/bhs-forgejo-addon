#!/usr/bin/env bashio
# shellcheck shell=bash
# Generate /data/forgejo/conf/app.ini from HA add-on options on every container start.

set -euo pipefail

CONF_DIR=/data/forgejo/conf
CONF_FILE=$CONF_DIR/app.ini
PASSWORD_FILE=/data/.db_password
OPTIONS_FILE=/data/options.json

mkdir -p "$CONF_DIR"

# Read a config value via bashio first (real HA), then fall back to reading
# /data/options.json directly with jq. The fallback covers smoke tests and
# any environment where the supervisor API isn't reachable.
get_option() {
  local key="$1"
  local value
  value=$(bashio::config "$key" 2>/dev/null || true)
  if [[ -z "$value" || "$value" == "null" ]] && [[ -f "$OPTIONS_FILE" ]]; then
    value=$(jq -r --arg k "$key" '.[$k] // empty' "$OPTIONS_FILE")
  fi
  echo "$value"
}

ROOT_URL=$(get_option 'root_url')
SITE_NAME=$(get_option 'site_name')
DISABLE_REGISTRATION=$(get_option 'disable_registration')
REQUIRE_SIGNIN_VIEW=$(get_option 'require_signin_view')
LOG_LEVEL=$(get_option 'log_level')
ENABLE_SSH=$(get_option enable_ssh)
SSH_PORT=$(get_option ssh_port)

# Strip characters that would break INI syntax or trigger heredoc interpretation:
# - newlines/CR break line structure
# - backticks trigger command substitution in unquoted heredoc
# - backslashes can surprise downstream parsing; INI doesn't generally need escapes
# Bools, ports, log_level, and root_url are constrained by the HA schema; only
# free-text fields (site_name) need sanitization, but apply consistently for safety.
# NOTE: $ chars in option values WILL undergo shell expansion in the heredoc below.
# In practice this never happens for site_name/log_level (humans don't write $VAR
# in titles), but if it does, the user sees an interpolated value rather than literal $.
# Switching to printf-based field writes would be the bulletproof fix; deferred for now.
# shellcheck disable=SC1003
sanitize_ini() { tr -d '\n\r`' <<< "$1" | tr -d '\\'; }
SITE_NAME=$(sanitize_ini "$SITE_NAME")
ROOT_URL=$(sanitize_ini "$ROOT_URL")
LOG_LEVEL=$(sanitize_ini "$LOG_LEVEL")
case "$ENABLE_SSH" in
  true|True|TRUE|1|yes) ENABLE_SSH=true ;;
  *) ENABLE_SSH=false ;;
esac

DB_PASSWORD=$(cat "$PASSWORD_FILE")

# Derive DOMAIN from ROOT_URL (strip scheme + path, keep host[:port])
DOMAIN=$(echo "$ROOT_URL" | sed -E 's#^https?://##; s#/.*##; s#:.*##')

bashio::log.info "Generating Forgejo config: ROOT_URL=$ROOT_URL, DOMAIN=$DOMAIN"

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
__SSH_BLOCK__
LFS_START_SERVER = true
LFS_JWT_SECRET = $(head -c 32 /dev/urandom | base64 | tr -d '+/=\n' | head -c 43)
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
SECRET_KEY = $(head -c 32 /dev/urandom | base64 | tr -d '+/=\n' | head -c 43)
INTERNAL_TOKEN = $(head -c 64 /dev/urandom | base64 | tr -d '+/=\n' | head -c 105)
PASSWORD_HASH_ALGO = pbkdf2_hi

[oauth2]
JWT_SECRET = $(head -c 32 /dev/urandom | base64 | tr -d '+/=\n' | head -c 43)

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

# IMPORTANT: regenerating SECRET_KEY/INTERNAL_TOKEN/JWT_SECRET on every start would
# invalidate sessions and 2FA tokens. So: only generate on first run, then stash a copy.
SECRETS_CACHE=/data/forgejo/conf/.secrets
if [[ -f "$SECRETS_CACHE" ]]; then
  bashio::log.info "Restoring cached Forgejo secrets..."
  # shellcheck disable=SC1090
  source "$SECRETS_CACHE"
  : "${SECRET_KEY:?cached SECRET_KEY is empty or missing in $SECRETS_CACHE}"
  : "${INTERNAL_TOKEN:?cached INTERNAL_TOKEN is empty or missing in $SECRETS_CACHE}"
  : "${JWT_SECRET:?cached JWT_SECRET is empty or missing in $SECRETS_CACHE}"
  : "${LFS_JWT_SECRET:?cached LFS_JWT_SECRET is empty or missing in $SECRETS_CACHE}"
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

# Snapshot the HA-generated config (what HA-options produced) for user inspection.
# /config/ is user-visible — redact every secret value before writing the snapshot.
mkdir -p /config/forgejo
sed -E '
  s|^(PASSWD = ).*|\1<REDACTED>|
  s|^(SECRET_KEY = ).*|\1<REDACTED>|
  s|^(INTERNAL_TOKEN = ).*|\1<REDACTED>|
  s|^(JWT_SECRET = ).*|\1<REDACTED>|
  s|^(LFS_JWT_SECRET = ).*|\1<REDACTED>|
' "$CONF_FILE" > /config/forgejo/app.ini.generated
chmod 0640 /config/forgejo/app.ini.generated

# Apply user overlay: append /config/forgejo/app.ini.override (if any) to app.ini.
# Forgejo's INI parser is last-key-wins, so user-supplied values override our generated ones.
OVERRIDE_FILE=/config/forgejo/app.ini.override
if [[ -f "$OVERRIDE_FILE" ]]; then
  bashio::log.info "Applying user overlay from $OVERRIDE_FILE"
  {
    echo
    echo "; ===== begin user override (from $OVERRIDE_FILE) ====="
    cat "$OVERRIDE_FILE"
    echo "; ===== end user override ====="
  } >> "$CONF_FILE"
else
  bashio::log.info "No user overlay file at $OVERRIDE_FILE (skipping)"
fi

chown -R git:git /data/forgejo/conf
chmod 0640 "$CONF_FILE"

bashio::log.info "Forgejo config written to $CONF_FILE."
