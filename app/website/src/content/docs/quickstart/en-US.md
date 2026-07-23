---
title: Quick start
description: Prepare the supported toolchains and run the complete Ankole development environment from source.
section: Getting started
order: 2
---

This page is the short path for a local source installation. The repository
[`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)
is the source of truth for environment preparation, product setup, Feishu/Lark
configuration, troubleshooting, and end-to-end acceptance.

A complete local environment runs PostgreSQL, the Phoenix/OTP control plane,
the web Console, frontend assets, and one managed Docker Agent Computer Worker.

## Choose a supported environment

Use macOS or Linux. On Windows, use WSL2. You need an account that can install
system packages, a stable network connection, and:

- Docker Desktop on macOS, or Docker Engine with Compose on Linux;
- an LLM provider API key for a real Agent turn;
- a Feishu account that can create an enterprise custom application if you
  want to complete the documented end-to-end test.

GitHub Codespaces is suitable for code and test work. The baseline Feishu
walkthrough assumes that the browser and Ankole use `localhost:4000`, so adapt
and verify callbacks when Codespaces provides a forwarded HTTPS origin.

## Clone and inspect the repository

```bash
git clone https://github.com/AgentBull/ankole.git
cd ankole
git status --short
```

Run all remaining commands from the repository root unless a command says
otherwise.

## Install and verify the system tools

Inspect the repository installer, then run it:

```bash
bash tools/devkit/scripts/env-setup.sh
```

The script installs system build packages, Docker, stable Rust with `rustfmt`
and `clippy`, the repository Elixir/Erlang toolchain, and the Bun version pinned
by the repository.

Open a new terminal after the installer finishes. On macOS, start Docker
Desktop. On Linux, log out and back in if the installer added your user to the
`docker` group. Return to the repository root and verify:

```bash
bun --version
elixir --version
rustc --version
cargo clippy --version
docker compose version
docker info
```

`bun --version` must match `packageManager` in the root `package.json`. Every
other command must succeed, and `docker info` must connect to the daemon. Do not
continue while a tool check fails.

## Install dependencies and initialize PostgreSQL

Run these commands in order:

```bash
bun install
bun run services:start
bun run services:status
bun run control-plane:setup
```

They install workspace and Elixir dependencies, start the devkit PostgreSQL
Compose service, create the development database, apply Ecto migrations, and
load seeds. The first Elixir compile can take several minutes.

Do not reset the database because one setup command failed. Keep the first
actionable error and follow the troubleshooting order in `CONTRIBUTING.md`.

## Start the complete development environment

```bash
bun dev
```

Keep this terminal open. The devkit starts or verifies PostgreSQL, creates and
migrates the local database, builds a missing or stale Worker image, starts
Phoenix and frontend assets, and starts one managed Docker Worker.

In another terminal, verify the visible boundaries:

```bash
bun run services:status
curl -I http://localhost:4000/
docker ps --filter name=ankole-dev-agent-computer
```

Open [http://localhost:4000](http://localhost:4000). Do not start a second
`bun dev`. Stop the managed control plane and Worker with `Ctrl+C` in the
original terminal. PostgreSQL remains running; stop it separately with:

```bash
bun run services:stop
```

## Complete product setup and acceptance

On the first visit, use the page's reprint action and read
`SETUP ACTIVATION CODE` from the `bun dev` terminal. If necessary, read the
current code from another terminal:

```bash
bun run kit show bootstrap-activation-code
```

The local environment is technically running when PostgreSQL is healthy, the
HTTP page opens, and `ankole-dev-agent-computer` stays running. A complete
product setup also needs:

1. the first administrator to sign in;
2. one usable LLM provider and Agent;
3. an enabled Signal binding;
4. `local-dev-worker` to be ready;
5. a real Feishu/Lark message to reach the Agent and return the expected reply.

Follow the exact permissions, events, callbacks, Console fields, and acceptance
message in
[`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md).
Do not treat a visible page or a running container as proof of the full
end-to-end result.

For production deployment, continue to the [installation guide](../installation/).
