#!/bin/sh
# Idempotent bootstrap for a single-node Garage cluster.
# Safe to run on every deploy: each step is skipped if already done.
set -eu

H="-h garage:3901"
BUCKET="${BUCKET_NAME:-contracts}"
CAPACITY="${CAPACITY:-10G}"

echo "==> Waiting for Garage RPC to become reachable..."
until garage $H status >/dev/null 2>&1; do
  sleep 2
done
echo "    Garage is up."

# --- 1. Cluster layout -------------------------------------------------------
if garage $H status | grep -q "NO ROLE ASSIGNED"; then
  NODE_ID=$(garage $H status | grep -oE '^[0-9a-f]{16,}' | head -n1)
  echo "==> Assigning layout to node $NODE_ID (capacity $CAPACITY)..."
  garage $H layout assign -z dc1 -c "$CAPACITY" "$NODE_ID"
  CUR=$(garage $H layout show 2>/dev/null | sed -n 's/.*layout version: *\([0-9]*\).*/\1/p' | head -n1)
  CUR=${CUR:-0}
  garage $H layout apply --version $((CUR + 1))
else
  echo "==> Layout already assigned, skipping."
fi

# --- 2. Bucket ---------------------------------------------------------------
if garage $H bucket info "$BUCKET" >/dev/null 2>&1; then
  echo "==> Bucket '$BUCKET' already exists, skipping."
else
  echo "==> Creating bucket '$BUCKET'..."
  garage $H bucket create "$BUCKET"
fi

# --- 3. S3 access key --------------------------------------------------------
if garage $H key info "$S3_ACCESS_KEY" >/dev/null 2>&1; then
  echo "==> Key already imported, skipping."
else
  echo "==> Importing S3 access key..."
  garage $H key import "$S3_ACCESS_KEY" "$S3_SECRET_KEY" -n contracts-app --yes
fi

# --- 4. Grant the key full access to the bucket ------------------------------
echo "==> Granting read/write/owner on '$BUCKET' to the key..."
garage $H bucket allow --read --write --owner "$BUCKET" --key "$S3_ACCESS_KEY"

echo "==> Garage init complete. Bucket '$BUCKET' is ready."
