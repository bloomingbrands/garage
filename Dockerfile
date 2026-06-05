# =============================================================================
# Garage S3-Compatible Storage — Coolify Dockerfile
# =============================================================================
# We copy the official static binary (scratch-based, no shell) into Alpine
# so we can run an entrypoint script that handles cluster initialization.
#
# Official image: https://hub.docker.com/r/dxflrs/garage
# Source Dockerfile: https://git.deuxfleurs.fr/networkException/garage/src/branch/main/Dockerfile
# =============================================================================

# --- Stage 1: Grab the official static binary ---
FROM dxflrs/garage:v1.0.1 AS garage-binary

# --- Stage 2: Alpine runtime with shell + init script ---
FROM alpine:3.19

RUN apk add --no-cache ca-certificates

# Copy the official statically-linked binary
COPY --from=garage-binary /garage /usr/local/bin/garage
RUN chmod +x /usr/local/bin/garage

# Copy entrypoint that generates config and bootstraps the cluster
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Create unprivileged user (matches upstream recommendation)
RUN adduser -D -s /bin/sh garage

# Data directories (named volumes will mount here)
RUN mkdir -p /var/lib/garage/meta /var/lib/garage/data \
    && chown -R garage:garage /var/lib/garage

USER garage

EXPOSE 3900 3901 3902 3903

ENTRYPOINT ["/entrypoint.sh"]
