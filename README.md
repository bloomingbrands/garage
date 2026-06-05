# Garage S3-Compatible Storage — Coolify Deployment

> One-click-ready Docker Compose deployment of [Garage](https://garagehq.deuxfleurs.fr/) (lightweight, distributed S3-compatible object storage) for [Coolify](https://coolify.io/).
>
> Based on the guide: [How to Set Up Garage S3-Compatible Storage on Ubuntu](https://oneuptime.com/blog/post/2026-03-02-how-to-set-up-garage-s3-compatible-storage-on-ubuntu/view)

---

## What's inside

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Main Coolify service definition (official `dxflrs/garage:v1.0.1` image) |
| `garage.toml` | Garage server configuration (edit `rpc_secret` before first deploy) |
| `.env.example` | Environment variable template for port mapping and timezone |
| `scripts/setup.sh` | Post-deploy helper that runs the 6 init steps from the article |

---

## Prerequisites

- Ubuntu 22.04/24.04 server (or any Linux host with Docker)
- At least **1 GB RAM** (2 GB+ recommended)
- Ports **3900–3903** free on the host (or edit `.env`)
- A block/volume mounted for persistent data (Coolify handles this via named volumes)

---

## 1. First deploy on Coolify

1. **Push this repo to GitHub** and create a new project in Coolify.
2. In Coolify UI → **Environment Variables**, paste the contents of `.env.example` and adjust ports if needed.
3. **Before first deploy**, edit `garage.toml` and replace:
   ```toml
   rpc_secret = "REPLACE_WITH_OPENSSL_RAND_HEX_32"
   ```
   with a real secret:
   ```bash
   openssl rand -hex 32
   ```
4. Click **Deploy**. Coolify will run `docker compose up -d`.

---

## 2. Initialize the cluster (single-node)

After the container is healthy, SSH into the Coolify server (or use Coolify's built-in terminal) and run:

```bash
cd /data/coolify/services/<your-garage-uuid>
chmod +x scripts/setup.sh
./scripts/setup.sh
```

The script automates the article's **Steps 5 & 6**:
1. Retrieves the node ID
2. Assigns layout (`zone=dc1`, `capacity=100`)
3. Applies layout version 1
4. Checks cluster status
5. Creates a bucket
6. Creates an access key and grants read+write permissions

> **Important:** Save the **Access Key ID** and **Secret Access Key** printed during key creation — they are shown only once.

---

## 3. Connect with AWS CLI

Install `awscli` locally or on the server:

```bash
aws configure set aws_access_key_id     <YOUR_KEY_ID>
aws configure set aws_secret_access_key <YOUR_SECRET_KEY>
aws configure set default.region        us-east-1
```

List buckets:

```bash
aws s3 ls --endpoint-url http://<your-server-ip>:3901
```

Upload a test file:

```bash
aws s3 cp /etc/hostname s3://my-bucket/hostname.txt --endpoint-url http://<your-server-ip>:3901
```

---

## 4. Connect with rclone

```bash
rclone config create garage s3 \
  provider Other \
  access_key_id <YOUR_KEY_ID> \
  secret_access_key <YOUR_SECRET_KEY> \
  endpoint http://<your-server-ip>:3901 \
  acl private
```

Sync a local directory:

```bash
rclone sync /var/backups garage:my-bucket/backups/
```

---

## 5. Ports reference

| Port | Service | Typical exposure |
|------|---------|----------------|
| 3900 | RPC (node-to-node) | Internal / VPN only |
| 3901 | S3 API | Internal / VPN only (or reverse-proxy for HTTPS) |
| 3902 | S3 Web (static sites) | Public if hosting websites |
| 3903 | Admin API | Internal / VPN only |

For public S3 access, put a reverse proxy (Nginx / Traefik) in front of **3901** and terminate TLS there. If you use Coolify's built-in Traefik, uncomment the labels in `docker-compose.yml`.

---

## 6. Monitoring

Garage exposes Prometheus metrics at `http://<host>:3903/metrics`. Point your monitoring stack (Grafana, OneUptime, Uptime-Kuma, etc.) to that endpoint.

---

## 7. Upgrading Garage

1. Check the [release page](https://garagehq.deuxfleurs.fr) for the latest version.
2. Update the image tag in `docker-compose.yml`:
   ```yaml
   image: dxflrs/garage:vX.Y.Z
   ```
3. Redeploy via Coolify.

---

## License

Garage is released under the AGPL-3.0 license. This deployment wrapper is provided as-is for self-hosting convenience.
