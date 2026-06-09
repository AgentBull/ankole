# syntax=docker/dockerfile:1
# Build the bullx-computerd daemon, then ship it on a slim image with bubblewrap.
# Build context is the package root (packages/computer).

FROM rust:1-bookworm AS builder
# aws-lc-rs (via jsonwebtoken / rustls) needs cmake + a C toolchain.
RUN apt-get update \
  && apt-get install -y --no-install-recommends cmake \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --bin bullx-computerd

FROM python:3.12-slim-bookworm
COPY --from=ghcr.io/astral-sh/uv:0.11.19 /uv /uvx /usr/local/bin/
COPY --from=oven/bun:1.3.14 /usr/local/bin/bun /usr/local/bin/bun
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    aria2 \
    bash \
    bubblewrap \
    ca-certificates \
    coreutils \
    curl \
    fonts-liberation \
    git \
    grep \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-glib-1-2 \
    libgbm1 \
    jq \
    libgl1 \
    libglib2.0-0 \
    libgomp1 \
    libgtk-3-0 \
    libnss3 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libx11-xcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libxss1 \
    libxt6 \
    tmux \
    unzip \
    xvfb \
    xz-utils \
    zstd \
  && rm -rf /var/lib/apt/lists/*
ENV UV_SYSTEM_PYTHON=1 \
    UV_TOOL_DIR=/usr/local/share/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin
RUN uv pip install --system \
    duckdb \
    pandas \
    numpy \
    matplotlib \
    polars \
    clickhouse-connect \
    python-dotenv \
    pyarrow \
    pydantic \
    exchange-calendars \
    numexpr \
    scipy \
    matplotlib-inline \
    opencv-python \
    pillow \
    imageio \
    openpyxl \
    PyPDF2 \
    python-docx \
    python-pptx \
    requests \
    jupyterlab \
    ipykernel \
    jupyter-client \
    jupyter-server \
    nbformat \
    websocket-client \
    "camoufox[geoip]" \
  && python - <<'PY'
import duckdb, pandas, numpy, matplotlib, polars, clickhouse_connect, dotenv, pyarrow, pydantic
import exchange_calendars, numexpr, scipy, matplotlib_inline, cv2, PIL, imageio, openpyxl
import PyPDF2, docx, pptx, requests, jupyterlab, ipykernel
import camoufox
print("python baseline ok")
PY
COPY browser/bullx_browser.py /usr/local/bin/bullx-browser
ENV BULLX_CAMOUFOX_PREINSTALLED_DIR=/opt/camoufox
RUN chmod +x /usr/local/bin/bullx-browser \
  && mkdir -p /opt/camoufox
ARG TARGETARCH
ARG BULLX_CAMOUFOX_VERSION=135.0.1-beta.24
ARG BULLX_CAMOUFOX_DOWNLOAD=1
RUN if [ "$BULLX_CAMOUFOX_DOWNLOAD" = "1" ]; then \
    case "$TARGETARCH" in \
      arm64) CAMOUFOX_ARCH="arm64" ;; \
      amd64) CAMOUFOX_ARCH="x86_64" ;; \
      *) echo "unsupported Camoufox architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    CAMOUFOX_URL="https://github.com/daijro/camoufox/releases/download/v${BULLX_CAMOUFOX_VERSION}/camoufox-${BULLX_CAMOUFOX_VERSION}-lin.${CAMOUFOX_ARCH}.zip"; \
    aria2c --continue=true --max-connection-per-server=8 --split=8 --min-split-size=4M --max-tries=5 --retry-wait=5 --timeout=60 --connect-timeout=30 --dir=/tmp --out=camoufox.zip "$CAMOUFOX_URL"; \
    unzip -q /tmp/camoufox.zip -d /opt/camoufox; \
    python -c "import json, pathlib; version='${BULLX_CAMOUFOX_VERSION}'; pathlib.Path('/opt/camoufox/version.json').write_text(json.dumps({'version': version.split('-', 1)[0], 'release': version.split('-', 1)[1] if '-' in version else ''}))"; \
    chmod -R 755 /opt/camoufox; \
    rm -f /tmp/camoufox.zip; \
  fi
RUN bun --version \
  && aria2c --version >/dev/null \
  && jq --version \
  && git --version \
  && HOME=/tmp/bullx-browser-doctor bullx-browser --json doctor \
  && rm -rf /tmp/bullx-browser-doctor
COPY --from=builder /build/target/release/bullx-computerd /usr/local/bin/bullx-computerd
ENV BULLX_COMPUTER_WORKSPACE_ROOT=/workspaces \
    BULLX_COMPUTER_PORT=8787
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/bullx-computerd"]
