# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ghcr.io/agentbull/ankole-agent-os-base:main-latest

FROM ${BASE_IMAGE} AS build

WORKDIR /repo

ENV CARGO_NET_RETRY=5
ENV CARGO_HTTP_TIMEOUT=120

COPY package.json bun.lock ./
COPY app/kernel/package.json app/kernel/Cargo.toml app/kernel/Cargo.lock ./app/kernel/
COPY app/agent_computer/package.json ./app/agent_computer/package.json

RUN --mount=type=cache,target=/root/.bun/install/cache \
  set -eux; \
  for attempt in 1 2 3; do \
    if timeout 120s bun install --no-save; then exit 0; fi; \
    rm -rf /tmp/bun-*; \
    sleep $((attempt * 5)); \
  done; \
  timeout 120s bun install --no-save

COPY app/kernel ./app/kernel
COPY app/agent_computer ./app/agent_computer

WORKDIR /repo/app/agent_computer

RUN --mount=type=cache,target=/root/.bun/install/cache \
  set -eux; \
  for attempt in 1 2 3; do \
    if timeout 120s bun install --no-save; then exit 0; fi; \
    rm -rf /tmp/bun-*; \
    sleep $((attempt * 5)); \
  done; \
  timeout 120s bun install --no-save

WORKDIR /repo/app/kernel

RUN --mount=type=cache,target=/root/.cargo/git \
  --mount=type=cache,target=/root/.cargo/registry \
  --mount=type=cache,target=/repo/app/kernel/target \
  bun run build:bun

FROM ${BASE_IMAGE}

ARG LARK_CLI_VERSION=v1.0.69
ARG TARGETARCH

WORKDIR /repo

RUN set -eux; \
  version="${LARK_CLI_VERSION#v}"; \
  case "${TARGETARCH:-$(uname -m)}" in \
    amd64|x86_64) lark_cli_arch="amd64" ;; \
    arm64|aarch64) lark_cli_arch="arm64" ;; \
    *) echo "Unsupported lark-cli architecture: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
  esac; \
  asset="lark-cli-${version}-linux-${lark_cli_arch}.tar.gz"; \
  base_url="https://github.com/larksuite/cli/releases/download/${LARK_CLI_VERSION}"; \
  curl -fsSL "${base_url}/checksums.txt" -o /tmp/lark-cli-checksums.txt; \
  curl -fsSL "${base_url}/${asset}" -o "/tmp/${asset}"; \
  expected="$(awk -v asset="${asset}" '$2 == asset { print $1; exit }' /tmp/lark-cli-checksums.txt)"; \
  test -n "${expected}"; \
  printf '%s  %s\n' "${expected}" "/tmp/${asset}" | sha256sum -c -; \
  mkdir -p /tmp/lark-cli; \
  tar -xzf "/tmp/${asset}" -C /tmp/lark-cli; \
  install -m 0755 /tmp/lark-cli/lark-cli /usr/local/bin/lark-cli; \
  test "$(lark-cli --version)" = "lark-cli version ${version}"; \
  rm -rf /tmp/lark-cli /tmp/lark-cli-checksums.txt "/tmp/${asset}"

RUN set -eux; \
  installed=0; \
  for attempt in 1 2 3; do \
    if bun add -g @openai/codex@0.144.0 mcporter@0.12.3; then installed=1; break; fi; \
    rm -rf /root/.bun/install/cache/* /tmp/bun-*; \
    sleep $((attempt * 5)); \
  done; \
  test "$installed" = 1; \
  rm -f /usr/local/bin/codex /usr/local/bin/mcporter; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec /usr/local/bin/bun /root/.bun/install/global/node_modules/@openai/codex/bin/codex.js "$@"' > /usr/local/bin/codex; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec /usr/local/bin/bun /root/.bun/install/global/node_modules/mcporter/dist/cli.js "$@"' > /usr/local/bin/mcporter; \
  chmod +x /usr/local/bin/codex; \
  chmod +x /usr/local/bin/mcporter; \
  test "$(codex --version)" = "codex-cli 0.144.0"; \
  test "$(mcporter --version)" = "0.12.3"

COPY --from=build /repo/app/kernel/index.js ./app/kernel/index.js
COPY --from=build /repo/app/kernel/main.js ./app/kernel/main.js
COPY --from=build /repo/app/kernel/index.d.ts ./app/kernel/index.d.ts
COPY --from=build /repo/app/kernel/ankole-kernel.node ./app/kernel/ankole-kernel.node
COPY --from=build /repo/app/kernel/package.json ./app/kernel/package.json
COPY --from=build /repo/node_modules ./node_modules
COPY --from=build /repo/app/agent_computer/node_modules ./app/agent_computer/node_modules
COPY tsconfig.base.json ./tsconfig.base.json
COPY app/library ./app/library

COPY app/agent_computer/package.json ./app/agent_computer/package.json
COPY app/agent_computer/tsconfig.json ./app/agent_computer/tsconfig.json
COPY app/agent_computer/src ./app/agent_computer/src

RUN bun app/agent_computer/src/validation/lark-skill-examples.ts app/library/skills

RUN printf '%s\n' 'ankole-agent-computer' > /etc/ankole-agent-computer-container

RUN set -eux; \
  printf '%s\n' \
    'export CODEX_UNSAFE_ALLOW_NO_SANDBOX=1' \
    'if [ -n "${BASH_VERSION:-}" ]; then' \
    '  shopt -s expand_aliases 2>/dev/null || true' \
    'fi' \
    "alias node='bun'" \
    > /etc/profile.d/ankole-agent-computer.sh; \
  chmod 0644 /etc/profile.d/ankole-agent-computer.sh; \
  printf '%s\n' \
    '[ -r /etc/profile.d/ankole-agent-computer.sh ] && . /etc/profile.d/ankole-agent-computer.sh' \
    >> /etc/bash.bashrc; \
  printf '%s\n' \
    '[ -r /etc/profile.d/ankole-agent-computer.sh ] && . /etc/profile.d/ankole-agent-computer.sh' \
    >> /root/.bashrc; \
  printf '%s\n' \
    '[ -r /etc/profile.d/ankole-agent-computer.sh ] && . /etc/profile.d/ankole-agent-computer.sh' \
    >> /root/.profile; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec /usr/local/bin/bun "$@"' > /usr/local/bin/node; \
  chmod +x /usr/local/bin/node

WORKDIR /repo/app/agent_computer

ENV NODE_ENV=production
ENV CODEX_UNSAFE_ALLOW_NO_SANDBOX=1
ENV LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1
ENV LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1
ENV BASH_ENV=/etc/profile.d/ankole-agent-computer.sh
ENV ENV=/etc/profile.d/ankole-agent-computer.sh
ENV SHELL=/bin/bash
ENV ANKOLE_WORKSPACE_ROOT=/workspace
ENV ANKOLE_SHARED_FS_ROOT=/workspace/shared
ENV ANKOLE_USER_FILES_ROOT=/workspace/shared/user-files
ENV ANKOLE_AGENT_INSTALLED_SKILLS_ROOT=/workspace/shared/skills/agents
ENV ANKOLE_BUILTIN_SKILLS_ROOT=/repo/app/library/skills
ENV ANKOLE_WORKSPACE_SESSIONS_ROOT=/workspace/.sessions
ENV ANKOLE_AGENT_COMPUTER_BUN_WORKDIR=/repo/app/agent_computer
ENV PATH="/opt/ankole-python/bin:/root/.cargo/bin:${PATH}"

ENTRYPOINT ["tini", "-g", "--"]
CMD ["bun", "src/main.ts"]
