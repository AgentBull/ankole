# syntax=docker/dockerfile:1
# Build the bullx-computerd daemon, then ship it on a slim image with bubblewrap.
# Build context is the package root (packages/computer).

FROM rust:1-bookworm AS builder
# aws-lc-rs (via rustls) needs cmake + a C toolchain.
RUN apt-get update \
  && apt-get install -y --no-install-recommends cmake \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --bin bullx-computerd

FROM python:3.12-slim-bookworm
COPY --from=ghcr.io/astral-sh/uv:0.11.21 /uv /uvx /usr/local/bin/
COPY --from=oven/bun:1.3.14 /usr/local/bin/bun /usr/local/bin/bun
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
  && curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' \
    | gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg \
  && ARCH="$(dpkg --print-architecture)" \
  && echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=${ARCH}] https://packages.clickhouse.com/deb stable main" > /etc/apt/sources.list.d/clickhouse.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
    aria2 \
    bash \
    bubblewrap \
    build-essential \
    ca-certificates \
    clickhouse-client \
    coreutils \
    curl \
    ffmpeg \
    file \
    fontconfig \
    fonts-liberation \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    ghostscript \
    git \
    gh \
    gnupg \
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
    less \
    libreoffice-impress \
    lsof \
    openssh-client \
    pandoc \
    pkg-config \
    poppler-utils \
    postgresql-client \
    procps \
    python3-dev \
    qpdf \
    ripgrep \
    rsync \
    tini \
    tmux \
    tree \
    unzip \
    xvfb \
    xz-utils \
    zip \
    zstd \
  && rm -rf /usr/share/doc/* /usr/share/info/* /usr/share/man/* \
  && rm -rf /var/lib/apt/lists/*
ENV UV_SYSTEM_PYTHON=1 \
    UV_TOOL_DIR=/usr/local/share/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin
RUN uv pip install --system --no-cache \
    blake3 \
    duckdb \
    defusedxml \
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
    "markitdown[pptx]" \
    nano-pdf \
    "camoufox[geoip]" \
  && python - <<'PY'
import blake3, duckdb, pandas, numpy, matplotlib, polars, clickhouse_connect, dotenv, pyarrow, pydantic
import exchange_calendars, numexpr, scipy, matplotlib_inline, cv2, PIL, imageio, openpyxl
import PyPDF2, defusedxml, docx, markitdown, pptx, requests, jupyterlab, ipykernel
import camoufox
print("python baseline ok")
PY
RUN curl -fsSL https://install.duckdb.org | sh \
  && install -m 0755 /root/.duckdb/cli/latest/duckdb /usr/local/bin/duckdb \
  && rm -rf /root/.duckdb \
  && duckdb --version
ARG CODEX_RELEASE=0.139.0
ARG TARGETARCH
RUN set -eux; \
  case "$TARGETARCH" in \
    arm64) CODEX_TARGET="aarch64-unknown-linux-musl" ;; \
    amd64) CODEX_TARGET="x86_64-unknown-linux-musl" ;; \
    *) echo "unsupported Codex architecture: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  CODEX_ASSET="codex-package-${CODEX_TARGET}.tar.gz"; \
  CODEX_API="https://api.github.com/repos/openai/codex/releases/tags/rust-v${CODEX_RELEASE}"; \
  CODEX_URL="https://github.com/openai/codex/releases/download/rust-v${CODEX_RELEASE}/${CODEX_ASSET}"; \
  CODEX_SHA="$(curl -fsSL "$CODEX_API" | jq -r --arg asset "$CODEX_ASSET" '.assets[] | select(.name == $asset) | .digest | sub("^sha256:"; "")')"; \
  test -n "$CODEX_SHA"; \
  test "$CODEX_SHA" != "null"; \
  curl -fsSL "$CODEX_URL" -o /tmp/codex.tar.gz; \
  echo "$CODEX_SHA  /tmp/codex.tar.gz" | sha256sum -c -; \
  mkdir -p /usr/local/share/codex; \
  tar -xzf /tmp/codex.tar.gz -C /usr/local/share/codex; \
  chmod 0755 /usr/local/share/codex/bin/codex /usr/local/share/codex/codex-path/rg; \
  if [ -f /usr/local/share/codex/codex-resources/bwrap ]; then chmod 0755 /usr/local/share/codex/codex-resources/bwrap; fi; \
  ln -sf /usr/local/share/codex/bin/codex /usr/local/bin/codex; \
  rm -f /tmp/codex.tar.gz; \
  codex --version
COPY browser/bullx_browser.py /usr/local/bin/bullx-browser
ENV BULLX_CAMOUFOX_PREINSTALLED_DIR=/opt/camoufox
RUN chmod +x /usr/local/bin/bullx-browser \
  && mkdir -p /opt/camoufox
ARG BULLX_CAMOUFOX_VERSION=150.0.2
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
  && file --version >/dev/null \
  && fc-match "Noto Sans CJK SC" >/dev/null \
  && fc-match "Noto Color Emoji" >/dev/null \
  && git --version \
  && rg --version >/dev/null \
  && less --version >/dev/null \
  && tree --version >/dev/null \
  && zip -v >/dev/null \
  && rsync --version >/dev/null \
  && ps --version >/dev/null \
  && command -v lsof >/dev/null \
  && ssh -V \
  && gh --version >/dev/null \
  && duckdb --version \
  && clickhouse-client --version \
  && psql --version \
  && qpdf --version \
  && gs --version >/dev/null \
  && ffmpeg -version >/dev/null \
  && pandoc --version >/dev/null \
  && gcc --version >/dev/null \
  && g++ --version >/dev/null \
  && make --version >/dev/null \
  && pkg-config --version \
  && python3-config --includes >/dev/null \
  && nano-pdf --help >/dev/null \
  && soffice --version \
  && pdftoppm -v >/dev/null 2>&1 \
  && HOME=/tmp/bullx-browser-doctor bullx-browser --json doctor \
  && rm -rf /tmp/bullx-browser-doctor
COPY --from=builder /build/target/release/bullx-computerd /usr/local/bin/bullx-computerd
ENV BULLX_COMPUTER_WORKSPACE_ROOT=/workspaces \
    BULLX_COMPUTER_PORT=8787
EXPOSE 8787
# tini reaps the orphans that every transient bwrap sandbox leaves behind
# (its PID-namespace init outlives the monitor and reparents to PID 1).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/bullx-computerd"]
