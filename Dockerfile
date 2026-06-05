# Garage server on Alpine so the entrypoint can self-bootstrap the cluster.
# (The official dxflrs/garage image is FROM scratch and has no shell.)
FROM dxflrs/garage:v2.0.0 AS bin

FROM alpine:3.20
COPY --from=bin /garage /usr/local/bin/garage
COPY garage.toml /etc/garage.toml
COPY server-init.sh /server-init.sh
RUN chmod +x /server-init.sh
ENTRYPOINT ["/bin/sh", "/server-init.sh"]
