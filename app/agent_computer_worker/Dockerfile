FROM oven/bun:1.3.14 AS build

WORKDIR /repo

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    libzmq3-dev \
    pkg-config \
    protobuf-compiler \
  && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal

ENV PATH="/root/.cargo/bin:${PATH}"

COPY app/kernel ./app/kernel
COPY app/agent_computer_worker ./app/agent_computer_worker

WORKDIR /repo/app/kernel

RUN bun install --no-save \
  && bun run build:bun

FROM oven/bun:1.3.14

WORKDIR /repo

RUN apt-get update \
  && apt-get install -y --no-install-recommends libzmq5 \
  && mkdir -p /workspace/user-files /workspace/temp /workspace/library-containers \
  && chmod -R 0775 /workspace \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /repo/app/kernel/index.js ./app/kernel/index.js
COPY --from=build /repo/app/kernel/main.js ./app/kernel/main.js
COPY --from=build /repo/app/kernel/index.d.ts ./app/kernel/index.d.ts
COPY --from=build /repo/app/kernel/ankole-kernel.node ./app/kernel/ankole-kernel.node
COPY --from=build /repo/app/kernel/package.json ./app/kernel/package.json
COPY app/agent_computer_worker ./app/agent_computer_worker

WORKDIR /repo/app/agent_computer_worker

ENV NODE_ENV=production
ENV ANKOLE_WORKSPACE_ROOT=/workspace

CMD ["bun", "src/main.ts"]
