# Garage S3-Compatible Storage — Coolify Dockerfile

> Single-container Dockerfile deployment of [Garage](https://garagehq.deuxfleurs.fr/) for [Coolify](https://coolify.io/).
> The container **self-bootstraps** on first run: it initializes the cluster layout,
> creates your bucket, and generates access keys automatically.
>
> Based on: [How to Set Up Garage S3-Compatible Storage on Ubuntu](https://oneuptime.com/blog/post/2026-03-02-how-to-set-up-garage-s3-compatible-storage-on-ubuntu/view)

---

## The Problem with Coolify's 1-Click Garage

Coolify's app-store template pulls `dxflrs/garage`, exposes ports, and mounts a volume.
**But it does NOT run the required post-start initialization:**

- `garage node id` → get node ID
- `garage layout assign` → assign zone + capacity
- `garage layout apply` → commit the layout
- `garage bucket create` → create a bucket
- `garage key create` → create access credentials

Without these steps, the cluster has **zero capacity** and the S3 API rejects requests. That's "half-provisioned."

**Why this happens:** The official Garage image is built `FROM scratch` (no shell). So Coolify's template can't run any init script inside the container.

**Our fix:** This repo builds a custom image based on Alpine that contains the official static binary PLUS an entrypoint script that handles all initialization automatically.

---

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage build: copies official binary into Alpine + entrypoint |
| `scripts/entrypoint.sh` | Generates config, bootstraps cluster on first boot, starts server |
| `.env.example` | All environment variables (copy into Coolify UI) |
| `garage.toml` | Reference template showing what the entrypoint generates |

---

## Quick Deploy on Coolify

### 1. Fork / clone this repo

Push to your own GitHub account.

### 2. Generate the RPC secret

```bash
openssl rand -hex 32
```

Copy the output. You'll paste it into Coolify in the next step.

### 3. Create Coolify Resource

1. In Coolify dashboard → **Projects** → **Add New**
2. Choose **Application** (not "Service" or "Docker Compose")
3. Source: your GitHub repo
4. Build type: **Dockerfile** (Coolify auto-detects `Dockerfile` in root)
5. Click **Deploy**

### 4. Set Environment Variables

In the Coolify UI for this resource, go to **Environment Variables** and paste the contents of `.env.example`. Then fill in the required values:

| Variable | Value | Required? |
|----------|-------|-----------|
| `GARAGE_RPC_SECRET` | `openssl rand -hex 32` | **YES** |
| `GARAGE_INIT_BUCKET` | `prod-bucket` | Optional |
| `GARAGE_INIT_KEY` | `prod-key` | Optional |
| `GARAGE_WEB_ROOT_DOMAIN` | `.web.yourdomain.com` | Optional |
| `TZ` | `UTC` | Recommended |

Leave `SERVICE_FQDN_*` empty — Coolify auto-populates them if you assign domains.

### 5. Re-deploy

Coolify rebuilds the image with your env vars baked into the startup. On first boot you will see initialization logs in Coolify's container logs. After that, the container restarts cleanly into the foreground server.

---

## First-Boot Logs (what you should see)

```
First boot detected. Starting server for initialization...
Waiting for Garage to be ready...
Garage is ready.

==========================================
  Initializing Garage Single-Node Cluster
==========================================

→ Retrieving node ID...
   Node ID: <hex-id>
→ Assigning layout (zone=dc1, capacity=100)...
→ Applying layout...
→ Cluster status:
→ Creating bucket 'prod-bucket'...
→ Creating access key 'prod-key'...
→ Granting read+write on 'prod-bucket' to key 'prod-key'...

✅ Initialization complete.

Restarting Garage in foreground...
```

**Important:** The access key ID and secret key are printed **only once** during the `key create` step. Save them from the Coolify logs — you will need them to connect S3 clients.

If you miss them, you can create a new key later:
```bash
docker exec <garage-container> /usr/local/bin/garage -c /etc/garage.toml key create another-key
```

---

## Ports

| Port | Service | Typical Exposure |
|------|---------|------------------|
| 3900 | RPC (node-to-node) | Internal only |
| 3901 | S3 API | Internal / VPN / Reverse-proxy |
| 3902 | S3 Web (static sites) | Public (if hosting websites) |
| 3903 | Admin API + Prometheus `/metrics` | Internal / VPN / Reverse-proxy |

In Coolify you can assign domains to ports 3901/3902/3903 via the **Domains** tab and Traefik will proxy them with HTTPS.

---

## Connect with AWS CLI

```bash
aws configure set aws_access_key_id     <YOUR_KEY_ID>
aws configure set aws_secret_access_key <YOUR_SECRET_KEY>
aws configure set default.region        us-east-1
```

List buckets:
```bash
aws s3 ls --endpoint-url https://s3.yourdomain.com
```

Upload:
```bash
aws s3 cp ./file.txt s3://prod-bucket/file.txt --endpoint-url https://s3.yourdomain.com
```

---

## Connect with rclone

```bash
rclone config create garage s3 \
  provider Other \
  access_key_id <YOUR_KEY_ID> \
  secret_access_key <YOUR_SECRET_KEY> \
  endpoint https://s3.yourdomain.com \
  acl private
```

Sync:
```bash
rclone sync /local/backups garage:prod-bucket/backups/
```

---

## Monitoring

Garage exposes Prometheus metrics at:
```
https://admin.yourdomain.com/metrics
```

If you need basic-auth in front of it, add an Nginx sidecar or use Coolify's Traefik middleware. The env vars `GARAGE_ADMIN_TOKEN` and `GARAGE_METRICS_TOKEN` are documented placeholders for your reverse-proxy config.

---

## Upgrading Garage

1. Check [releases](https://garagehq.deuxfleurs.fr) for latest version.
2. Edit `Dockerfile`:
   ```dockerfile
   FROM dxflrs/garage:vX.Y.Z AS garage-binary
   ```
3. Push to GitHub. Coolify auto-redeploys.

---

## License

Garage is AGPL-3.0. This deployment wrapper is provided as-is.
