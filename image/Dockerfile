# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
#
# CommonLayer base image.
#
# Stage "toolchain": Alpine (pinned by digest) with a compiler.
# Stage "probe":     builds and tests cl-probe (static).
# Stage "busybox":   rebuilds Alpine's BusyBox from Alpine's pinned source and
#                    patches with network clients and admin applets compiled out.
# Stage "rootfs":    installs a minimal package set into an empty root with
#                    `apk --root`; apk-tools itself is never installed there.
# Final:             FROM scratch + that root. Runs as 10001:10001.
#
# Build with scripts/build.sh (or scripts/docker-build.sh for proxy/CA support).

# Mirrors commonlayer.yaml versions[0]: the Alpine release and the digest of its
# official image index.
ARG UPSTREAM_VERSION=3.24.4
ARG UPSTREAM_SHA256=f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

FROM docker.io/library/alpine:${UPSTREAM_VERSION}@sha256:${UPSTREAM_SHA256} AS toolchain
RUN --mount=type=secret,id=extra_ca,target=/etc/ssl/certs/ca-certificates.crt,required=false \
    apk add --no-cache build-base linux-headers curl

FROM toolchain AS probe
WORKDIR /src/probe
COPY probe/ ./
RUN mkdir -p /out && make OUT=/out all test

FROM toolchain AS busybox
# Alpine aports commit (branch 3.24-stable) and the SHA-256 of busybox's
# APKBUILD at that commit; the APKBUILD's sha512sums pin the tarball and patches.
ARG APORTS_COMMIT=95ecd1043f781a308ae20a7aa08b86070806946f
ARG BUSYBOX_APKBUILD_SHA256=98f019f62291aff63cb798f046fb59dfd43340885de63ca2f127651fc21d0450
ARG BUSYBOX_VERSION=1.37.0
ARG BUSYBOX_PKGREL=31
COPY busybox/ /src/busybox/
RUN --mount=type=secret,id=extra_ca,target=/etc/ssl/certs/ca-certificates.crt,required=false \
    sh /src/busybox/build-busybox.sh

FROM docker.io/library/alpine:${UPSTREAM_VERSION}@sha256:${UPSTREAM_SHA256} AS rootfs
ARG BUSYBOX_VERSION=1.37.0
ARG BUSYBOX_PKGREL=31
ARG BASE_PACKAGES="musl busybox busybox-binsh ca-certificates-bundle tzdata alpine-release"
ARG SOURCE_DATE_EPOCH
COPY --from=busybox /out/busybox /out/LICENSE.busybox /in/
COPY --from=probe /out/cl-probe /in/cl-probe
COPY rootfs/ /src/rootfs/
COPY licenses/ /src/licenses/
COPY vex/ /src/vex/
COPY sbom/ /src/sbom/
COPY assemble-rootfs.sh /src/assemble-rootfs.sh
RUN --mount=type=secret,id=extra_ca,target=/etc/ssl/certs/ca-certificates.crt,required=false \
    sh /src/assemble-rootfs.sh

FROM scratch
ARG UPSTREAM_VERSION
ARG UPSTREAM_SHA256
ARG IMAGE_REVISION=0
ARG VCS_REF=unknown
ARG CREATED=1970-01-01T00:00:00Z
ARG SOURCE_REPOSITORY=https://github.com/envaro/commonlayer-base
COPY --from=rootfs /rootfs/ /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LABEL org.opencontainers.image.title="CommonLayer base" \
      org.opencontainers.image.description="Minimal non-root base root filesystem assembled from Alpine packages: musl, reduced BusyBox, CA certificates, tzdata, cl-probe. No package manager." \
      org.opencontainers.image.version="${UPSTREAM_VERSION}-r${IMAGE_REVISION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.source="${SOURCE_REPOSITORY}" \
      org.opencontainers.image.url="https://commonlayer.org/projects/base" \
      org.opencontainers.image.documentation="${SOURCE_REPOSITORY}" \
      org.opencontainers.image.licenses="Apache-2.0 AND GPL-2.0-only AND MIT AND MPL-2.0" \
      org.opencontainers.image.vendor="CommonLayer" \
      org.opencontainers.image.base.name="docker.io/library/alpine:${UPSTREAM_VERSION}" \
      org.opencontainers.image.base.digest="sha256:${UPSTREAM_SHA256}" \
      org.commonlayer.project="base" \
      org.commonlayer.variant="" \
      org.commonlayer.upstream.version="${UPSTREAM_VERSION}" \
      org.commonlayer.revision="${IMAGE_REVISION}" \
      org.commonlayer.standard="image-standard-v1"
USER 10001:10001
WORKDIR /app
CMD ["/bin/sh"]
