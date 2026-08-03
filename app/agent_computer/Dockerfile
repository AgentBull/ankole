# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE
ARG BROWSER_NODE_VERSION=26.5.0

FROM node:${BROWSER_NODE_VERSION}-bookworm-slim AS browser-node

FROM ${BASE_IMAGE} AS build

ARG BROWSER_NODE_VERSION

WORKDIR /repo

ENV CARGO_NET_RETRY=5
ENV CARGO_HTTP_TIMEOUT=120

COPY package.json bun.lock ./
COPY app/kernel/package.json app/kernel/Cargo.toml app/kernel/Cargo.lock ./app/kernel/
COPY app/agent_computer/package.json ./app/agent_computer/package.json
COPY app/ankole-browser/package.json ./app/ankole-browser/package.json

COPY --from=browser-node /usr/local/bin/node /opt/ankole-browser/node/bin/node

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
COPY app/ankole-browser ./app/ankole-browser

WORKDIR /repo/app/kernel

RUN --mount=type=cache,target=/root/.cargo/git \
  --mount=type=cache,target=/root/.cargo/registry \
  --mount=type=cache,target=/repo/app/kernel/target \
  bun run build:bun

WORKDIR /repo/app/ankole-browser

RUN bun run build \
  && mkdir -p /tmp/ankole-browser-runtime/node/bin /tmp/ankole-browser-runtime/node_modules \
  && cp /opt/ankole-browser/node/bin/node /tmp/ankole-browser-runtime/node/bin/node \
  && cp package.json /tmp/ankole-browser-runtime/package.json \
  && cp -R dist /tmp/ankole-browser-runtime/dist \
  && cp -RL node_modules/playwright-core /tmp/ankole-browser-runtime/node_modules/playwright-core \
  && PLAYWRIGHT_BROWSERS_PATH=/tmp/ankole-browser-runtime/browsers \
    /opt/ankole-browser/node/bin/node node_modules/playwright-core/cli.js install chromium-headless-shell \
  && browser_bin="$(find /tmp/ankole-browser-runtime/browsers -type f \
    \( -name headless_shell -o -name chrome-headless-shell \) -perm /111 -print -quit)" \
  && test -n "${browser_bin}" \
  && mkdir -p /tmp/ankole-browser-runtime/browsers/chromium \
  && ln -s "$(realpath --relative-to=/tmp/ankole-browser-runtime/browsers/chromium "${browser_bin}")" \
    /tmp/ankole-browser-runtime/browsers/chromium/chrome-headless-shell \
  && test "$(/tmp/ankole-browser-runtime/node/bin/node --version)" = "v${BROWSER_NODE_VERSION}"

FROM ${BASE_IMAGE}

ARG LARK_CLI_VERSION=v1.0.69
ARG BROWSER_NODE_VERSION
ARG TARGETARCH
ARG ANKOLE_RELEASE_REVISION=development
ARG ANKOLE_RUNTIME_FABRIC_PROTOCOL_VERSION=4

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

COPY --from=build /repo/app/kernel/index.js ./app/kernel/index.js
COPY --from=build /repo/app/kernel/main.js ./app/kernel/main.js
COPY --from=build /repo/app/kernel/index.d.ts ./app/kernel/index.d.ts
COPY --from=build /repo/app/kernel/ankole-kernel.node ./app/kernel/ankole-kernel.node
COPY --from=build /repo/app/kernel/package.json ./app/kernel/package.json
COPY --from=build /repo/node_modules ./node_modules
COPY --from=build /repo/app/agent_computer/node_modules ./app/agent_computer/node_modules
COPY --from=build /repo/app/ankole-browser/node_modules ./app/ankole-browser/node_modules
COPY --from=build /tmp/ankole-browser-runtime /opt/ankole-browser
COPY tsconfig.base.json ./tsconfig.base.json
COPY app/library ./app/library

