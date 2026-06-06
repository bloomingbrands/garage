#!/bin/sh
# Generates /etc/garage.toml from environment variables, starts the Garage
# server, then idempotently bootstraps the single-node cluster (layout, bucket,
# S3 key). Safe to run on every deploy.
#
# Design:
#   * The three secrets (rpc_secret, admin_token, metrics_token) are NOT written
#     to the config file. Garage reads GARAGE_RPC_SECRET / GARAGE_ADMIN_TOKEN /
#     GARAGE_METRICS_TOKEN natively from the environment and they override the
#     config, so secrets never touch disk.
#   * Every other setting is env-driven. Required structure is emitted with sane
#     defaults; all tuning options are opt-in — emitted only when the matching
#     env var is set, so Garage's own defaults apply otherwise.
#   * The container filesystem is rebuilt from the image on every deploy; only
#     the meta/data volumes persist.
set -u

CFG="/etc/garage.toml"

# --- Helpers ----------------------------------------------------------------
# Strip scheme/port/path so "https://s3.example.com:3900" -> "s3.example.com".
normalize_host() {
  h="$1"; h="${h#http://}"; h="${h#https://}"; h="${h%%/*}"; h="${h%%:*}"
  echo "$h"
}
emit()   { printf '%s\n' "$1" >> "$CFG"; }
# kv_str <key> <value> : emit `key = "value"` only if value is non-empty
kv_str() { [ -n "$2" ] && emit "$1 = \"$2\""; return 0; }
# kv_raw <key> <value> : emit `key = value` (numbers/bools) only if non-empty
kv_raw() { [ -n "$2" ] && emit "$1 = $2"; return 0; }

# --- Required structure (with defaults) -------------------------------------
METADATA_DIR="${GARAGE_METADATA_DIR:-/var/lib/garage/meta}"
DATA_DIR="${GARAGE_DATA_DIR:-/var/lib/garage/data}"
DB_ENGINE="${GARAGE_DB_ENGINE:-lmdb}"
REPLICATION_FACTOR="${GARAGE_REPLICATION_FACTOR:-1}"
RPC_BIND_ADDR="${GARAGE_RPC_BIND_ADDR:-[::]:3901}"
RPC_PUBLIC_ADDR="${GARAGE_RPC_PUBLIC_ADDR:-127.0.0.1:3901}"
S3_BIND_ADDR="${GARAGE_S3_API_BIND_ADDR:-${GARAGE_S3_BIND_ADDR:-[::]:3900}}"
S3_REGION="${S3_REGION:-Germany-1}"
S3_ROOT_DOMAIN=".$(normalize_host "${S3_DOMAIN:-s3.garage.localhost}")"

BUCKET="${BUCKET_NAME:-${S3_BUCKET:-customer-data}}"
CAPACITY="${CAPACITY:-20G}"
ZONE="${ZONE:-dc1}"

# --- Validate required secrets (read natively by Garage from env) -----------
missing=""
[ -n "${GARAGE_RPC_SECRET:-}" ]    || missing="$missing GARAGE_RPC_SECRET"
[ -n "${GARAGE_ADMIN_TOKEN:-}" ]   || missing="$missing GARAGE_ADMIN_TOKEN"
[ -n "${GARAGE_METRICS_TOKEN:-}" ] || missing="$missing GARAGE_METRICS_TOKEN"
if [ -n "$missing" ]; then
  echo "ERROR: required env var(s) not set:$missing" >&2
  exit 1
fi

# --- Generate garage.toml ---------------------------------------------------
: > "$CFG"   # truncate

# Core
kv_str metadata_dir "$METADATA_DIR"
kv_str data_dir     "$DATA_DIR"
kv_str db_engine    "$DB_ENGINE"
kv_raw replication_factor "$REPLICATION_FACTOR"
kv_str consistency_mode "${GARAGE_CONSISTENCY_MODE:-}"

# Durability / maintenance (opt-in)
kv_raw metadata_fsync "${GARAGE_METADATA_FSYNC:-}"
kv_raw data_fsync     "${GARAGE_DATA_FSYNC:-}"
kv_raw disable_scrub  "${GARAGE_DISABLE_SCRUB:-}"
kv_raw use_local_tz   "${GARAGE_USE_LOCAL_TZ:-}"
kv_str metadata_snapshots_dir "${GARAGE_METADATA_SNAPSHOTS_DIR:-}"
kv_str metadata_auto_snapshot_interval "${GARAGE_METADATA_AUTO_SNAPSHOT_INTERVAL:-}"
kv_raw allow_punycode "${GARAGE_ALLOW_PUNYCODE:-}"

# Storage tuning (opt-in)
kv_str block_size            "${GARAGE_BLOCK_SIZE:-}"
kv_str compression_level     "${GARAGE_COMPRESSION_LEVEL:-}"
kv_str block_ram_buffer_max  "${GARAGE_BLOCK_RAM_BUFFER_MAX:-}"
kv_raw block_max_concurrent_reads "${GARAGE_BLOCK_MAX_CONCURRENT_READS:-}"
kv_raw block_max_concurrent_writes_per_request "${GARAGE_BLOCK_MAX_CONCURRENT_WRITES_PER_REQUEST:-}"
kv_str lmdb_map_size         "${GARAGE_LMDB_MAP_SIZE:-}"
kv_str fjall_block_cache_size "${GARAGE_FJALL_BLOCK_CACHE_SIZE:-}"

