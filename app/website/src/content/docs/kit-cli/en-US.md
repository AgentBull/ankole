---
title: kit CLI reference
description: The devkit command surface — every `bun run kit` command an operator or contributor runs, what it does, and the scripts that wrap it.
section: Reference
order: 200
---

`kit` is the devkit command line for Ankole. It is invoked as `bun run kit <command>` from the repository root, and it covers environment setup, local services, the development environment, database lifecycle, the activation code, logs, code generation, and repository analysis. This page is the reference for every command.

The decisive property, stated up front: `kit` is a Bun + TypeScript program in `tools/devkit/`, and the repository's `package.json` scripts wrap the common commands (`services:start`, `services:stop`, `dev`, `analyze`, and so on) so you do not have to type the full `bun run kit` form. Either form works; the scripts are aliases.

## Environment and detection

| Command | What it does |
|---|---|
| `kit env-setup` | Install the host toolchain required for Ankole development — system build packages, Docker, Rust, the Elixir/Erlang toolchain, the pinned Bun. Add `--print` to print the installer commands without running them. |
| `kit is-ci` | Exit `0` if running in a CI environment, `1` otherwise. Used by scripts that branch on CI. |
| `kit is-dev` | Exit `0` if running in a development environment, `1` otherwise. |

Run `env-setup` once on a fresh machine; the rest are detection helpers other commands call internally.

## Local services and the dev environment

| Command | What it does |
|---|---|
| `kit external-services start` | Start the devkit Docker Compose services (PostgreSQL and friends). Wrapped as `bun run services:start`. |
| `kit external-services stop` | Stop the devkit Compose services. Wrapped as `bun run services:stop`. |
| `kit external-services status` | Report devkit service health. Wrapped as `bun run services:status`. |
| `kit dev` | Start the complete development environment — Phoenix, frontend assets, and one managed Docker worker. Wrapped as `bun run dev`. Keep this terminal open. |

`kit dev` is the one command that runs the whole stack. It starts or verifies PostgreSQL, creates and migrates the local database, builds a missing or stale worker image, and starts the managed worker. Do not start a second `kit dev`; stop it with `Ctrl+C` in its terminal.

## Database lifecycle

`kit app-db` owns the local control-plane database:

| Command | What it does |
|---|---|
| `kit app-db create` | Create the app database if it does not already exist. |
| `kit app-db drop` | Drop the app database. Requires `--yes` to confirm the destructive operation. |
| `kit app-db rebuild` | Drop, create, and migrate the app database. Requires `--yes`; runs Ecto migrations after recreating. |
| `kit app-db migrate` | Run control-plane Ecto migrations against the configured local database. |

Options apply across these: `--start-services` starts Compose before the operation, `--pull-images` pulls the latest service images first, and a health-check wait controls how long to wait for service readiness. The `app-db rebuild` command in particular deletes the local `ankole_dev` database — only run it when the data is genuinely disposable.

## Setup and inspection

| Command | What it does |
|---|---|
| `kit show bootstrap-activation-code` | Print the current setup activation code. Use this when the first-visit page needs the code and the `kit dev` terminal is not visible. |
| `kit logs pretty` | Pretty-print Ankole structured JSON log lines from stdin. Pipe a log stream to it for readable local output. |

## Code generation and analysis

| Command | What it does |
|---|---|
| `kit generate [collection-name:]<schematic-name> [options]` | Generate or modify files from a schematic. `bun run kit g code-workspace` (wrapped as `bun run workspace:update`) regenerates the VS Code workspace. |
| `kit analyze all` | Run all repository analyses. Wrapped as `bun run analyze`. |
| `kit analyze smells` | Report code smells. Wrapped as `bun run analyze:smells`. |
| `kit analyze unused` | Report unused code. Wrapped as `bun run analyze:unused`. |
| `kit analyze structure` | Report repository structure. Wrapped as `bun run analyze:structure`. |
| `kit analyze cycles` | Report dependency cycles. Wrapped as `bun run analyze:cycles`. |

## Worker test runner

`kit agent-computer-test` runs the Agent Computer Worker package tests in the canonical worker container runtime, so tests execute in the same environment a real turn uses. It takes a `--suite` of `unit` or `integration`, and a `--prebuilt-image` to run against a specific Agent Computer Worker Docker image rather than building one.

## Discovering more

```bash
bun run kit --help
```

`kit` is a `@crustjs` command tree, so every level has `--help`. The commands above are the ones an operator or contributor actually runs; for the full subcommand surface of any one command (for example, `kit app-db --help`), ask the CLI directly.

## Next steps

- For the local-environment walkthrough that uses these commands, read [Quick start](../quickstart/).
- For what `kit dev` starts, read the [architecture overview](../architecture/).
