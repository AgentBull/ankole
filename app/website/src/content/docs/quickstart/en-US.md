---
title: Quick start
description: Prepare the toolchain and run the complete Ankole development environment from source.
section: Getting started
order: 2
---

This page is the short path to a local source install. The repository [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) stays the source of truth for environment preparation, product setup, Feishu/Lark configuration, troubleshooting, and end-to-end acceptance — come back here when a step needs more detail.

A complete local environment runs PostgreSQL, the Phoenix/OTP control plane, the web Console, frontend assets, and one managed Docker Agent Computer Worker.

## Who this is for

You want to run Ankole from source on your own machine: develop against it, reproduce an issue, or see every component running before you deploy. If you only want a running installation, skip ahead to the [installation guide](../installation/) and use Docker Compose or Helm.

## Choose a supported environment

Use macOS or Linux. On Windows, use WSL2. You need an account that can install system packages, a stable network connection, and:

- Docker Desktop on macOS, or Docker Engine with Compose on Linux;
- an LLM provider API key for a real agent turn;
- a Feishu account that can create an enterprise custom application, if you want to run the documented end-to-end test.

GitHub Codespaces works for code and test work. The baseline Feishu walkthrough assumes the browser and Ankole both use `localhost:4000`, so adapt and verify the callbacks when Codespaces hands you a forwarded HTTPS origin.

## Clone and inspect the repository

```bash
git clone https://github.com/AgentBull/ankole.git
cd ankole
git status --short
```

Run every remaining command from the repository root unless a step says otherwise.

## Install and verify the system tools

Look over the installer first, then run it:

```bash
bash tools/devkit/scripts/env-setup.sh
```

The script installs system build packages, Docker, a stable Rust toolchain with `rustfmt` and `clippy`, the repository's Elixir/Erlang toolchain, and the Bun version pinned by the repository.

Open a fresh terminal when it finishes. On macOS, start Docker Desktop. On Linux, log out and back in if the installer added your user to the `docker` group. Then, back at the repository root, verify each tool:

```bash
bun --version
elixir --version
rustc --version
cargo clippy --version
docker compose version
docker info
```

`bun --version` must match `packageManager` in the root `package.json`. Every other command must succeed, and `docker info` must reach the daemon. If any check fails, stop and fix it before moving on — the later steps assume all of these work.

## Install dependencies and initialize PostgreSQL

Run these in order:

```bash
bun install
bun run services:start
bun run services:status
bun run control-plane:setup
```

They install workspace and Elixir dependencies, start the devkit PostgreSQL Compose service, create the development database, apply Ecto migrations, and load seeds. The first Elixir compile can take a few minutes.

One thing worth saying out loud: do not reset the database because a setup command failed. Keep the first actionable error and work through it in the order `CONTRIBUTING.md` describes.

## Start the complete development environment

```bash
bun dev
```

Keep this terminal open. The devkit starts or verifies PostgreSQL, creates and migrates the local database, builds a missing or stale Worker image, starts Phoenix and the frontend assets, and starts one managed Docker Worker.

From another terminal, confirm the visible boundaries:

```bash
bun run services:status
curl -I http://localhost:4000/
docker ps --filter name=ankole-dev-agent-computer
```

Open [http://localhost:4000](http://localhost:4000). Do not start a second `bun dev`. Stop the managed control plane and Worker with `Ctrl+C` in the original terminal. PostgreSQL keeps running; stop it separately when you are done:

```bash
bun run services:stop
```

## Complete product setup and acceptance

On first visit, use the page's reprint action and read `SETUP ACTIVATION CODE` from the `bun dev` terminal. If you need it from another terminal:

```bash
bun run kit show bootstrap-activation-code
```

The local environment is technically up when PostgreSQL is healthy, the HTTP page opens, and `ankole-dev-agent-computer` stays running. A complete product setup needs more than that:

1. the first administrator signs in;
2. one usable LLM provider and one Agent exist;
3. a Signal binding is enabled;
4. `local-dev-worker` is ready;
5. a real Feishu/Lark message reaches the Agent and returns the expected reply.

Follow the exact permissions, events, callbacks, Console fields, and acceptance message in [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md). A visible page or a running container is not proof that the end-to-end path works.

For a production deployment, continue to the [installation guide](../installation/).
