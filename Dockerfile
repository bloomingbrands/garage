# ---- Stage 1: Garage v2.0.0 binary ----
FROM dxflrs/garage:v2.0.0 AS garage-bin

# ---- Stage 2: garage-webui (Node frontend + Go backend) ----
FROM node:20-slim AS webui-build
WORKDIR /app
RUN npm install -g corepack@latest && corepack use pnpm@latest
COPY garage-webui/package.json garage-webui/pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --frozen-lockfile || pnpm install
COPY garage-webui/ .
RUN pnpm run build

FROM golang:1.23 AS webui-backend
WORKDIR /app
COPY garage-webui/backend/go.mod garage-webui/backend/go.sum ./
RUN go mod download
COPY garage-webui/backend/ .
COPY --from=webui-build /app/dist ./ui/dist
RUN make

# ---- Stage 3: Final image — Garage + WebUI in one container ----
FROM alpine:3.20

RUN apk add --no-cache python3 py3-pip ca-certificates curl && \
    pip3 install --break-system-packages supervisor && \
    rm -rf /var/cache/apk/* /root/.cache/pip

COPY --from=garage-bin /garage /usr/local/bin/garage
COPY --from=webui-backend /app/main /usr/local/bin/garage-webui
COPY garage.toml /etc/garage.toml
COPY server-init.sh /server-init.sh
RUN chmod +x /server-init.sh
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

EXPOSE 3900 3901 3902 3903 3909

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=30s \
    CMD curl -f http://127.0.0.1:3909/ || exit 1

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]