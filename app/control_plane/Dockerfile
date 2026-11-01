# syntax=docker/dockerfile:1.20

ARG ELIXIR_IMAGE=elixir:1.20.4-otp-29-slim
ARG BUN_IMAGE=oven/bun:1.4.4
ARG RUNNER_IMAGE=debian:trixie-slim
ARG ANKOLE_EDITION=foss

# A named BuildKit context can replace this empty source for a SaaS build.
FROM scratch AS ankole-internals
COPY .dockerignore /.ankole-empty-source

FROM ${BUN_IMAGE} AS bun-deps

WORKDIR /repo

COPY package.json bun.lock ./
COPY app/webapps/package.json ./app/webapps/package.json
COPY libs/ankole-editor/package.json ./libs/ankole-editor/package.json
COPY libs/applet-sdk/package.json ./libs/applet-sdk/package.json
COPY libs/uikit/package.json ./libs/uikit/package.json

# Install only the frontend workspace packages needed for the Vite bundle.
RUN bun -e 'const p = await Bun.file("package.json").json(); p.workspaces = ["app/webapps", "libs/ankole-editor", "libs/applet-sdk", "libs/uikit"]; await Bun.write("package.json", JSON.stringify(p));'

RUN --mount=type=cache,target=/root/.bun/install/cache \
  bun install --no-save

FROM bun-deps AS webapps-build

ARG ANKOLE_EDITION=foss
ENV ANKOLE_EDITION=${ANKOLE_EDITION}
ENV NODE_ENV=production

COPY --parents \
  ./tsconfig.json \
  ./tsconfig.base.json \
  ./libs/ankole-editor/tsconfig.json \
  ./libs/applet-sdk/tsconfig.json \
  ./libs/uikit/tsconfig.json \
  ./
COPY app/locales ./app/locales
COPY app/webapps ./app/webapps
COPY libs/ankole-editor/src ./libs/ankole-editor/src
COPY libs/ankole-editor/upstream ./libs/ankole-editor/upstream
COPY libs/applet-sdk/src ./libs/applet-sdk/src
COPY libs/uikit/src ./libs/uikit/src

RUN --mount=from=ankole-internals,source=/,target=/mnt/internals \
  if [ "${ANKOLE_EDITION}" = "saas" ]; then \
    mkdir -p /repo/internals \
    && cp -RP /mnt/internals/locales /repo/internals/locales \
    && cp -RP /mnt/internals/webapps /repo/internals/webapps \
    && rm -rf /repo/internals/webapps/node_modules; \
  fi

WORKDIR /repo/app/webapps

RUN bun run build:bundle

FROM ${ELIXIR_IMAGE} AS build

WORKDIR /repo

ARG DEBIAN_FRONTEND=noninteractive
ARG DEBIAN_MIRROR=http://deb.debian.org/debian
ARG DEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security
ARG RUST_TOOLCHAIN=1.99.1
ARG SCCACHE_VERSION=v0.19.0
ARG TARGETARCH

ENV MIX_ENV=prod
ENV HEX_HTTP_CONCURRENCY=1
ENV HEX_HTTP_TIMEOUT=120
ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUSTC_WRAPPER=/usr/local/bin/sccache
ENV SCCACHE_DIR=/var/cache/sccache
ENV SCCACHE_CACHE_SIZE=10G
ENV CARGO_INCREMENTAL=0

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
    patch \
    pkg-config \
    protobuf-compiler \
  && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
  case "${TARGETARCH:-$(uname -m)}" in \
    amd64|x86_64) \
      sccache_arch="x86_64-unknown-linux-musl"; \
      sccache_sha256="aa73c7270c997894038c0d8f0d297865f57569e1687883322bc431713d4bb9dd" ;; \
    arm64|aarch64) \
      sccache_arch="aarch64-unknown-linux-musl"; \
      sccache_sha256="3e47fc4a71b1ddd1b4294a0de9d34498922fdf41e3cd0bda5df3954e3d6deb9d" ;; \
    *) echo "Unsupported sccache architecture: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
  esac; \
  sccache_dir="sccache-${SCCACHE_VERSION}-${sccache_arch}"; \
  curl -fsSL --retry 5 --retry-all-errors \
    "https://github.com/mozilla/sccache/releases/download/${SCCACHE_VERSION}/${sccache_dir}.tar.gz" \
    -o /tmp/sccache.tar.gz; \
  echo "${sccache_sha256}  /tmp/sccache.tar.gz" | sha256sum -c -; \
  tar -xzf /tmp/sccache.tar.gz -C /tmp; \
  install -m 0755 "/tmp/${sccache_dir}/sccache" /usr/local/bin/sccache; \
  rm -rf /tmp/sccache.tar.gz "/tmp/${sccache_dir}"; \
  sccache --version

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --default-toolchain "${RUST_TOOLCHAIN}" \
  && rustc --version \
  && cargo --version

