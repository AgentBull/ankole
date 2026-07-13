# syntax=docker/dockerfile:1.20

ARG ELIXIR_IMAGE=elixir:1.20.1-otp-28-slim
ARG BUN_IMAGE=oven/bun:1.3.14
ARG RUNNER_IMAGE=debian:trixie-slim

FROM ${BUN_IMAGE} AS bun

FROM ${ELIXIR_IMAGE} AS build

WORKDIR /repo

ARG DEBIAN_FRONTEND=noninteractive
ARG DEBIAN_MIRROR=http://deb.debian.org/debian
ARG DEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security
ARG RUST_TOOLCHAIN=1.91.0

ENV MIX_ENV=prod
ENV RUSTFLAGS="--cfg reqwest_unstable"
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
    libzmq3-dev \
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
COPY app/control_plane/package.json ./app/control_plane/package.json
COPY app/kernel/package.json ./app/kernel/package.json
COPY app/webapps/package.json ./app/webapps/package.json
COPY libs/feishu_openapi/package.json ./libs/feishu_openapi/package.json
COPY libs/uikit/package.json ./libs/uikit/package.json
COPY tools/devkit/package.json ./tools/devkit/package.json

RUN --mount=type=cache,target=/root/.bun/install/cache \
  bun install --no-save

COPY --parents \
  ./app/control_plane/mix.exs \
  ./app/control_plane/mix.lock \
  ./app/kernel/mix.exs \
  ./app/kernel/Cargo.toml \
  ./app/kernel/Cargo.lock \
  ./libs/*/mix.exs \
  ./libs/*/mix.lock \
  ./

WORKDIR /repo/app/control_plane

RUN --mount=type=cache,target=/root/.cache/hex \
  --mount=type=cache,target=/root/.cache/rebar3 \
  mix deps.get --only prod

WORKDIR /repo

COPY tsconfig.json tsconfig.base.json ./
COPY app/control_plane ./app/control_plane
COPY app/kernel ./app/kernel
COPY app/library ./app/library
COPY app/locales ./app/locales
COPY app/webapps ./app/webapps
COPY libs ./libs
COPY plugins ./plugins

WORKDIR /repo/app/control_plane

RUN --mount=type=cache,target=/root/.cargo/git \
  --mount=type=cache,target=/root/.cargo/registry \
  --mount=type=cache,target=/repo/app/kernel/target \
  mix compile

RUN ANKOLE_SECRET_BASE=build-smoke \
  DATABASE_URL=ecto://ankole:ankole@127.0.0.1/ankole_build_smoke \
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
    libzmq5 \
    locales \
    openssl \
    tini \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

RUN useradd --system --home-dir /app --shell /usr/sbin/nologin ankole \
  && chown ankole:ankole /app

COPY --from=build --chown=ankole:ankole /repo/app/control_plane/_build/prod/rel/ankole ./
COPY --from=build --chown=ankole:ankole /repo/app/locales ./lib/locales
COPY --from=build --chown=ankole:ankole /repo/app/library ./app/library
COPY --from=build --chown=ankole:ankole /repo/plugins ./plugins

USER ankole

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV MIX_ENV=prod
ENV PHX_SERVER=true
ENV PORT=4000
ENV ANKOLE_LIBRARY_ROOT=/app/app/library
ENV ANKOLE_PLUGIN_PATHS=/app/plugins

RUN ANKOLE_SECRET_BASE=build-smoke \
  DATABASE_URL=ecto://ankole:ankole@127.0.0.1/ankole_build_smoke \
  PHX_SERVER=false \
  /app/bin/ankole eval 'Application.load(:ankole)'

ENTRYPOINT ["tini", "-g", "--"]
CMD ["/app/bin/ankole", "start"]
