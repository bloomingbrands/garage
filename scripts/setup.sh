#!/usr/bin/env bash
# Post-deployment setup script for Garage on Coolify
# Run this from the Coolify project root after the garage container is healthy.
# Based on: https://oneuptime.com/blog/post/2026-03-02-how-to-set-up-garage-s3-compatible-storage-on-ubuntu/view

set -e

CONTAINER="garage"
CONFIG="/etc/garage.toml"

echo "=========================================="
echo "  Garage Single-Node Cluster Setup"
echo "=========================================="
echo ""

# --- Verify container is running ---
if ! docker compose ps | grep -q "${CONTAINER}"; then
    echo "❌ Error: Garage container '${CONTAINER}' is not running."
    echo "   Start it first with: docker compose up -d"
    exit 1
fi

echo "✅ Garage container is running."
echo ""

# --- Step 1: Get node ID ---
echo "Step 1/6: Retrieving node ID..."
NODE_ID=$(docker compose exec -T "${CONTAINER}" /garage -c "${CONFIG}" node id)
echo "   Node ID: ${NODE_ID}"
echo ""

# --- Step 2: Assign layout ---
echo "Step 2/6: Assigning node layout (zone=dc1, capacity=100)..."
docker compose exec -T "${CONTAINER}" /garage -c "${CONFIG}" layout assign \
    "${NODE_ID}" --zone dc1 --capacity 100
echo ""

# --- Step 3: Apply layout ---
echo "Step 3/6: Applying layout..."
docker compose exec -T "${CONTAINER}" /garage -c "${CONFIG}" layout apply --version 1
echo ""

# --- Step 4: Check status ---
echo "Step 4/6: Checking cluster status..."
docker compose exec -T "${CONTAINER}" /garage -c "${CONFIG}" status
echo ""

# --- Step 5: Create bucket ---
read -rp "Step 5/6: Enter bucket name to create (or press Enter to skip): " BUCKET
if [[ -n "${BUCKET}" ]]; then
    docker compose exec -T "${CONTAINER}" /garage -c "${CONFIG}" bucket create "${BUCKET}"
    echo "   ✅ Bucket '${BUCKET}' created."
    echo ""

    # --- Step 6: Create key and grant permissions ---
    read -rp "Step 6/6: Enter key name to create (or press Enter to skip): " KEY
    if [[ -n "${KEY}" ]]; then
        echo "   Creating key '${KEY}'..."
        docker compose exec -T "${CONTAINER}" /garage -c "${CONFIG}" key create "${KEY}"
        echo ""

        echo "   Granting read+write on '${BUCKET}' to key '${KEY}'..."
        docker compose exec -T "${CONTAINER}" /garage -c "${CONFIG}" bucket allow \
            "${BUCKET}" --read --write --key "${KEY}"
        echo "   ✅ Permissions granted."
        echo ""
        echo "   🔑 Use the Access Key ID and Secret Access Key printed above"
        echo "      to configure your S3 client (awscli, rclone, MinIO client, etc.)."
    fi
fi

echo ""
echo "=========================================="
echo "  Setup complete!"
echo "=========================================="
echo ""
echo "S3 API endpoint: http://<your-server-ip>:${GARAGE_S3_PORT:-3901}"
echo "Admin API:       http://<your-server-ip>:${GARAGE_ADMIN_PORT:-3903}"
echo "S3 Web:          http://<your-server-ip>:${GARAGE_WEB_PORT:-3902}"
echo ""
