# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE
ARG OFFICECLI_VERSION=v1.0.158

FROM mcr.microsoft.com/dotnet/sdk:10.0.402 AS officecli-build

ARG OFFICECLI_VERSION
ARG TARGETARCH

WORKDIR /src
ADD --checksum=sha256:ef610ee83e81a13f39edaa1b7fa6eaa2697d90c2c1ed8e2c30f994a86bb7c1d7 \
  https://github.com/iOfficeAI/OfficeCLI/archive/2900a4a20f49d6a94384d6ea7fb8cc0120999825.tar.gz /tmp/officecli.tar.gz
COPY app/agent_computer/scripts/officecli-v1.0.158-screenshot.patch /tmp/officecli-screenshot.patch
COPY app/agent_computer/scripts/officecli-v1.0.158-data.patch /tmp/officecli-data.patch
COPY app/agent_computer/scripts/officecli-v1.0.158-editable-charts.patch /tmp/officecli-editable-charts.patch

RUN --mount=type=cache,target=/root/.nuget/packages \
  set -eux; \
  tar -xzf /tmp/officecli.tar.gz --strip-components=1; \
  git apply /tmp/officecli-screenshot.patch; \
  git apply /tmp/officecli-data.patch; \
  git apply /tmp/officecli-editable-charts.patch; \
  case "${TARGETARCH}" in \
    amd64) officecli_rid=linux-x64 ;; \
    arm64) officecli_rid=linux-arm64 ;; \
    *) echo "Unsupported OfficeCLI architecture: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  dotnet publish src/officecli/officecli.csproj -c Release -r "${officecli_rid}" -o /out --nologo; \
  test "$(OFFICECLI_SKIP_UPDATE=1 /out/officecli --version)" = "${OFFICECLI_VERSION#v}"

FROM --platform=linux/amd64 cloudflare/sandbox:1.0.0 AS directory-backup

FROM ${BASE_IMAGE} AS kernel-addon

ARG TARGETARCH

WORKDIR /repo

COPY app/kernel/Cargo.toml app/kernel/Cargo.lock app/kernel/build.rs ./app/kernel/
COPY app/kernel/src ./app/kernel/src
COPY app/kernel/scripts ./app/kernel/scripts

RUN --mount=type=cache,target=/root/.cargo/registry \
  --mount=type=cache,id=ankole-kernel-${TARGETARCH},target=/repo/app/kernel/target \
  bun app/kernel/scripts/build-node-addon.ts --release \
  && cp /repo/app/kernel/target/napi-build/ankole_kernel.node /tmp/ankole_kernel.node

FROM ${BASE_IMAGE} AS build

WORKDIR /repo

COPY package.json bun.lock ./
COPY app/agent_computer/package.json ./app/agent_computer/package.json
COPY app/ankole-browser/package.json ./app/ankole-browser/package.json
COPY app/kernel/package.json ./app/kernel/package.json
COPY libs/ankole-editor/package.json ./libs/ankole-editor/package.json
COPY libs/ankole-editor/patches ./libs/ankole-editor/patches
COPY libs/applet-sdk/package.json ./libs/applet-sdk/package.json
COPY libs/uikit/package.json ./libs/uikit/package.json

# Only the Worker and its workspace dependencies are present in this image.
RUN bun -e 'const p = await Bun.file("package.json").json(); p.workspaces = ["app/agent_computer", "app/ankole-browser", "app/kernel", "libs/ankole-editor", "libs/applet-sdk", "libs/uikit"]; await Bun.write("package.json", JSON.stringify(p));'

RUN --mount=type=cache,target=/root/.bun/install/cache \
  set -eux; \
  for attempt in 1 2 3; do \
    if timeout 120s bun install --no-save; then exit 0; fi; \
    rm -rf /tmp/bun-*; \
    sleep $((attempt * 5)); \
  done; \
  timeout 120s bun install --no-save

RUN set -eux; \
  mkdir -p /tmp/ankole-browser-runtime/node_modules; \
  cp app/ankole-browser/package.json /tmp/ankole-browser-runtime/package.json; \
  cp -RL app/ankole-browser/node_modules/playwright-core /tmp/ankole-browser-runtime/node_modules/playwright-core; \
  PLAYWRIGHT_BROWSERS_PATH=/tmp/ankole-browser-runtime/browsers \
    bun app/ankole-browser/node_modules/playwright-core/cli.js install chromium-headless-shell; \
  browser_bin="$(find /tmp/ankole-browser-runtime/browsers -type f \
    \( -name headless_shell -o -name chrome-headless-shell \) -perm /111 -print -quit)"; \
  test -n "${browser_bin}"; \
  mkdir -p /tmp/ankole-browser-runtime/browsers/chromium; \
  ln -s "$(realpath --relative-to=/tmp/ankole-browser-runtime/browsers/chromium "${browser_bin}")" \
    /tmp/ankole-browser-runtime/browsers/chromium/chrome-headless-shell

COPY --from=kernel-addon /tmp/ankole_kernel.node ./app/kernel/target/napi-build/ankole_kernel.node
COPY app/kernel/node.ts ./app/kernel/node.ts
COPY app/ankole-browser ./app/ankole-browser

WORKDIR /repo/app/ankole-browser

RUN rm -rf dist /tmp/ankole-browser-runtime/dist \
  && bun build src/cli/main.ts src/daemon/main.ts src/runner/bootstrap.ts --target=bun --outdir dist --external playwright-core \
  && cp -R dist /tmp/ankole-browser-runtime/dist

WORKDIR /repo

COPY libs/ankole-editor/src ./libs/ankole-editor/src
COPY libs/ankole-editor/upstream ./libs/ankole-editor/upstream
COPY libs/applet-sdk/src ./libs/applet-sdk/src
COPY libs/uikit/src ./libs/uikit/src

FROM ${BASE_IMAGE}

ARG LARK_CLI_VERSION=v1.0.98
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

COPY --from=build /tmp/ankole-browser-runtime/browsers /opt/ankole-browser/browsers

RUN --mount=from=build,source=/tmp/ankole-browser-runtime/node_modules/playwright-core,target=/tmp/playwright-core \
  set -eux; \
  PLAYWRIGHT_BROWSERS_PATH=/opt/ankole-browser/browsers \
    bun \
    /tmp/playwright-core/cli.js \
    install-deps chromium-headless-shell; \
  ln -s /opt/ankole-browser/browsers/chromium/chrome-headless-shell /usr/local/bin/chromium; \
  rm -rf /var/lib/apt/lists/*

# Release CLIs stay in this image. A version change rebuilds the Worker image
# on the current Agent OS base. The base keeps the compiled toolchain, the
# Python stack, fonts, and database clients.
ARG CODEX_VERSION=0.164.0
ARG MCPORTER_VERSION=0.16.0
ARG OFFICECLI_VERSION
ARG TYPST_VERSION=v0.15.1
ARG KUBECTL_VERSION=v1.37.1
ARG AWS_CLI_VERSION=2.38.5

RUN set -eux; \
  mcporter_package="/tmp/mcporter-${MCPORTER_VERSION}.tgz"; \
  curl -fsSL --retry 3 --retry-delay 2 \
    "https://github.com/openclaw/mcporter/releases/download/v${MCPORTER_VERSION}/mcporter-${MCPORTER_VERSION}.tgz" \
    -o "$mcporter_package"; \
  installed=0; \
  for attempt in 1 2 3; do \
    if bun add -g "@openai/codex@${CODEX_VERSION}" "$mcporter_package"; then installed=1; break; fi; \
    rm -rf /root/.bun/install/cache/* /tmp/bun-*; \
    sleep $((attempt * 5)); \
  done; \
  test "$installed" = 1; \
  rm -f /usr/local/bin/codex /usr/local/bin/mcporter; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec /usr/local/bin/bun /root/.bun/install/global/node_modules/@openai/codex/bin/codex.js "$@"' > /usr/local/bin/codex; \
  printf '%s\n' '#!/usr/bin/env sh' 'exec /usr/local/bin/bun /root/.bun/install/global/node_modules/mcporter/dist/cli.js "$@"' > /usr/local/bin/mcporter; \
  chmod +x /usr/local/bin/codex /usr/local/bin/mcporter; \
  test "$(codex --version)" = "codex-cli ${CODEX_VERSION}"; \
  test "$(mcporter --version)" = "${MCPORTER_VERSION}"; \
  rm -f "$mcporter_package"

COPY --from=officecli-build /out/officecli /usr/local/bin/officecli

RUN set -eux; \
  chmod +x /usr/local/bin/officecli; \
  test "$(officecli --version)" = "${OFFICECLI_VERSION#v}"

# Typst is not packaged for Debian trixie, so the pinned release binary is
# installed here.
RUN set -eux; \
  case "${TARGETARCH:-$(uname -m)}" in \
    amd64|x86_64) typst_asset="typst-x86_64-unknown-linux-musl" ;; \
    arm64|aarch64) typst_asset="typst-aarch64-unknown-linux-musl" ;; \
    *) echo "Unsupported Typst architecture: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
  esac; \
  curl -fsSL "https://github.com/typst/typst/releases/download/${TYPST_VERSION}/${typst_asset}.tar.xz" \
    -o /tmp/typst.tar.xz; \
  tar -xJf /tmp/typst.tar.xz -C /tmp; \
  install -m 0755 "/tmp/${typst_asset}/typst" /usr/local/bin/typst; \
  rm -rf /tmp/typst.tar.xz "/tmp/${typst_asset}"; \
  typst --version | grep -qF "typst ${TYPST_VERSION#v}"

RUN set -eux; \
  case "${TARGETARCH:-$(uname -m)}" in \
    amd64|x86_64) kubectl_arch=amd64 ;; \
    arm64|aarch64) kubectl_arch=arm64 ;; \
    *) echo "Unsupported kubectl architecture: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
  esac; \
  kubectl_base_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${kubectl_arch}"; \
  curl -fsSL --retry 5 --retry-all-errors "${kubectl_base_url}/kubectl" -o /tmp/kubectl; \
  install -m 0755 /tmp/kubectl /usr/local/bin/kubectl; \
  test "$(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')" = "${KUBECTL_VERSION}"; \
  rm -f /tmp/kubectl

RUN set -eux; \
  case "${TARGETARCH:-$(uname -m)}" in \
    amd64|x86_64) aws_arch=x86_64 ;; \
    arm64|aarch64) aws_arch=aarch64 ;; \
    *) echo "Unsupported AWS CLI architecture: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
  esac; \
  aws_asset="awscli-exe-linux-${aws_arch}-${AWS_CLI_VERSION}.zip"; \
  curl -fsSL --retry 5 --retry-all-errors "https://awscli.amazonaws.com/${aws_asset}" \
    -o /tmp/awscliv2.zip; \
  unzip -q /tmp/awscliv2.zip -d /tmp; \
  /tmp/aws/install --install-dir /usr/local/aws-cli --bin-dir /usr/local/bin; \
  aws --version | grep -qF "aws-cli/${AWS_CLI_VERSION} "; \
  rm -rf /tmp/aws /tmp/awscliv2.zip

RUN set -eux; \
  usermod -l agent -d /workspace -s /bin/bash bun; \
  groupmod -n agent bun; \
  mkdir -p /agents /workspace /var/cache/ankole/codex /var/share /run/ankole-browser; \
  chown 1000:1000 /agents /workspace /var/cache/ankole /var/cache/ankole/codex /run/ankole-browser; \
  chmod 0755 /agents /workspace /var/cache/ankole; \
  chmod 1777 /var/share; \
  printf '%s\n' 'ankole-agent-computer' > /etc/ankole-agent-computer-container

COPY --from=build /repo/node_modules ./node_modules
COPY --from=build /repo/app/agent_computer/node_modules ./app/agent_computer/node_modules
COPY --from=build /repo/app/ankole-browser/node_modules ./app/ankole-browser/node_modules
COPY --from=build /repo/libs ./libs
COPY --from=build /tmp/ankole-browser-runtime/package.json /opt/ankole-browser/package.json
COPY --from=build /tmp/ankole-browser-runtime/node_modules /opt/ankole-browser/node_modules
COPY --from=build /tmp/ankole-browser-runtime/dist /opt/ankole-browser/dist
COPY tsconfig.base.json ./tsconfig.base.json
COPY app/library ./app/library

RUN chmod -R a+rX,go-w /repo/app/library

COPY app/agent_computer/package.json ./app/agent_computer/package.json
COPY app/agent_computer/tsconfig.json ./app/agent_computer/tsconfig.json
COPY app/agent_computer/src ./app/agent_computer/src
COPY app/agent_computer/matplotlibrc /etc/ankole/matplotlibrc
COPY app/ankole-browser/package.json ./app/ankole-browser/package.json
COPY app/ankole-browser/src ./app/ankole-browser/src

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
  printf '%s\n' '#!/usr/bin/env sh' 'exec bun /repo/app/agent_computer/src/cli/pod/pod-cli.ts "$@"' > /usr/local/bin/ankole-pod; \
  codex_native="$(find -L /root/.bun/install/global/node_modules/@openai -path '*/vendor/*/bin/codex' -type f -print -quit)"; \
  test -n "$codex_native"; \
  ln -s "$codex_native" /usr/local/bin/apply_patch; \
  chmod +x /usr/local/bin/ankole-browser /usr/local/bin/ankole-browserd /usr/local/bin/create-webhook-cli /usr/local/bin/list-webhooks-cli /usr/local/bin/cancel-webhook-cli /usr/local/bin/create-automation-job-cli /usr/local/bin/list-automation-jobs-cli /usr/local/bin/show-automation-job-cli /usr/local/bin/cancel-automation-job-cli /usr/local/bin/ankole-files /usr/local/bin/ankole-pod; \
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
  env -0 \
    -u PWD \
    -u HTTP_PROXY \
    -u http_proxy \
    -u HTTPS_PROXY \
    -u https_proxy \
    -u FTP_PROXY \
    -u ftp_proxy \
    -u ALL_PROXY \
    -u all_proxy \
    -u NO_PROXY \
    -u no_proxy \
    -u LARK_CLI_VERSION \
    -u TARGETARCH \
    -u CODEX_VERSION \
    -u MCPORTER_VERSION \
    -u OFFICECLI_VERSION \
    -u TYPST_VERSION \
    -u KUBECTL_VERSION \
    -u AWS_CLI_VERSION \
    > /etc/ankole/worker-environ

ENTRYPOINT ["ankole-worker-entry"]
CMD ["bun", "src/main.ts"]
