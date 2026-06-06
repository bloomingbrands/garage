# =============================================================================
# Garage (built from source, v2.3.0) + garage-webui, in one container.
# Designed to deploy on Coolify as a single Application (Dockerfile build pack).
#
#   Stage 1  garage-build   compile the Garage binary from ./garage (Rust)
#   Stage 2  webui-frontend build the React UI (pnpm)
#   Stage 3  webui-backend  build the Go backend, embedding the UI
#   Stage 4  runtime        Debian slim (glibc) running both via supervisord
#
# NOTE: the runtime base must be glibc-based (debian-slim), because the Garage
# binary is compiled against glibc here. Copying it into Alpine (musl) would
# produce a binary that cannot start.
# =============================================================================

# ---- Stage 1: build Garage from source --------------------------------------
FROM rust:1-bookworm AS garage-build
WORKDIR /src

# Native toolchain for the bundled C deps (sqlite, lmdb, libsodium, zstd, ring).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential clang libclang-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Stamp the reported version (otherwise it falls back to "unknown").
ENV GIT_VERSION=v2.3.0

COPY garage/ .

# Build only the garage binary (default features: bundled-libs, metrics, lmdb,
# sqlite, k2v). Cache mounts keep redeploys fast when BuildKit is enabled.
RUN --mount=type=cache,id=garage-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=garage-cargo-target,target=/src/target \
    cargo build --release --locked -p garage \
    && cp target/release/garage /garage

# ---- Stage 2: build the web UI frontend -------------------------------------
# Node 22+ is required by pnpm 11 (it uses the node:sqlite builtin).
FROM node:22-slim AS webui-frontend
WORKDIR /app
RUN npm install -g corepack@latest && corepack enable
# pnpm-workspace.yaml carries the build-script allowlist (allowBuilds) and must
# be present at install time, or esbuild/@swc native binaries won't be built.
COPY garage-webui/package.json garage-webui/pnpm-lock.yaml garage-webui/pnpm-workspace.yaml ./
RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    corepack pnpm install --frozen-lockfile
COPY garage-webui/ .
RUN corepack pnpm run build

# ---- Stage 3: build the web UI backend (embeds the frontend) ----------------
FROM golang:1.24-bookworm AS webui-backend
WORKDIR /app
COPY garage-webui/backend/go.mod garage-webui/backend/go.sum ./
RUN go mod download
COPY garage-webui/backend/ .
COPY --from=webui-frontend /app/dist ./ui/dist
RUN make   # CGO_ENABLED=0 -> static binary, runs on any base

# ---- Stage 4: runtime -------------------------------------------------------
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        supervisor ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=garage-build   /garage              /usr/local/bin/garage
COPY --from=webui-backend  /app/main            /usr/local/bin/garage-webui

COPY garage.toml        /etc/garage.toml
COPY server-init.sh     /server-init.sh
COPY webui-run.sh       /webui-run.sh
COPY supervisord.conf   /etc/supervisor/conf.d/garage.conf
RUN chmod +x /server-init.sh /webui-run.sh

# S3 API | RPC | Web (static) | Admin API/metrics | Web UI
EXPOSE 3900 3901 3902 3903 3909

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=60s \
    CMD curl -fsS http://127.0.0.1:3909/ >/dev/null && garage status >/dev/null || exit 1

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/garage.conf"]
