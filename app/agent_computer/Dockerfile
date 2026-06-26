FROM oven/bun:1.3.14 AS build

WORKDIR /repo

ARG DEBIAN_FRONTEND=noninteractive
ARG DEBIAN_MIRROR=http://deb.debian.org/debian
ARG DEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security

RUN sed -i \
    -e "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
    -e "s|http://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
    /etc/apt/sources.list.d/debian.sources \
  && apt-get -o Acquire::Retries=5 update \
  && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    libzmq3-dev \
    pkg-config \
    protobuf-compiler \
  && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal

ENV PATH="/root/.cargo/bin:${PATH}"
ENV CARGO_NET_RETRY=5
ENV CARGO_HTTP_TIMEOUT=120

COPY package.json bun.lock ./
COPY app/kernel ./app/kernel
COPY app/agent_computer ./app/agent_computer

RUN set -eux; \
  for attempt in 1 2 3; do \
    if bun install --no-save; then exit 0; fi; \
    rm -rf /root/.bun/install/cache /tmp/bun-*; \
    sleep $((attempt * 5)); \
  done; \
  bun install --no-save

WORKDIR /repo/app/agent_computer

RUN set -eux; \
  for attempt in 1 2 3; do \
    if bun install --no-save; then exit 0; fi; \
    rm -rf /root/.bun/install/cache /tmp/bun-*; \
    sleep $((attempt * 5)); \
  done; \
  bun install --no-save

WORKDIR /repo/app/kernel

RUN bun run build:bun

FROM oven/bun:1.3.14

WORKDIR /repo

ARG DEBIAN_FRONTEND=noninteractive
ARG DEBIAN_MIRROR=http://deb.debian.org/debian
ARG DEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security

ENV PATH="/root/.local/bin:${PATH}"

RUN sed -i \
    -e "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
    -e "s|http://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
    /etc/apt/sources.list.d/debian.sources \
  && apt-get -o Acquire::Retries=5 update \
  && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
    bash \
    bubblewrap \
    ca-certificates \
    chromium \
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
    gnupg \
    grep \
    jq \
    less \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-glib-1-2 \
    libgbm1 \
    libgl1 \
    libglib2.0-0 \
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
    libzmq5 \
    libreoffice-impress \
    lsof \
    openssh-client \
    pandoc \
    pkg-config \
    poppler-utils \
    procps \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    qpdf \
    ripgrep \
    rsync \
    tini \
    tmux \
    tree \
    unzip \
    util-linux \
    xvfb \
    xz-utils \
    zip \
    zstd \
  && mkdir -p /workspace/shared/user-files /workspace/shared/skills/agents /workspace/.sessions \
  && chmod -R 0775 /workspace \
  && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
  && python3 -m venv /opt/ankole-python \
  && /root/.local/bin/uv pip install --python /opt/ankole-python/bin/python \
    blake3 \
    defusedxml \
    duckdb \
    imageio \
    ipykernel \
    jupyter-client \
    jupyter-server \
    jupyterlab \
    "markitdown[pptx]" \
    matplotlib \
    matplotlib-inline \
    nano-pdf \
    nbformat \
    numpy \
    opencv-python-headless \
    openpyxl \
    pandas \
    pillow \
    polars \
    pyarrow \
    pydantic \
    python-docx \
    python-pptx \
    requests \
    scipy \
    websocket-client \
  && find /opt/ankole-python/bin -maxdepth 1 -type f -perm /111 -exec ln -sf {} /usr/local/bin/ \; \
  && rm -f /usr/local/bin/python /usr/local/bin/python3 \
  && printf '%s\n' '#!/usr/bin/env sh' 'exec /opt/ankole-python/bin/python "$@"' > /usr/local/bin/python \
  && cp /usr/local/bin/python /usr/local/bin/python3 \
  && chmod +x /usr/local/bin/python /usr/local/bin/python3

COPY --from=build /repo/app/kernel/index.js ./app/kernel/index.js
COPY --from=build /repo/app/kernel/main.js ./app/kernel/main.js
COPY --from=build /repo/app/kernel/index.d.ts ./app/kernel/index.d.ts
COPY --from=build /repo/app/kernel/ankole-kernel.node ./app/kernel/ankole-kernel.node
COPY --from=build /repo/app/kernel/package.json ./app/kernel/package.json
COPY --from=build /repo/node_modules ./node_modules
COPY app/library ./app/library
COPY app/agent_computer ./app/agent_computer
COPY --from=build /repo/app/agent_computer/node_modules ./app/agent_computer/node_modules
RUN chmod +x ./app/agent_computer/bin/ankole-browser \
  && ln -sf /repo/app/agent_computer/bin/ankole-browser /usr/local/bin/ankole-browser \
  && printf '%s\n' 'ankole-agent-computer' > /etc/ankole-agent-computer-container

WORKDIR /repo/app/agent_computer

ENV NODE_ENV=production
ENV ANKOLE_AGENT_COMPUTER_CONTAINER=1
ENV ANKOLE_WORKSPACE_ROOT=/workspace
ENV ANKOLE_SHARED_FS_ROOT=/workspace/shared
ENV ANKOLE_USER_FILES_ROOT=/workspace/shared/user-files
ENV ANKOLE_AGENT_INSTALLED_SKILLS_ROOT=/workspace/shared/skills/agents
ENV ANKOLE_BUILTIN_SKILLS_ROOT=/repo/app/library/skills
ENV ANKOLE_WORKSPACE_SESSIONS_ROOT=/workspace/.sessions
ENV ANKOLE_AGENT_COMPUTER_BUN_WORKDIR=/repo/app/agent_computer
ENV PATH="/opt/ankole-python/bin:/root/.local/bin:${PATH}"

ENTRYPOINT ["tini", "--"]
CMD ["bun", "src/main.ts"]
