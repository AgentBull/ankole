# syntax=docker/dockerfile:1
# Build context: repository root.

FROM rust:1-bookworm AS build
COPY --from=oven/bun:1.3.14 /usr/local/bin/bun /usr/local/bin/bun
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates cmake pkg-config \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app

COPY . .
RUN bun install --frozen-lockfile
RUN bun run --filter @agentbull/bullx-native-addons build:production
RUN bun run --filter @agentbull/bullx-agent web:build
RUN rm -rf \
  /root/.cache \
  /tmp/* \
  /app/packages/native-addons/target \
  /app/packages/computer/target \
  /app/internals/skills/financial-data/cli/target

FROM oven/bun:1.3.14
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssh-client \
  && rm -rf /var/lib/apt/lists/* \
  && ssh -V \
  && test -x /usr/bin/ssh-keygen
WORKDIR /app
ENV NODE_ENV=production \
    HTTP_PORT=3000 \
    PLUGIN_DIR=../plugin \
    INTERNAL_PLUGIN_DIR=../internals/plugins
COPY --from=build /app /app
WORKDIR /app/app
EXPOSE 3000
CMD ["bun", "src/main.ts"]