RUN mix local.hex --force \
  && mix local.rebar --force

COPY --from=bun-deps /usr/local/bin/bun /usr/local/bin/bun
RUN ln -sf /usr/local/bin/bun /usr/local/bin/bunx

ARG ANKOLE_EDITION=foss
ENV ANKOLE_EDITION=${ANKOLE_EDITION}

COPY --parents \
  ./app/control_plane/mix.exs \
  ./app/control_plane/mix.lock \
  ./app/control_plane/patches/* \
  ./app/kernel/mix.exs \
  ./app/kernel/Cargo.toml \
  ./app/kernel/Cargo.lock \
  ./libs/*/mix.exs \
  ./

WORKDIR /repo/app/control_plane

RUN --mount=type=cache,target=/root/.cache/hex \
  --mount=type=cache,target=/root/.cache/rebar3 \
  mix deps.get --only prod

WORKDIR /repo

# Compile third-party Hex and Rust NIF dependencies against dependencies.exs so
# application config or frontend entry edits do not invalidate this layer.
COPY --parents \
  ./app/control_plane/config/dependencies.exs \
  ./

RUN printf '%s\n' \
    'import Config' \
    'import_config "dependencies.exs"' \
    'import_config "#{config_env()}.exs"' \
    > /repo/app/control_plane/config/config.exs \
  && printf '%s\n' \
    'import Config' \
    'config :logger, level: :info' \
    > /repo/app/control_plane/config/prod.exs

WORKDIR /repo/app/control_plane

RUN --mount=type=cache,target=/root/.cargo/git \
  --mount=type=cache,target=/root/.cargo/registry \
  --mount=type=cache,id=ankole-cp-sccache-${TARGETARCH},target=/var/cache/sccache \
  MJML_BUILD=true TORQUE_BUILD=true mix deps.compile --skip-local-deps

WORKDIR /repo

COPY app/kernel ./app/kernel
COPY libs/im_transport ./libs/im_transport
COPY libs/feishu_protocol ./libs/feishu_protocol

WORKDIR /repo/app/control_plane

RUN --mount=type=cache,target=/root/.cargo/git \
  --mount=type=cache,target=/root/.cargo/registry \
  --mount=type=cache,id=ankole-cp-sccache-${TARGETARCH},target=/var/cache/sccache \
  --mount=type=cache,id=ankole-cp-kernel-${TARGETARCH},target=/repo/app/kernel/target \
  mix deps.compile ankole_kernel im_transport feishu_protocol \
  && mix deps.loadpaths

WORKDIR /repo

COPY app/control_plane ./app/control_plane
COPY app/locales ./app/locales
COPY app/webapps/entries.json ./app/webapps/entries.json
COPY app/webapps/entrypoints ./app/webapps/entrypoints
COPY app/webapps/openapi ./app/webapps/openapi
COPY app/webapps/scripts ./app/webapps/scripts
COPY plugins ./plugins
RUN --mount=from=ankole-internals,source=/,target=/mnt/internals \
  if [ "${ANKOLE_EDITION}" = "saas" ]; then \
    mkdir -p /repo/internals \
    && cp -RP /mnt/internals/control_plane /repo/internals/control_plane \
    && cp -RP /mnt/internals/locales /repo/internals/locales \
    && cp -RP /mnt/internals/webapps /repo/internals/webapps \
    && rm -rf /repo/internals/webapps/node_modules \
    && if [ -d /mnt/internals/plugins ]; then cp -RP /mnt/internals/plugins /repo/internals/plugins; fi; \
  fi

RUN mkdir -p /repo/app/webapps/node_modules

WORKDIR /repo/app/control_plane

RUN --mount=type=cache,target=/root/.cargo/git \
  --mount=type=cache,target=/root/.cargo/registry \
  --mount=type=cache,id=ankole-cp-sccache-${TARGETARCH},target=/var/cache/sccache \
  --mount=type=cache,id=ankole-cp-kernel-${TARGETARCH},target=/repo/app/kernel/target \
  mix compile

