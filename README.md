# Standalone Garage object storage (for customer contracts)

A self-contained, single-node [Garage](https://garagehq.deuxfleurs.fr/) S3-compatible
object store, ready to deploy on **Coolify** from this repo. Your app connects to it
over the S3 API to store contract documents.

## What's in here

| File                 | Purpose                                                                   |
|----------------------|---------------------------------------------------------------------------|
| `docker-compose.yaml` | Garage server (self-bootstrapping) + `garage-webui` admin UI + volumes.   |
| `garage.toml`        | Garage configuration (secrets come from env vars, not this file).         |
| `Dockerfile.garage`  | Garage server on Alpine, config baked in, self-bootstrapping entrypoint.   |
| `Dockerfile.webui`   | `garage-webui` image with `garage.toml` baked in.                         |
| `server-init.sh`     | Entrypoint: starts the server, then idempotently creates the layout,      |
|                      | bucket and S3 key using the local CLI, then keeps the server running.     |
| `.env.example`       | Template for the required secrets/credentials.                            |

> The config is **baked into each image** at build time rather than bind-mounted,
> because Coolify does not reliably expose repo files as host bind mounts at runtime
> (a bind mount to a missing file silently becomes an empty directory).

## Ports & what's exposed

Garage has **no native graphical UI** — only the S3 API, a REST admin API, and a CLI.
The browser admin panel here is the third-party **`garage-webui`**.

| Service        | Port | Exposure                          | Used by                          |
|----------------|------|-----------------------------------|----------------------------------|
| `garage` S3    | 3900 | **internal only**                 | your app (`http://garage:3900`)  |
| `garage` admin | 3903 | **internal only**                 | `garage-webui`                   |
| `garage-webui` | 3909 | **public** (behind login)         | you, from a browser              |

> The S3 API and raw admin API are never published to the host or the internet.
> Only `garage-webui` gets a public domain, and it requires a username/password
> (`AUTH_USER_PASS`).

## Deploy on Coolify

1. **New Resource → Docker Compose**, point it at this repository.
2. In the resource's **Environment Variables**, add the keys from `.env.example`
   with **freshly generated** production values:
   - `GARAGE_RPC_SECRET`  — `openssl rand -hex 32`
   - `GARAGE_ADMIN_TOKEN` — `openssl rand -hex 32`
   - `S3_ACCESS_KEY`      — `GK` + `openssl rand -hex 12`
   - `S3_SECRET_KEY`      — `openssl rand -hex 32`
   - `BUCKET_NAME`        — e.g. `contracts`
   - `CAPACITY`           — e.g. `10G` (must be ≤ the disk Coolify gives the volume)
   - `AUTH_USER_PASS`         — `username:bcrypt-hash` for the admin UI login
3. Deploy. The `garage` container starts, self-bootstraps (you'll see
   `Garage init complete. Bucket 'contracts' is ready.` in its logs) and keeps
   running alongside `garage-webui`.
4. In Coolify, assign a **public domain to the `garage-webui` service → port 3909**.
   Open it, log in with your `AUTH_USER_PASS` credentials, and you can manage buckets,
   keys and layout from the browser.

### Connecting your app (same Coolify server)

Your app and this stack are separate Coolify resources, so they are **not** on the
same Docker network by default. Do one of the following so the app can resolve
`http://garage:3900`:

- **Recommended:** in Coolify, enable **"Connect to Predefined Network"** on *both*
  the app resource and this Garage resource, then use `http://garage:3900`.
- Or move the app's service into this same `docker-compose.yaml` (one resource, one
  network) — then `http://garage:3900` works with no extra config.

## How your app connects

Use any S3 SDK with these settings:

```
Endpoint:          http://garage:3900        (same Coolify network)
                   https://<your-domain>     (if exposed via the proxy)
Region:            garage
Access key ID:     <S3_ACCESS_KEY>
Secret access key: <S3_SECRET_KEY>
Bucket:            contracts
Force path style:  true   <-- important for Garage
```

Example (Node.js, AWS SDK v3):

```js
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";

const s3 = new S3Client({
  endpoint: process.env.S3_ENDPOINT,   // e.g. http://garage:3900
  region: "garage",
  forcePathStyle: true,
  credentials: {
    accessKeyId: process.env.S3_ACCESS_KEY,
    secretAccessKey: process.env.S3_SECRET_KEY,
  },
});

await s3.send(new PutObjectCommand({
  Bucket: "contracts",
  Key: `customers/${customerId}/${contractId}.pdf`,
  Body: pdfBuffer,
  ContentType: "application/pdf",
}));
```

## Notes & operations

- **Persistence:** data lives in the `garage_data` / `garage_meta` Docker volumes,
  so it survives redeploys. Back these up.
- **Single node = `replication_factor = 1`:** one copy of each object. Fine for a
  standalone deploy; ensure the underlying disk is backed up.
- **Manual admin** (from the host running the stack):
  ```sh
  docker compose exec garage /garage status
  docker compose exec garage /garage bucket list
  docker compose exec garage /garage key list
  ```
- **Pinned version:** `dxflrs/garage:v1.1.0`. Bump in `docker-compose.yaml` and
  `Dockerfile.init` together when upgrading.
