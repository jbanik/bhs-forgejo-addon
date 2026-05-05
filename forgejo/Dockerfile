ARG BUILD_FROM=ghcr.io/hassio-addons/base:15.0.9
# hadolint ignore=DL3006
FROM ${BUILD_FROM}

# hadolint ignore=DL3008,DL3018
RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      dcron \
      git \
      gnupg \
      jq \
      openssh-client \
      postgresql16 \
      postgresql16-client \
      postgresql16-contrib \
      su-exec \
      tini \
      tzdata

# Forgejo binary
ARG FORGEJO_VERSION=12.0.1
ARG TARGETARCH
# Map docker TARGETARCH to forgejo release arch: amd64 -> amd64, arm64 -> arm64, arm/v7 -> arm-6
# When BuildKit isn't passing TARGETARCH (local docker build), fall back to uname -m mapping.
RUN set -eux; \
    arch="${TARGETARCH:-$(uname -m)}"; \
    case "$arch" in \
      amd64|x86_64)   forgejo_arch=amd64 ;; \
      arm64|aarch64)  forgejo_arch=arm64 ;; \
      arm/v7|armv7l)  forgejo_arch=arm-6 ;; \
      *) echo "unsupported arch: $arch"; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/forgejo \
      "https://codeberg.org/forgejo/forgejo/releases/download/v${FORGEJO_VERSION}/forgejo-${FORGEJO_VERSION}-linux-${forgejo_arch}"; \
    chmod 0755 /usr/local/bin/forgejo; \
    /usr/local/bin/forgejo --version

# Create system users with stable UIDs
RUN addgroup -S -g 1000 git \
 && adduser -S -D -H -h /data/forgejo -s /bin/bash -G git -u 1000 git \
 && mkdir -p /data \
 && chmod 0755 /data

# Copy rootfs (s6 service definitions, init scripts, helper binaries) over container root
COPY rootfs/ /

# Make sure all shell scripts are executable
RUN find /etc/cont-init.d -type f -exec chmod 0755 {} \; \
 && find /etc/s6-overlay -type f \( -name run -o -name up -o -name finish \) -exec chmod 0755 {} \; \
 && find /usr/local/bin -type f -exec chmod 0755 {} \;
