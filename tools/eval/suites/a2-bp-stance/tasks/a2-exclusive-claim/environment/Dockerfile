FROM node:22-bookworm-slim@sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436

ARG CODEX_VERSION=0.146.0

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        ripgrep \
    && codex_arch="$(dpkg --print-architecture)" \
    && case "$codex_arch" in \
        arm64) codex_platform="linux-arm64" ;; \
        amd64) codex_platform="linux-x64" ;; \
        *) echo "Unsupported Codex architecture: $codex_arch" >&2; exit 1 ;; \
    esac \
    && npm install -g \
        "@openai/codex@${CODEX_VERSION}" \
        "@openai/codex-${codex_platform}@npm:@openai/codex@${CODEX_VERSION}-${codex_platform}" \
    && codex --version \
    && npm cache clean --force \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

