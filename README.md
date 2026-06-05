# Garage Object Storage for Blooming Brands

A self-contained, single-node [Garage](https://garagehq.deuxfleurs.fr/) S3-compatible
object store, ready to deploy on **Coolify** from this repo. The Blooming Brands app
connects to it over the S3 API to store contracts, documents, and invoices.

## What's in here

| File                 | Purpose                                                                     |
|----------------------|-----------------------------------------------------------------------------|
| `docker-compose.yaml`| Garage server (self-bootstrapping) + `garage-webui` admin UI + volumes.      |
| `garage.toml`        | Garage configuration (secrets come from env vars, not this file).           |
| `Dockerfile.garage`  | Garage v2.0.0 on Alpine, config baked in, self-bootstrapping entrypoint.     |
| `Dockerfile.webui`   | `garage-webui` image with `garage.toml` baked in.                           |
| `server-init.sh`     | Entrypoint: starts the server, then idempotently creates the layout,        |
|                      | bucket and S3 key using the local CLI, then keeps the server running.       |
| `.env.example`       | Template for the required secrets/credentials.                              |

> The config is **baked into each image** at build time rather than bind-mounted,
> because Coolify does not reliably expose repo files as host bind mounts at runtime
> (a bind mount to a missing file silently becomes an empty directory).

## Deploy on Coolify

1. **New Resource → Docker Compose**, point it at this repository.
2. In the resource's **Environment Variables**, add the keys from `.env.example`
   with **freshly generated** production values:
   - `GARAGE_RPC_SECRET`  — `openssl rand -hex 32`
   - `GARAGE_ADMIN_TOKEN` — `openssl rand -base64 32`
   - `S3_ACCESS_KEY`      — `GK` + `openssl rand -hex 12`
   - `S3_SECRET_KEY`      — `openssl rand -hex 32`
   - `BUCKET_NAME`        — `blooming-brands`
   - `CAPACITY`           — `50G`
   - `AUTH_USER_PASS`     — `username:bcrypt-hash` for the admin UI login
3. Deploy. The `garage` container starts, self-bootstraps and keeps running
   alongside `garage-webui`.
4. In Coolify, assign domains:
   - **`garage-webui` service → port 3909** → e.g. `garage.blooming-brands.com`
   - The S3 API (`garage:3900`) stays internal unless you also expose it

### Connecting your app (same Coolify server)

Your app and this stack are separate Coolify resources. Enable **"Connect to Predefined
Network"** on *both* the app resource and this Garage resource, then use:

```
S3 Endpoint:    http://garage:3900        (internal, same network)
                https://s3.blooming-brands.com  (if you expose it)
Region:         garage
Access key ID:  <S3_ACCESS_KEY>
Secret key:     <S3_SECRET_KEY>
Bucket:         blooming-brands
Force path style: true   <-- important for Garage
```

## Ports & what's exposed

| Service          | Port | Exposure                    | Used by                         |
|------------------|------|-----------------------------|---------------------------------|
| `garage` S3      | 3900 | internal only               | your app (`http://garage:3900`) |
| `garage` RPC     | 3901 | internal only               | cluster communication            |
| `garage` Web     | 3902 | internal only               | static website hosting           |
| `garage` Admin   | 3903 | internal only               | `garage-webui`                   |
| `garage-webui`   | 3909 | **public** (behind login)   | you, from a browser              |

> Only `garage-webui` gets a public domain, and it requires a username/password
> (`AUTH_USER_PASS`). The S3 API and admin API are never published to the internet.

## Notes & operations

- **Persistence:** data lives in `garage_data` / `garage_meta` Docker volumes,
  so it survives redeploys. Back these up.
- **Single node = `replication_factor = 1`:** one copy of each object. Fine for a
  standalone deploy; ensure the underlying disk is backed up.
- **Self-bootstrapping:** `server-init.sh` runs on every container start. It's
  idempotent — safe to redeploy without losing data.
- **Pinned version:** `dxflrs/garage:v2.0.0`.