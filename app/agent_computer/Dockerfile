# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE

FROM --platform=linux/amd64 cloudflare/sandbox:1.0.0 AS directory-backup

FROM ${BASE_IMAGE} AS build

WORKDIR /repo

COPY package.json bun.lock ./
COPY app/agent_computer/package.json ./app/agent_computer/package.json
COPY app/ankole-browser/package.json ./app/ankole-browser/package.json

# Only the Worker and its workspace dependencies are present in this image.
RUN bun -e 'const p = await Bun.file("package.json").json(); p.workspaces = ["app/agent_computer", "app/ankole-browser"]; delete p.patchedDependencies["mdast-util-to-markdown@2.2.0"]; await Bun.write("package.json", JSON.stringify(p));'

RUN --mount=type=cache,target=/root/.bun/install/cache \
  set -eux; \
  for attempt in 1 2 3; do \
    if timeout 120s bun install --no-save; then exit 0; fi; \
    rm -rf /tmp/bun-*; \
    sleep $((attempt * 5)); \
  done; \
  timeout 120s bun install --no-save

COPY app/agent_computer ./app/agent_computer
COPY app/ankole-browser ./app/ankole-browser

WORKDIR /repo/app/ankole-browser

RUN bun run build \
  && mkdir -p /tmp/ankole-browser-runtime/node_modules \
  && cp package.json /tmp/ankole-browser-runtime/package.json \
  && cp -R dist /tmp/ankole-browser-runtime/dist \
  && cp -RL node_modules/playwright-core /tmp/ankole-browser-runtime/node_modules/playwright-core \
  && PLAYWRIGHT_BROWSERS_PATH=/tmp/ankole-browser-runtime/browsers \
    bun node_modules/playwright-core/cli.js install chromium-headless-shell \
  && browser_bin="$(find /tmp/ankole-browser-runtime/browsers -type f \
    \( -name headless_shell -o -name chrome-headless-shell \) -perm /111 -print -quit)" \
  && test -n "${browser_bin}" \
  && mkdir -p /tmp/ankole-browser-runtime/browsers/chromium \
  && ln -s "$(realpath --relative-to=/tmp/ankole-browser-runtime/browsers/chromium "${browser_bin}")" \
    /tmp/ankole-browser-runtime/browsers/chromium/chrome-headless-shell

FROM ${BASE_IMAGE}

ARG LARK_CLI_VERSION=v1.0.93
ARG TARGETARCH
ARG ANKOLE_RELEASE_REVISION=development

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
  curl -fsSL "${base_url}/${asset}" -o "/tmp/${asset}"; \
  mkdir -p /tmp/lark-cli /usr/local/libexec; \
  tar -xzf "/tmp/${asset}" -C /tmp/lark-cli; \
  install -m 0755 /tmp/lark-cli/lark-cli /usr/local/libexec/lark-cli; \
  test "$(/usr/local/libexec/lark-cli --version)" = "lark-cli version ${version}"; \
  rm -rf /tmp/lark-cli "/tmp/${asset}"

COPY app/agent_computer/scripts/lark-cli.sh /usr/local/bin/lark-cli
COPY app/agent_computer/scripts/ankole-worker-supervisor.sh /usr/local/bin/ankole-worker-supervisor
COPY app/agent_computer/scripts/ankole-worker-entry.sh /usr/local/bin/ankole-worker-entry
COPY app/agent_computer/scripts/ankole-worker-command-entry.sh /usr/local/bin/ankole-worker-command-entry
COPY app/agent_computer/scripts/ankole-worker-nfs.sh /usr/local/bin/ankole-worker-nfs
COPY app/agent_computer/scripts/function-compute-resume-oss.py /usr/local/libexec/function-compute-resume-oss.py
COPY --from=directory-backup /usr/local/bin/sandbox-shim /usr/local/bin/sandbox-shim

RUN chmod 0755 /usr/local/bin/lark-cli /usr/local/bin/ankole-worker-supervisor /usr/local/bin/ankole-worker-entry /usr/local/bin/ankole-worker-command-entry /usr/local/bin/ankole-worker-nfs \
  && test "$(lark-cli --version)" = "lark-cli version ${LARK_CLI_VERSION#v}"

