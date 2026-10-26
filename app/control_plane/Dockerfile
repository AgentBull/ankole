# syntax=docker/dockerfile:1.20

ARG ELIXIR_IMAGE=elixir:1.20.4-otp-29-slim
ARG BUN_IMAGE=oven/bun:1.4.4
ARG RUNNER_IMAGE=debian:trixie-slim
ARG ANKOLE_EDITION=foss

# A named BuildKit context can replace this empty source for a SaaS build.
FROM scratch AS ankole-internals
COPY .dockerignore /.ankole-empty-source

FROM ${BUN_IMAGE} AS bun

FROM ${ELIXIR_IMAGE} AS build

WORKDIR /repo

ARG DEBIAN_FRONTEND=noninteractive
ARG DEBIAN_MIRROR=http://deb.debian.org/debian
ARG DEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security
ARG RUST_TOOLCHAIN=1.98.1

ARG ANKOLE_EDITION=foss
ENV ANKOLE_EDITION=${ANKOLE_EDITION}
ENV MIX_ENV=prod
ENV HEX_HTTP_CONCURRENCY=1
ENV HEX_HTTP_TIMEOUT=120
ENV PATH="/root/.cargo/bin:${PATH}"

COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
RUN ln -sf /usr/local/bin/bun /usr/local/bin/bunx

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

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --default-toolchain "${RUST_TOOLCHAIN}" \
  && rustc --version \
  && cargo --version

RUN mix local.hex --force \
  && mix local.rebar --force

COPY package.json bun.lock ./
COPY app/agent_computer/package.json ./app/agent_computer/package.json
COPY app/ankole-browser/package.json ./app/ankole-browser/package.json
COPY app/control_plane/package.json ./app/control_plane/package.json
COPY app/kernel/package.json ./app/kernel/package.json
COPY app/webapps/package.json ./app/webapps/package.json
COPY libs/ankole-editor/package.json ./libs/ankole-editor/package.json
COPY libs/applet-sdk/package.json ./libs/applet-sdk/package.json
COPY libs/uikit/package.json ./libs/uikit/package.json
COPY tools/devkit/package.json ./tools/devkit/package.json
COPY tools/openapi-client-generator/package.json ./tools/openapi-client-generator/package.json
COPY libs/ankole-editor/patches/mdast-util-to-markdown@2.2.0.patch ./libs/ankole-editor/patches/mdast-util-to-markdown@2.2.0.patch

# The build uses only the workspace packages copied above.
RUN bun -e 'const p = await Bun.file("package.json").json(); p.workspaces = ["app/agent_computer", "app/ankole-browser", "app/control_plane", "app/kernel", "app/webapps", "libs/ankole-editor", "libs/applet-sdk", "libs/uikit", "tools/devkit", "tools/openapi-client-generator"]; await Bun.write("package.json", JSON.stringify(p));'

RUN --mount=type=cache,target=/root/.bun/install/cache \
  bun install --no-save

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

COPY tsconfig.json tsconfig.base.json ./
COPY app/control_plane ./app/control_plane
COPY app/agent_computer/src ./app/agent_computer/src
COPY app/kernel ./app/kernel
COPY app/library ./app/library
COPY app/locales ./app/locales
COPY app/webapps ./app/webapps
COPY libs ./libs
COPY plugins ./plugins
COPY --from=ankole-internals / ./internals/
COPY tools/openapi-client-generator ./tools/openapi-client-generator

WORKDIR /repo/app/control_plane

RUN --mount=type=cache,target=/root/.cache/hex \
  --mount=type=cache,target=/root/.cache/rebar3 \
  mix deps.get --only prod

RUN --mount=type=cache,target=/root/.cargo/git \
  --mount=type=cache,target=/root/.cargo/registry \
  --mount=type=cache,target=/repo/app/kernel/target \
  TORQUE_BUILD=true mix compile

RUN ANKOLE_SECRET_BASE=build-smoke \
  DATABASE_URL=ecto://ankole:ankole@127.0.0.1/ankole_build_smoke \
  ANKOLE_FILES_STORE=fs \
  ANKOLE_FILES_FS_ROOT=/var/lib/ankole/files \
  ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT=ws://build-smoke:4000/runtime-fabric/worker \
  ANKOLE_AGENT_COMPUTER_IMAGE=build-smoke \
  ANKOLE_FUNCTION_RUNTIME_URL=http://build-smoke:9000 \
  ANKOLE_FUNCTION_RUNTIME_TOKEN=build-smoke \
  PHX_SERVER=false \
  mix ankole.openapi.check

RUN --mount=type=cache,target=/root/.cargo/git \
  --mount=type=cache,target=/root/.cargo/registry \
  --mount=type=cache,target=/repo/app/kernel/target \
  bun run build

RUN --mount=type=cache,target=/root/.cargo/git \
  --mount=type=cache,target=/root/.cargo/registry \
  --mount=type=cache,target=/repo/app/kernel/target \
  mix release

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
COPY --from=build --chown=ankole:ankole /repo/app/library ./app/library

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
