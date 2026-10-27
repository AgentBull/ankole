# syntax=docker/dockerfile:1.7
ARG EDGE_RUNTIME_IMAGE=native

FROM rust:1.99.1-bookworm AS native
ARG TARGETPLATFORM
RUN apt-get update && apt-get install -y --no-install-recommends llvm-dev libclang-dev clang cmake binutils libblas-dev liblapack-dev libopenblas-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /usr/src/edge-runtime
ADD --checksum=sha256:04e4094f95bee6fff928a29e9e9d66e45e3ef2ce8719b19fb6bf7fe92e5b7721 https://codeload.github.com/supabase/edge-runtime/tar.gz/d4a4f606a90e8c66864219c9b1d31ef0e3e3f626 /tmp/edge-runtime.tar.gz
RUN tar -xzf /tmp/edge-runtime.tar.gz --strip-components=1 -C . && rm /tmp/edge-runtime.tar.gz
COPY app/function_runtime/native/patches /tmp/ankole-patches
RUN for patch in /tmp/ankole-patches/*.patch; do git apply --check "$patch" && git apply "$patch"; done
RUN --mount=type=cache,target=/usr/local/cargo/registry,id=ankole-edge-registry-${TARGETPLATFORM} --mount=type=cache,target=/usr/local/cargo/git,id=ankole-edge-git-${TARGETPLATFORM} --mount=type=cache,target=/usr/src/edge-runtime/target,id=ankole-edge-target-${TARGETPLATFORM} GIT_V_TAG=v1.77.4-ankole.1 CARGO_BUILD_JOBS=4 cargo build --release --locked --bin edge-runtime && mkdir -p /usr/local/bin && cp target/release/edge-runtime /usr/local/bin/edge-runtime && objcopy --strip-debug /usr/local/bin/edge-runtime

FROM ${EDGE_RUNTIME_IMAGE} AS edge-runtime-binary

FROM oven/bun:1.4.4 AS build
WORKDIR /build
COPY package.json bun.lock ./
COPY app/function_runtime/package.json ./app/function_runtime/package.json
COPY libs/applet-sdk/package.json ./libs/applet-sdk/package.json
COPY libs/ankole-editor/patches ./libs/ankole-editor/patches
RUN bun install --filter @ankole/function-runtime --production --frozen-lockfile --ignore-scripts
COPY app/function_runtime/main ./app/function_runtime/main
COPY libs/applet-sdk/src ./libs/applet-sdk/src
RUN bun build app/function_runtime/main/index.ts --target=browser --external=node:* --outdir=build

FROM ghcr.io/supabase/edge-runtime:v1.77.4
ARG RELEASE_REVISION
ARG RUNTIME_FABRIC_PROTOCOL_VERSION
LABEL org.opencontainers.image.revision=$RELEASE_REVISION
LABEL io.ankole.runtime-fabric.protocol-version=$RUNTIME_FABRIC_PROTOCOL_VERSION
COPY --from=edge-runtime-binary /usr/local/bin/edge-runtime /usr/local/bin/edge-runtime
COPY app/function_runtime/native/LICENSE /usr/share/licenses/edge-runtime/LICENSE
COPY --from=build /build/build/index.js /opt/ankole/function_runtime/main/index.js
CMD ["start", "--main-service", "/opt/ankole/function_runtime/main", "--port", "9000"]
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=6 CMD bash -ec 'exec 3<>/dev/tcp/127.0.0.1/9000; printf "GET /_internal/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3; head -n 1 <&3 | grep -q " 200 "'
