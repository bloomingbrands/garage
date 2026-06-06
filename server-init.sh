#!/bin/sh
# Starts the Garage server, then idempotently bootstraps the single-node cluster
# (layout, bucket, S3 key) using the LOCAL CLI. Safe to run on every deploy.
#
# Secrets and domains come from environment variables (set in Coolify) and are
# written into /etc/garage.toml at startup, because Garage reads the TOML file
# directly. The container filesystem is rebuilt from the image on every deploy,
# so /etc/garage.toml always starts as the committed template — only the
# meta/data volumes persist.
set -u

CFG="/etc/garage.toml"
BUCKET="${BUCKET_NAME:-customer-data}"
CAPACITY="${CAPACITY:-20G}"
ZONE="${ZONE:-dc1}"

# --- 1. Inject secrets into garage.toml -------------------------------------
inject() { # inject <placeholder> <value>
  [ -n "$2" ] || return 0
  # Use a non-/ delimiter so values with slashes don't break sed.
  sed -i "s|$1|$2|g" "$CFG"
}
inject "__RPC_SECRET__"    "${GARAGE_RPC_SECRET:-}"
inject "__ADMIN_TOKEN__"   "${GARAGE_ADMIN_TOKEN:-}"
inject "__METRICS_TOKEN__" "${GARAGE_METRICS_TOKEN:-}"

# --- 2. Inject public root domains (vhost-style S3 + static web) ------------
# S3_DOMAIN=s3.example.com  ->  root_domain = ".s3.example.com"
# WEB_DOMAIN=web.example.com ->  root_domain = ".web.example.com"
if [ -n "${S3_DOMAIN:-}" ]; then
  sed -i "s|\.s3\.example\.com|.${S3_DOMAIN}|" "$CFG"
fi
if [ -n "${WEB_DOMAIN:-}" ]; then
  sed -i "s|\.web\.example\.com|.${WEB_DOMAIN}|" "$CFG"
fi

# Fail loudly if the required secrets weren't provided.
if grep -q "__RPC_SECRET__\|__ADMIN_TOKEN__\|__METRICS_TOKEN__" "$CFG"; then
  echo "ERROR: GARAGE_RPC_SECRET / GARAGE_ADMIN_TOKEN / GARAGE_METRICS_TOKEN must all be set." >&2
  exit 1
fi
echo "==> Config prepared (bucket=$BUCKET capacity=$CAPACITY zone=$ZONE)"

# --- 3. Start the server in the background ----------------------------------
garage server &
SRV=$!
trap 'kill -TERM "$SRV" 2>/dev/null; wait "$SRV"; exit 0' TERM INT

# --- 4. Wait until the local node answers -----------------------------------
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

# --- 5. Cluster layout ------------------------------------------------------
if garage status | grep -q "NO ROLE ASSIGNED"; then
  NODE_ID=$(garage node id 2>/dev/null | head -1 | cut -d'@' -f1)
  echo "==> Assigning layout to node $NODE_ID (zone $ZONE, capacity $CAPACITY)..."
  garage layout assign -z "$ZONE" -c "$CAPACITY" "$NODE_ID"
  CUR=$(garage layout show 2>/dev/null | sed -n 's/.*layout version: *\([0-9]*\).*/\1/p' | head -n1)
  garage layout apply --version $(( ${CUR:-0} + 1 ))
else
  echo "==> Layout already assigned, skipping."
fi

# --- 6. Bucket --------------------------------------------------------------
if garage bucket info "$BUCKET" >/dev/null 2>&1; then
  echo "==> Bucket '$BUCKET' already exists, skipping."
else
  echo "==> Creating bucket '$BUCKET'..."
  garage bucket create "$BUCKET"
fi

# --- 7. S3 access key + permissions -----------------------------------------
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

# --- 8. Optional: make the bucket's static site reachable at WEB_DOMAIN ------
if [ -n "${WEB_DOMAIN:-}" ]; then
  garage bucket website --allow "$BUCKET" >/dev/null 2>&1 || true
fi

echo "==> Garage init complete. Bucket '$BUCKET' is ready. Server running (pid $SRV)."
wait "$SRV"