RUN set -eux; \
  PLAYWRIGHT_BROWSERS_PATH=/opt/ankole-browser/browsers \
    /opt/ankole-browser/node/bin/node \
    /opt/ankole-browser/node_modules/playwright-core/cli.js \
    install-deps chromium-headless-shell; \
  rm -rf /var/lib/apt/lists/*

COPY app/agent_computer/package.json ./app/agent_computer/package.json
COPY app/agent_computer/tsconfig.json ./app/agent_computer/tsconfig.json
COPY app/agent_computer/src ./app/agent_computer/src
COPY app/agent_computer/matplotlibrc /etc/ankole/matplotlibrc
COPY app/ankole-browser/package.json ./app/ankole-browser/package.json
COPY app/ankole-browser/src ./app/ankole-browser/src

RUN bun app/agent_computer/src/validation/lark-skill-examples.ts app/library/agent-plugins/lark/skills

RUN set -eux; \
  mkdir -p /agents /var/share; \
  chmod 0775 /agents; \
  chmod 1777 /var/share; \
  printf '%s\n' 'ankole-agent-computer' > /etc/ankole-agent-computer-container

RUN set -eux; \
  printf '%s\n' \
    'export CODEX_UNSAFE_ALLOW_NO_SANDBOX=1' \
    'if [ -n "${BASH_VERSION:-}" ]; then' \
    '  shopt -s expand_aliases 2>/dev/null || true' \
    'fi' \
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
  rm -f /usr/local/bin/node /usr/local/bun-node-fallback-bin/node; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec /opt/ankole-browser/node/bin/node /opt/ankole-browser/dist/cli/main.js "$@"' > /usr/local/bin/ankole-browser; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec /opt/ankole-browser/node/bin/node /opt/ankole-browser/dist/daemon/main.js "$@"' > /usr/local/bin/ankole-browserd; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/webhooks/webhook-cli.ts create "$@"' > /usr/local/bin/create-webhook-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/webhooks/webhook-cli.ts list "$@"' > /usr/local/bin/list-webhooks-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/webhooks/webhook-cli.ts cancel "$@"' > /usr/local/bin/cancel-webhook-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/automation-jobs/automation-job-cli.ts create "$@"' > /usr/local/bin/create-automation-job-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/automation-jobs/automation-job-cli.ts list "$@"' > /usr/local/bin/list-automation-jobs-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/automation-jobs/automation-job-cli.ts show "$@"' > /usr/local/bin/show-automation-job-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/automation-jobs/automation-job-cli.ts cancel "$@"' > /usr/local/bin/cancel-automation-job-cli; \
  codex_native="$(find -L /root/.bun/install/global/node_modules/@openai -path '*/vendor/*/bin/codex' -type f -print -quit)"; \
  test -n "$codex_native"; \
  ln -s "$codex_native" /usr/local/bin/apply_patch; \
  chmod +x /usr/local/bin/ankole-browser /usr/local/bin/ankole-browserd /usr/local/bin/create-webhook-cli /usr/local/bin/list-webhooks-cli /usr/local/bin/cancel-webhook-cli /usr/local/bin/create-automation-job-cli /usr/local/bin/list-automation-jobs-cli /usr/local/bin/show-automation-job-cli /usr/local/bin/cancel-automation-job-cli; \
  ! command -v node; \
  bun -e 'if (typeof Bun.TOML.stringify !== "function") throw new Error("Bun.TOML.stringify is required")'; \
  test "$(/opt/ankole-browser/node/bin/node --version)" = "v${BROWSER_NODE_VERSION}"; \
  /opt/ankole-browser/browsers/chromium/chrome-headless-shell --version >/dev/null; \
  ankole-browser --help >/dev/null; \
  patch_probe="$(mktemp -d)"; \
  cd "$patch_probe"; \
  printf '%s\n' '*** Begin Patch' '*** Add File: probe.txt' '+ok' '*** End Patch' | apply_patch; \
  test "$(cat probe.txt)" = "ok"; \
  rm -rf "$patch_probe"

WORKDIR /repo/app/agent_computer

ENV NODE_ENV=production
ENV ANKOLE_RELEASE_REVISION=${ANKOLE_RELEASE_REVISION}
ENV ANKOLE_RUNTIME_FABRIC_PROTOCOL_VERSION=${ANKOLE_RUNTIME_FABRIC_PROTOCOL_VERSION}
ENV CODEX_UNSAFE_ALLOW_NO_SANDBOX=1
ENV LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1
ENV LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1
ENV BASH_ENV=/etc/profile.d/ankole-agent-computer.sh
ENV ENV=/etc/profile.d/ankole-agent-computer.sh
ENV SHELL=/bin/bash
ENV ANKOLE_AGENTS_ROOT=/agents
ENV ANKOLE_BUILTIN_SKILLS_ROOT=/repo/app/library
ENV ANKOLE_AGENT_COMPUTER_BUN_WORKDIR=/repo/app/agent_computer
ENV ANKOLE_BROWSER_NODE=/opt/ankole-browser/node/bin/node
ENV ANKOLE_BROWSER_DAEMON_ENTRY=/opt/ankole-browser/dist/daemon/main.js
ENV ANKOLE_BROWSER_RUNNER=/opt/ankole-browser/dist/runner/bootstrap.js
ENV ANKOLE_BROWSER_CHROMIUM_EXECUTABLE=/opt/ankole-browser/browsers/chromium/chrome-headless-shell
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ankole-browser/browsers
ENV MATPLOTLIBRC=/etc/ankole/matplotlibrc
ENV PATH="/opt/ankole-python/bin:/root/.cargo/bin:${PATH}"

ENTRYPOINT ["tini", "-g", "--"]
CMD ["bun", "src/main.ts"]
