#!/bin/sh
# Starts the Garage server, then idempotently bootstraps the single-node cluster
# (layout, bucket, S3 key) using the LOCAL CLI. Safe to run on every deploy.
#
# Coolify injects secrets as env vars (SERVICE_PASSWORD_*). We write them
# into the config file at startup because Garage reads the TOML directly.
set -u

BUCKET="${BUCKET_NAME:-customer-data}"
CAPACITY="${CAPACITY:-50G}"

# --- Inject secrets from env vars into garage.toml -------------------------
# Garage reads these from the config file, not env vars named GARAGE_*.
# Coolify provides them as SERVICE_PASSWORD_* in the .env file.
CFG="/etc/garage.toml"

# rpc_secret — must be 32 bytes hex
if [ -n "${GARAGE_RPC_SECRET:-}" ]; then
  sed -i "s/^#* *rpc_secret.*/rpc_secret = \"${GARAGE_RPC_SECRET}\"/" "$CFG" 2>/dev/null || \
  sed -i "/\[rpc\]/a rpc_secret = \"${GARAGE_RPC_SECRET}\"" "$CFG" 2>/dev/null || \
  printf '\nrpc_secret = "%s"\n' "$GARAGE_RPC_SECRET" >> "$CFG"
fi

# admin_token
if [ -n "${GARAGE_ADMIN_TOKEN:-}" ]; then
  sed -i "s/^#* *admin_token.*/admin_token = \"${GARAGE_ADMIN_TOKEN}\"/" "$CFG" 2>/dev/null || \
  printf 'admin_token = "%s"\n' "$GARAGE_ADMIN_TOKEN" >> "$CFG"
fi

# metrics_token
if [ -n "${GARAGE_METRICS_TOKEN:-}" ]; then
  sed -i "s/^#* *metrics_token.*/metrics_token = \"${GARAGE_METRICS_TOKEN}\"/" "$CFG" 2>/dev/null || \
  printf 'metrics_token = "%s"\n' "$GARAGE_METRICS_TOKEN" >> "$CFG"
fi

echo "==> Secrets injected into garage.toml"

# --- Start the server in the background -------------------------------------
garage server &
SRV=$!

# Forward shutdown signals to the server for a clean stop.
trap 'kill -TERM "$SRV" 2>/dev/null; wait "$SRV"; exit 0' TERM INT

# --- Wait until the local node answers --------------------------------------
echo "==> Waiting for local Garage node to be ready..."
i=0
until OUT=$(garage status 2>&1); do
  i=$((i + 1))
  if ! kill -0 "$SRV" 2>/dev/null; then
    echo "ERROR: Garage server exited during startup. Last output:"
    echo "$OUT"
    exit 1
  fi
  if [ $((i % 5)) -eq 0 ]; then
    echo "    still waiting (attempt $i); last error:"
    echo "$OUT" | sed 's/^/      /'
  fi
  sleep 2
done
echo "    Node is up."

# --- 1. Cluster layout -------------------------------------------------------
if garage status | grep -q "NO ROLE ASSIGNED"; then
  NODE_ID=$(garage node id 2>/dev/null | head -1 | cut -d'@' -f1)
  echo "==> Assigning layout to node $NODE_ID (capacity $CAPACITY)..."
  garage layout assign -z dc1 -c "$CAPACITY" "$NODE_ID"
  CUR=$(garage layout show 2>/dev/null | sed -n 's/.*layout version: *\([0-9]*\).*/\1/p' | head -n1)
  garage layout apply --version $(( ${CUR:-0} + 1 ))
else
  echo "==> Layout already assigned, skipping."
fi

# --- 2. Bucket ---------------------------------------------------------------
if garage bucket info "$BUCKET" >/dev/null 2>&1; then
  echo "==> Bucket '$BUCKET' already exists, skipping."
else
  echo "==> Creating bucket '$BUCKET'..."
  garage bucket create "$BUCKET"
fi

# --- 3. S3 access key + permissions -----------------------------------------
if [ -n "${S3_ACCESS_KEY:-}" ] && [ -n "${S3_SECRET_KEY:-}" ]; then
  if garage key info "$S3_ACCESS_KEY" >/dev/null 2>&1; then
    echo "==> Key already imported, skipping."
  else
    echo "==> Importing S3 access key..."
    garage key import "$S3_ACCESS_KEY" "$S3_SECRET_KEY" -n contracts-app --yes
  fi
  echo "==> Granting read/write/owner on '$BUCKET' to the key..."
  garage bucket allow --read --write --owner "$BUCKET" --key "$S3_ACCESS_KEY"
else
  echo "WARNING: S3_ACCESS_KEY/S3_SECRET_KEY not set — skipping key setup."
fi

echo "==> Garage init complete. Bucket '$BUCKET' is ready. Server running (pid $SRV)."

# Keep the container alive on the server process.
wait "$SRV"