#!/bin/sh
# Launches garage-webui against the local Garage admin/S3 APIs.
# Reads optional overrides from the environment and falls back to sane defaults.
set -u

export CONFIG_PATH="${CONFIG_PATH:-/etc/garage.toml}"
# Admin + S3 endpoints the UI talks to. Default to in-container localhost — keep
# these defaults unless you really need the UI to reach Garage via another host.
export API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:3903}"
# Accept S3_ENDPOINT as an alias for the UI's S3_ENDPOINT_URL.
export S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-${S3_ENDPOINT:-http://127.0.0.1:3900}}"
export S3_REGION="${S3_REGION:-Germany-1}"
export API_ADMIN_KEY="${API_ADMIN_KEY:-${GARAGE_ADMIN_TOKEN:-}}"
export AUTH_USER_PASS="${AUTH_USER_PASS:-}"
export HOST="${WEBUI_HOST:-${HOST:-0.0.0.0}}"
export PORT="${WEBUI_PORT:-${PORT:-3909}}"
# Optional: serve the UI under a sub-path (e.g. /garage).
[ -n "${BASE_PATH:-}" ] && export BASE_PATH="$BASE_PATH"

if [ -z "$AUTH_USER_PASS" ]; then
  echo "WARNING: AUTH_USER_PASS not set — the web UI login will reject all users." >&2
fi

exec /usr/local/bin/garage-webui