RUN ANKOLE_SECRET_BASE=build-smoke \
  ANKOLE_SAAS_DOMAIN=ankole.localhost \
  DATABASE_URL=ecto://ankole:ankole@127.0.0.1/ankole_build_smoke \
  ANKOLE_FILES_STORE=fs \
  ANKOLE_FILES_FS_ROOT=/var/lib/ankole/files \
  ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT=ws://build-smoke:4000/runtime-fabric/worker \
  ANKOLE_AGENT_COMPUTER_IMAGE=build-smoke \
  ANKOLE_FUNCTION_RUNTIME_URL=http://build-smoke:9000 \
  ANKOLE_FUNCTION_RUNTIME_TOKEN=build-smoke \
  PHX_SERVER=false \
  mix ankole.openapi.check

COPY --from=webapps-build \
  /repo/app/control_plane/_build/${ANKOLE_EDITION}/webapps/assets \
  ./_build/${ANKOLE_EDITION}/webapps/assets

RUN --mount=type=cache,target=/root/.cargo/git \
  --mount=type=cache,target=/root/.cargo/registry \
  --mount=type=cache,id=ankole-cp-sccache-${TARGETARCH},target=/var/cache/sccache \
  --mount=type=cache,id=ankole-cp-kernel-${TARGETARCH},target=/repo/app/kernel/target \
  mix phx.digest --no-deps-check \
  && mix release

FROM ${RUNNER_IMAGE}

WORKDIR /app

ARG ANKOLE_EDITION=foss
ARG ANKOLE_VERSION=development
ARG ANKOLE_RELEASE_REVISION=development
ARG ANKOLE_AGENT_COMPUTER_IMAGE=""
ARG DEBIAN_FRONTEND=noninteractive
ARG DEBIAN_MIRROR=http://deb.debian.org/debian
ARG DEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security

RUN sed -i \
    -e "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR}|g" \
    -e "s|http://deb.debian.org/debian|${DEBIAN_MIRROR}|g" \
    /etc/apt/sources.list.d/debian.sources \
  && apt-get -o Acquire::Retries=5 update \
  && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
    ca-certificates \
    libgcc-s1 \
    libncurses6 \
    libstdc++6 \
    locales \
    openssh-client \
    openssl \
    tini \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

# The fixed uid and gid let a Kubernetes fsGroup make the file store volume
# writable. /var/lib/ankole/files is the mount point of the `fs` file store;
# a new Docker named volume copies its owner from the image. USER is numeric
# because the kubelet can verify runAsNonRoot only for a numeric image user.
RUN groupadd --system --gid 10001 ankole \
  && useradd --system --uid 10001 --gid ankole --home-dir /app --shell /usr/sbin/nologin ankole \
  && chown ankole:ankole /app \
  && install -d -o ankole -g ankole /var/lib/ankole /var/lib/ankole/files

COPY --from=build --chown=ankole:ankole /repo/app/control_plane/_build/${ANKOLE_EDITION}/prod/rel/ankole ./
COPY --chown=ankole:ankole app/library ./app/library

USER 10001:10001

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV MIX_ENV=prod
ENV PHX_SERVER=true
ENV PORT=4000
ENV ANKOLE_VERSION=${ANKOLE_VERSION}
ENV ANKOLE_RELEASE_REVISION=${ANKOLE_RELEASE_REVISION}
ENV ANKOLE_AGENT_COMPUTER_IMAGE=${ANKOLE_AGENT_COMPUTER_IMAGE}
ENV ANKOLE_LIBRARY_ROOT=/app/app/library

RUN ANKOLE_SECRET_BASE=build-smoke \
  ANKOLE_SAAS_DOMAIN=ankole.localhost \
  DATABASE_URL=ecto://ankole:ankole@127.0.0.1/ankole_build_smoke \
  ANKOLE_FILES_STORE=fs \
  ANKOLE_FILES_FS_ROOT=/var/lib/ankole/files \
  ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT=ws://build-smoke:4000/runtime-fabric/worker \
  ANKOLE_FUNCTION_RUNTIME_URL=http://build-smoke:9000 \
  ANKOLE_FUNCTION_RUNTIME_TOKEN=build-smoke \
  PHX_SERVER=false \
  /app/bin/ankole eval 'Application.load(:ankole)'

ENTRYPOINT ["tini", "-g", "--"]
CMD ["/app/bin/ankole", "start"]
