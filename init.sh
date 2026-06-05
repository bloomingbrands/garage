#!/bin/sh
# Idempotent bootstrap for a single-node Garage cluster.
# Safe to run on every deploy: each step is skipped if already done.
set -u

H="garage:3901"
GARAGE="garage -h $H"
BUCKET="${BUCKET_NAME:-contracts}"
CAPACITY="${CAPACITY:-10G}"

echo "==> Waiting for Garage RPC at $H ..."
i=0
while true; do
  if OUT=$($GARAGE status 2>&1); then
    echo "    Garage is up."
    break
  fi
  i=$((i + 1))
  if [ $((i % 5)) -eq 0 ]; then
    echo "    still waiting (attempt $i); last error:"
    echo "$OUT" | sed 's/^/      /'
  fi
  if [ "$i" -ge 90 ]; then
    echo "ERROR: gave up waiting for Garage RPC. Last error:"
    echo "$OUT"
    exit 1
  fi
  sleep 2
done

# --- 1. Cluster layout -------------------------------------------------------
if $GARAGE status | grep -q "NO ROLE ASSIGNED"; then
  NODE_ID=$($GARAGE status | grep -oE '^[0-9a-f]{16,}' | head -n1)
  echo "==> Assigning layout to node $NODE_ID (capacity $CAPACITY)..."
  $GARAGE layout assign -z dc1 -c "$CAPACITY" "$NODE_ID"
  CUR=$($GARAGE layout show 2>/dev/null | sed -n 's/.*layout version: *\([0-9]*\).*/\1/p' | head -n1)
  CUR=${CUR:-0}
  $GARAGE layout apply --version $((CUR + 1))
else
  echo "==> Layout already assigned, skipping."
fi

# --- 2. Bucket ---------------------------------------------------------------
if $GARAGE bucket info "$BUCKET" >/dev/null 2>&1; then
  echo "==> Bucket '$BUCKET' already exists, skipping."
else
  echo "==> Creating bucket '$BUCKET'..."
  $GARAGE bucket create "$BUCKET"
fi

# --- 3. S3 access key --------------------------------------------------------
if $GARAGE key info "$S3_ACCESS_KEY" >/dev/null 2>&1; then
  echo "==> Key already imported, skipping."
else
  echo "==> Importing S3 access key..."
  $GARAGE key import "$S3_ACCESS_KEY" "$S3_SECRET_KEY" -n contracts-app --yes
fi

# --- 4. Grant the key full access to the bucket ------------------------------
echo "==> Granting read/write/owner on '$BUCKET' to the key..."
$GARAGE bucket allow --read --write --owner "$BUCKET" --key "$S3_ACCESS_KEY"

echo "==> Garage init complete. Bucket '$BUCKET' is ready."
