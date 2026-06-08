# syntax=docker/dockerfile:1
# Build the bullx-computerd daemon, then ship it on a slim image with bubblewrap.
# Build context is the package root (packages/computer).

FROM rust:1-bookworm AS builder
# aws-lc-rs (via jsonwebtoken / rustls) needs cmake + a C toolchain.
RUN apt-get update \
  && apt-get install -y --no-install-recommends cmake \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --bin bullx-computerd

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends bubblewrap bash coreutils ca-certificates curl python3 python-is-python3 tmux \
  && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/target/release/bullx-computerd /usr/local/bin/bullx-computerd
ENV BULLX_COMPUTER_WORKSPACE_ROOT=/workspaces \
    BULLX_COMPUTER_PORT=8787
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/bullx-computerd"]
