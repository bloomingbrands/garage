# Garage Object Storage — Coolify deployment

A self-contained, single-node [Garage](https://garagehq.deuxfleurs.fr/)
S3-compatible object store **plus** the [garage-webui](https://github.com/khairul169/garage-webui)
admin UI, built **from source** and shipped as **one Coolify Application**.

- **Garage v2.3.0**, compiled from the `garage/` source tree in this repo.
- **garage-webui**, compiled from the `garage-webui/` source tree in this repo.
- Both run in a single container managed by `supervisord`.
- Self-bootstrapping: on first boot it creates the cluster layout, a bucket and
  an S3 key. Idempotent — safe to redeploy without data loss.

## Repository layout

| Path                | Purpose                                                              |
|---------------------|---------------------------------------------------------------------|
| `Dockerfile`        | 4-stage build: Garage (Rust) → web UI (pnpm) → backend (Go) → runtime |
| `garage/`           | Vendored Garage source (lean: `Cargo.*` + `src/`)                   |
| `garage-webui/`     | Web UI source (frontend + Go backend)                               |
| `garage.toml`       | Config template; secrets/domains are injected at startup             |
| `server-init.sh`    | Entrypoint: injects config, starts server, bootstraps the cluster   |
| `webui-run.sh`      | Launches the web UI against the local APIs                          |
| `supervisord.conf`  | Runs `garage` + `garage-webui` together                            |
| `.env.example`      | All environment variables you need to set in Coolify               |

## Ports

| Port | Service        | Purpose                                  |
|------|----------------|------------------------------------------|
| 3900 | S3 API         | object storage API for your apps         |
| 3901 | RPC            | internal cluster RPC (keep private)      |
| 3902 | Web            | static website hosting from buckets      |
| 3903 | Admin          | admin API **and** Prometheus `/metrics`  |
| 3909 | Web UI         | browser admin/management UI (has login)  |

## Deploy on Coolify

1. **Titan01 → Production → + New → Application → Public/Private Repository**,
   point it at this repo (`bloomingbrands/garage`).
2. **Build Pack: `Dockerfile`** (Coolify uses the root `Dockerfile`).
   - First build compiles Garage from source — expect **~15–30 min**. Later
     builds are fast thanks to the BuildKit cache mounts.
3. **Environment Variables** — add everything from `.env.example` with real
   production values. Generate secrets:
   ```bash
   openssl rand -hex 32     # GARAGE_RPC_SECRET, S3_SECRET_KEY
   openssl rand -base64 32  # GARAGE_ADMIN_TOKEN, GARAGE_METRICS_TOKEN
   echo "GK$(openssl rand -hex 12)"            # S3_ACCESS_KEY
   htpasswd -nbB admin 'your-ui-password'      # AUTH_USER_PASS (user:bcrypt)
   ```
   Keep `CAPACITY=20G` (the deployment cap).
4. **Persistent storage** — add two volumes so data survives redeploys:
   - `/var/lib/garage/meta`
   - `/var/lib/garage/data`
5. **Ports & Domains** — set **Ports Exposes** to `3900,3902,3903,3909`, then map
   a domain to each port in the Domains field (one per line, `:port` suffix):
   ```
   https://garage.blooming-brands.com:3909   # Web UI (management)
   https://s3.blooming-brands.com:3900       # S3 API
   https://media.blooming-brands.com:3902     # static web hosting
   https://admin.blooming-brands.com:3903     # admin API + /metrics
   ```
   Set the matching `S3_DOMAIN` / `WEB_DOMAIN` env vars (host only, no scheme)
   so Garage's vhost-style routing matches your domains.
6. **Deploy.**

## Configuration — everything is an environment variable

Garage's entire `garage.toml` is **generated at container start from environment
variables** by `server-init.sh`, so an admin can change any setting from the
Coolify UI without editing files or rebuilding. See **`.env.example`** for the
complete, annotated list. Highlights:

- **Secrets** (`GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN`, `GARAGE_METRICS_TOKEN`)
  are read by Garage **natively from the environment** and are never written to
  disk.
- **Domains** (`S3_DOMAIN`, `WEB_DOMAIN`) are host-only and auto-normalized — a
  full `https://host:port` is accepted and reduced to the host.
- **Required with defaults:** `BUCKET_NAME`/`S3_BUCKET`, `CAPACITY`, `ZONE`,
  `S3_REGION`, `GARAGE_DB_ENGINE`, `GARAGE_REPLICATION_FACTOR`, the bind addrs.
- **Opt-in (Garage default applies if unset):** fsync, scrubbing, metadata
  snapshots, compression level, block sizing, LMDB map size, consistency mode,
  bootstrap peers / replication factor (multi-node), K2V, punycode, and more.

Changing a value and redeploying (or restarting the container) regenerates the
config — data in the volumes is untouched.

> **DNS:** for vhost-style S3 (`bucket.s3.blooming-brands.com`) and static web
> hosting, add wildcard records `*.s3...` and `*.media/web...`. Path-style S3
> (`s3.blooming-brands.com/<bucket>`) works without wildcards — see below.

## Connecting an app (same Coolify server)

Enable **"Connect to Predefined Network"** on both this Application and your app,
then point your S3 client at the internal address:

```
S3 Endpoint:       http://<garage-container>:3900   (internal) or https://s3.blooming-brands.com
Region:            Germany-1
Access key ID:     <S3_ACCESS_KEY>
Secret key:        <S3_SECRET_KEY>
Bucket:            <BUCKET_NAME>
Force path style:  true     # required for Garage
```

## Operations

- **Persistence:** lives in the `meta` / `data` volumes — back them up.
- **Single node:** `replication_factor = 1` (one copy per object). Fine for a
  standalone host; the underlying disk is your durability boundary.
- **Metrics:** scrape `https://admin.../metrics` with
  `Authorization: Bearer <GARAGE_METRICS_TOKEN>`.
- **Self-bootstrap:** `server-init.sh` runs every boot and is idempotent.
- **DB engine:** `lmdb` (Garage's recommended default).
- **Versions:** Garage = vendored `garage/` source (v2.3.0); web UI = vendored
  `garage-webui/` source.

## Updating Garage

Re-vendor the source from your Garage checkout and bump `GIT_VERSION` in the
`Dockerfile`. Keep `Cargo.toml`/`Cargo.lock` and the `fuzz/` member in sync so
the `cargo build --locked` step stays reproducible:

```bash
cp ../garage/Cargo.toml ../garage/Cargo.lock ./garage/
rsync -a --exclude target ../garage/src/  ./garage/src/
rsync -a --exclude target ../garage/fuzz/ ./garage/fuzz/
```

## Backups (required at RF=1)

With `replication_factor = 1` the meta/data volumes are the only copy of every
object — including customer contracts stored by blooming-brands. Use
`backup.sh` to take a consistent snapshot (it runs `garage meta snapshot` for
LMDB consistency, then tars meta + data):

```bash
# on the docker host, e.g. daily at 03:17 UTC
17 3 * * * CONTAINER=garage BACKUP_DIR=/var/backups/garage /opt/garage-deploy/backup.sh
```

Then ship `BACKUP_DIR` off the machine (restic/rclone/rsync to another host or
S3 provider). A backup on the same disk is not a backup. Do a test restore
(stop container → extract tarball over the volumes → start) at least once.