# RPC / clustering
kv_str rpc_bind_addr   "$RPC_BIND_ADDR"
kv_str rpc_public_addr "$RPC_PUBLIC_ADDR"
kv_raw rpc_bind_outgoing "${GARAGE_RPC_BIND_OUTGOING:-}"
kv_raw rpc_ping_timeout_msec "${GARAGE_RPC_PING_TIMEOUT_MSEC:-}"
kv_raw rpc_timeout_msec      "${GARAGE_RPC_TIMEOUT_MSEC:-}"
# bootstrap_peers: comma-separated -> TOML array (for multi-node clusters)
if [ -n "${GARAGE_BOOTSTRAP_PEERS:-}" ]; then
  arr=$(printf '%s' "$GARAGE_BOOTSTRAP_PEERS" | sed 's/[[:space:]]//g; s/,/", "/g')
  emit "bootstrap_peers = [\"$arr\"]"
fi

# S3 API
emit ""
emit "[s3_api]"
kv_str s3_region    "$S3_REGION"
kv_str api_bind_addr "$S3_BIND_ADDR"
kv_str root_domain  "$S3_ROOT_DOMAIN"

# Static website serving (enabled unless GARAGE_WEB_ENABLE=false)
if [ "${GARAGE_WEB_ENABLE:-true}" != "false" ]; then
  WEB_BIND_ADDR="${GARAGE_WEB_BIND_ADDR:-[::]:3902}"
  WEB_ROOT_DOMAIN=".$(normalize_host "${WEB_DOMAIN:-web.garage.localhost}")"
  emit ""
  emit "[s3_web]"
  kv_str bind_addr   "$WEB_BIND_ADDR"
  kv_str root_domain "$WEB_ROOT_DOMAIN"
  kv_str index       "${WEB_INDEX:-index.html}"
  kv_raw add_host_to_metrics "${GARAGE_WEB_ADD_HOST_TO_METRICS:-}"
fi

# K2V API (opt-in; the binary is built with the k2v feature)
if [ -n "${GARAGE_K2V_BIND_ADDR:-}" ]; then
  emit ""
  emit "[k2v_api]"
  kv_str api_bind_addr "$GARAGE_K2V_BIND_ADDR"
fi

# Admin API + metrics (tokens come from env natively, not written here)
emit ""
emit "[admin]"
kv_str api_bind_addr "${GARAGE_ADMIN_BIND_ADDR:-[::]:3903}"
kv_raw metrics_require_token "${GARAGE_METRICS_REQUIRE_TOKEN:-}"
kv_str trace_sink "${GARAGE_ADMIN_TRACE_SINK:-}"

echo "==> Generated $CFG :"
sed 's/^/      /' "$CFG"
echo "==> bucket=${BUCKET} capacity=${CAPACITY} zone=${ZONE}"

# --- Start the server in the background --------------------------------------
garage server &
SRV=$!
trap 'kill -TERM "$SRV" 2>/dev/null; wait "$SRV"; exit 0' TERM INT

# --- Wait until the local node answers ---------------------------------------
echo "==> Waiting for local Garage node to be ready..."
i=0
until OUT=$(garage status 2>&1); do
  i=$((i + 1))
  if ! kill -0 "$SRV" 2>/dev/null; then
    echo "ERROR: Garage server exited during startup. Last output:"; echo "$OUT"
    exit 1
  fi
  [ $((i % 5)) -eq 0 ] && { echo "    still waiting (attempt $i); last error:"; echo "$OUT" | sed 's/^/      /'; }
  sleep 2
done
echo "    Node is up."

# --- Cluster layout ----------------------------------------------------------
if garage status | grep -q "NO ROLE ASSIGNED"; then
  NODE_ID=$(garage node id 2>/dev/null | head -1 | cut -d'@' -f1)
  echo "==> Assigning layout to node $NODE_ID (zone $ZONE, capacity $CAPACITY)..."
  garage layout assign -z "$ZONE" -c "$CAPACITY" "$NODE_ID"
  CUR=$(garage layout show 2>/dev/null | sed -n 's/.*layout version: *\([0-9]*\).*/\1/p' | head -n1)
  garage layout apply --version $(( ${CUR:-0} + 1 ))
else
  echo "==> Layout already assigned, skipping."
fi

# --- Bucket ------------------------------------------------------------------
if garage bucket info "$BUCKET" >/dev/null 2>&1; then
  echo "==> Bucket '$BUCKET' already exists, skipping."
else
  echo "==> Creating bucket '$BUCKET'..."
  garage bucket create "$BUCKET"
fi

# --- S3 access key + permissions ---------------------------------------------
if [ -n "${S3_ACCESS_KEY:-}" ] && [ -n "${S3_SECRET_KEY:-}" ]; then
  if garage key info "$S3_ACCESS_KEY" >/dev/null 2>&1; then
    echo "==> Key already imported, skipping."
  else
    echo "==> Importing S3 access key..."
    garage key import "$S3_ACCESS_KEY" "$S3_SECRET_KEY" -n app-key --yes
  fi
  echo "==> Granting read/write/owner on '$BUCKET' to the key..."
  garage bucket allow --read --write --owner "$BUCKET" --key "$S3_ACCESS_KEY"
else
  echo "WARNING: S3_ACCESS_KEY/S3_SECRET_KEY not set — skipping key setup."
fi

# --- Optional: enable static website serving for the bucket ------------------
if [ -n "${WEB_DOMAIN:-}" ] && [ "${GARAGE_WEB_ENABLE:-true}" != "false" ]; then
  garage bucket website --allow "$BUCKET" >/dev/null 2>&1 || true
fi

echo "==> Garage init complete. Bucket '$BUCKET' is ready. Server running (pid $SRV)."
wait "$SRV"
