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

WORKDIR /repo

COPY --from=build /repo/app/kernel/index.js ./app/kernel/index.js
COPY --from=build /repo/app/kernel/main.js ./app/kernel/main.js
COPY --from=build /repo/app/kernel/index.d.ts ./app/kernel/index.d.ts
COPY --from=build /repo/app/kernel/ankole-kernel.node ./app/kernel/ankole-kernel.node
COPY --from=build /repo/app/kernel/package.json ./app/kernel/package.json
COPY --from=build /repo/node_modules ./node_modules
COPY --from=build /repo/app/agent_computer/node_modules ./app/agent_computer/node_modules
COPY tsconfig.base.json ./tsconfig.base.json
COPY app/library ./app/library

RUN set -eux; \
  for attempt in 1 2 3; do \
    if /usr/local/bin/uv pip install --python /opt/ankole-python/bin/python \
      -r app/library/skills/ppt-master/requirements.txt; then \
      break; \
    fi; \
    if [ "$attempt" = "3" ]; then exit 1; fi; \
    sleep $((attempt * 10)); \
  done

COPY app/agent_computer/package.json ./app/agent_computer/package.json
COPY app/agent_computer/tsconfig.json ./app/agent_computer/tsconfig.json
COPY app/agent_computer/bin ./app/agent_computer/bin
COPY app/agent_computer/src ./app/agent_computer/src

RUN chmod +x ./app/agent_computer/bin/ankole-browser \
  && ln -sf /repo/app/agent_computer/bin/ankole-browser /usr/local/bin/ankole-browser \
  && printf '%s\n' 'ankole-agent-computer' > /etc/ankole-agent-computer-container

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
