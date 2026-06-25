FROM oven/bun:1.3.14 AS build

WORKDIR /repo

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    libpq-dev \
    libzmq3-dev \
    pkg-config \
    protobuf-compiler \
  && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal

ENV PATH="/root/.cargo/bin:${PATH}"

COPY package.json bun.lock ./
COPY app/kernel ./app/kernel
COPY app/agent_computer ./app/agent_computer

RUN bun install --no-save

WORKDIR /repo/app/agent_computer

RUN bun install --no-save

WORKDIR /repo/app/kernel

RUN bun run build:bun

WORKDIR /repo/app/agent_computer/native

RUN cargo build --release

FROM oven/bun:1.3.14

WORKDIR /repo

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
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
    postgresql-client \
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
    xvfb \
    xz-utils \
    zip \
    zstd \
  && mkdir -p /workspace/user-files /workspace/temp /workspace/library-containers \
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
COPY --from=build /repo/app/agent_computer/native/target/release/ankole-agent-computerd /usr/local/bin/ankole-agent-computerd
COPY --from=build /repo/node_modules ./node_modules
COPY app/agent_computer ./app/agent_computer
COPY --from=build /repo/app/agent_computer/node_modules ./app/agent_computer/node_modules
RUN chmod +x ./app/agent_computer/bin/ankole-browser \
  && ln -sf /repo/app/agent_computer/bin/ankole-browser /usr/local/bin/ankole-browser

WORKDIR /repo/app/agent_computer

ENV NODE_ENV=production
ENV ANKOLE_WORKSPACE_ROOT=/workspace
ENV ANKOLE_AGENT_COMPUTER_BUN_WORKDIR=/repo/app/agent_computer
ENV PATH="/opt/ankole-python/bin:/root/.local/bin:${PATH}"

ENTRYPOINT ["tini", "--"]
CMD ["ankole-agent-computerd"]