RUN apt-get update \
  && apt-get install -y --no-install-recommends nfs-common iproute2 \
  && rm -rf /var/lib/apt/lists/*

# Function Compute uses amd64 and does not install OSSFS2 in custom images.
RUN set -eux; \
  if [ "${TARGETARCH}" = amd64 ]; then \
    apt-get update; \
    curl -fsSL https://gosspublic.alicdn.com/ossfs/ossfs2_2.0.10_linux_x86_64.deb -o /tmp/ossfs2.deb; \
    echo '72e864b8087d6f889c5017339c625154619f626bbc13c9afcb70403544ad9b70  /tmp/ossfs2.deb' | sha256sum -c -; \
    apt-get install -y --no-install-recommends fuse3 /tmp/ossfs2.deb; \
    ossfs2 --version; \
    fusermount3 --version; \
    rm -rf /tmp/ossfs2.deb /var/lib/apt/lists/*; \
  fi

COPY --from=build /repo/node_modules ./node_modules
COPY --from=build /repo/app/agent_computer/node_modules ./app/agent_computer/node_modules
COPY --from=build /repo/app/ankole-browser/node_modules ./app/ankole-browser/node_modules
COPY --from=build /tmp/ankole-browser-runtime /opt/ankole-browser
COPY tsconfig.base.json ./tsconfig.base.json
COPY app/library ./app/library

RUN chmod -R a+rX,go-w /repo/app/library

RUN set -eux; \
  PLAYWRIGHT_BROWSERS_PATH=/opt/ankole-browser/browsers \
    bun \
    /opt/ankole-browser/node_modules/playwright-core/cli.js \
    install-deps chromium-headless-shell; \
  rm -rf /var/lib/apt/lists/*

COPY app/agent_computer/package.json ./app/agent_computer/package.json
COPY app/agent_computer/tsconfig.json ./app/agent_computer/tsconfig.json
COPY app/agent_computer/src ./app/agent_computer/src
COPY app/agent_computer/matplotlibrc /etc/ankole/matplotlibrc
COPY app/ankole-browser/package.json ./app/ankole-browser/package.json
COPY app/ankole-browser/src ./app/ankole-browser/src

RUN set -eux; \
  usermod -l agent -d /workspace -s /bin/bash bun; \
  groupmod -n agent bun; \
  mkdir -p /agents /workspace /var/cache/ankole/codex /var/share /run/ankole-browser; \
  chown 1000:1000 /agents /workspace /var/cache/ankole /var/cache/ankole/codex /run/ankole-browser; \
  chmod 0755 /agents /workspace /var/cache/ankole; \
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
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /opt/ankole-browser/dist/cli/main.js "$@"' > /usr/local/bin/ankole-browser; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /opt/ankole-browser/dist/daemon/main.js "$@"' > /usr/local/bin/ankole-browserd; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/webhooks/webhook-cli.ts create "$@"' > /usr/local/bin/create-webhook-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/webhooks/webhook-cli.ts list "$@"' > /usr/local/bin/list-webhooks-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/webhooks/webhook-cli.ts cancel "$@"' > /usr/local/bin/cancel-webhook-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/automation-jobs/automation-job-cli.ts create "$@"' > /usr/local/bin/create-automation-job-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/automation-jobs/automation-job-cli.ts list "$@"' > /usr/local/bin/list-automation-jobs-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/automation-jobs/automation-job-cli.ts show "$@"' > /usr/local/bin/show-automation-job-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/automation-jobs/automation-job-cli.ts cancel "$@"' > /usr/local/bin/cancel-automation-job-cli; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/drive/drive-cli.ts "$@"' > /usr/local/bin/ankole-files; \
  codex_native="$(find -L /root/.bun/install/global/node_modules/@openai -path '*/vendor/*/bin/codex' -type f -print -quit)"; \
  test -n "$codex_native"; \
  ln -s "$codex_native" /usr/local/bin/apply_patch; \
  chmod +x /usr/local/bin/ankole-browser /usr/local/bin/ankole-browserd /usr/local/bin/create-webhook-cli /usr/local/bin/list-webhooks-cli /usr/local/bin/cancel-webhook-cli /usr/local/bin/create-automation-job-cli /usr/local/bin/list-automation-jobs-cli /usr/local/bin/show-automation-job-cli /usr/local/bin/cancel-automation-job-cli /usr/local/bin/ankole-files; \
  ! command -v node; \
  bun -e 'if (typeof Bun.TOML.stringify !== "function") throw new Error("Bun.TOML.stringify is required")'; \
  /opt/ankole-browser/browsers/chromium/chrome-headless-shell --version >/dev/null; \
  ankole-browser --help >/dev/null; \
  patch_probe="$(mktemp -d)"; \
  cd "$patch_probe"; \
  printf '%s\n' '*** Begin Patch' '*** Add File: probe.txt' '+ok' '*** End Patch' | apply_patch; \
  test "$(cat probe.txt)" = "ok"; \
  rm -rf "$patch_probe"

# The base installs build tools under /root. Runtime tools must also be
# readable by uid 1000, with root as their only writer.
RUN set -eux; \
  mv /root/.bun/install/global /opt/ankole-cli; \
  mv /root/.cargo /opt/ankole-cargo; \
  mv /root/.rustup /opt/ankole-rustup; \
  sed -i 's|/root/.bun/install/global|/opt/ankole-cli|g' /usr/local/bin/codex /usr/local/bin/mcporter; \
  codex_native="$(find -L /opt/ankole-cli/node_modules/@openai -path '*/vendor/*/bin/codex' -type f -print -quit)"; \
  test -n "$codex_native"; \
  ln -sf "$codex_native" /usr/local/bin/apply_patch; \
  ! command -v sudo

WORKDIR /repo/app/agent_computer

ENV NODE_ENV=production
ENV ANKOLE_RELEASE_REVISION=${ANKOLE_RELEASE_REVISION}
ENV CODEX_UNSAFE_ALLOW_NO_SANDBOX=1
ENV LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1
ENV LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1
ENV BASH_ENV=/etc/profile.d/ankole-agent-computer.sh
ENV ENV=/etc/profile.d/ankole-agent-computer.sh
ENV SHELL=/bin/bash
ENV HOME=/workspace
ENV CODEX_HOME=/workspace/.codex
ENV CODEX_SQLITE_HOME=/var/cache/ankole/codex
ENV RUSTUP_HOME=/opt/ankole-rustup
ENV CARGO_HOME=/opt/ankole-cargo
ENV ANKOLE_AGENT_COMPUTER_BUN_WORKDIR=/repo/app/agent_computer
ENV ANKOLE_BUILTIN_SKILLS_ROOT=/repo/app/library
ENV ANKOLE_BROWSER_DAEMON_ENTRY=/opt/ankole-browser/dist/daemon/main.js
ENV ANKOLE_BROWSER_RUNNER=/opt/ankole-browser/dist/runner/bootstrap.js
ENV ANKOLE_BROWSER_CHROMIUM_EXECUTABLE=/opt/ankole-browser/browsers/chromium/chrome-headless-shell
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ankole-browser/browsers
ENV MATPLOTLIBRC=/etc/ankole/matplotlibrc
ENV PATH="/opt/ankole-python/bin:/opt/ankole-cargo/bin:/usr/local/bin:/usr/bin:/bin"

# A launcher can replace this environment, for example sudo on Function
# Compute. The entrypoint exports this copy, which has the format of
# /proc/<pid>/environ. The copy excludes the PWD of the build shell and the
# build arguments of this stage. Keep build caches out of the empty OSS mount
# point, including Rosetta caches from an amd64 build on macOS.
RUN --mount=type=tmpfs,target=/workspace \
  env -0 -u PWD -u LARK_CLI_VERSION -u TARGETARCH > /etc/ankole/worker-environ

ENTRYPOINT ["ankole-worker-entry"]
CMD ["bun", "src/main.ts"]
