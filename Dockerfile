# ---- Builder stage ----
FROM clux/muslrust:stable AS builder

WORKDIR /app

# Copy dependency manifests first (cargo caching layer)
COPY Cargo.toml Cargo.lock ./
COPY src/db/Cargo.toml src/db/
COPY src/util/Cargo.toml src/util/
COPY src/net/Cargo.toml src/net/
COPY src/rpc/Cargo.toml src/rpc/
COPY src/table/Cargo.toml src/table/
COPY src/block/Cargo.toml src/block/
COPY src/model/Cargo.toml src/model/
COPY src/api/common/Cargo.toml src/api/common/
COPY src/api/s3/Cargo.toml src/api/s3/
COPY src/api/k2v/Cargo.toml src/api/k2v/
COPY src/api/admin/Cargo.toml src/api/admin/
COPY src/web/Cargo.toml src/web/
COPY src/garage/Cargo.toml src/garage/
COPY src/k2v-client/Cargo.toml src/k2v-client/
COPY src/format-table/Cargo.toml src/format-table/

# Copy all source
COPY . .

# Build in release mode (static musl binary)
ENV CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=muslgcc
RUN cargo build --release --bin garage 2>&1

# ---- Final stage (scratch — minimal image) ----
FROM scratch

ENV RUST_BACKTRACE=1
ENV RUST_LOG=garage=info

COPY --from=builder /app/target/release/garage /garage

CMD ["/garage", "server"]
