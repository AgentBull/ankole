---
title: kit CLI reference
description: The devkit command surface — every `bun run kit` command an operator or contributor runs, what it does, and the scripts that wrap it.
section: Reference
order: 200
---

`kit` is Ankole's developer and operator command-line tool. Invoked as `bun run kit <command>` from the repository root, it manages host toolchains, local backing services, the development stack, control-plane databases, setup activation codes, structured logs, code generation, and static analysis.

Implemented as a Bun + TypeScript CLI in `tools/devkit/`, `kit` also backs the convenience scripts in the root `package.json` (`services:start`, `services:stop`, `dev`, `analyze`, and others). You can run either the `package.json` alias or the full `bun run kit <command>` form interchangeably.

## Environment and detection

| Command | What it does |
|---|---|
| `kit env-setup` | Install the host toolchain required for Ankole development — system build packages, Docker, Rust, the Elixir/Erlang toolchain, and the pinned Bun version. Add `--print` to inspect the installer commands without executing them. |
| `kit is-ci` | Exit `0` when running in a CI environment, or `1` otherwise. Used by scripts that branch on CI. |
| `kit is-dev` | Exit `0` when running in a development environment, or `1` otherwise. |

Run `env-setup` once on a fresh machine; the remaining two commands are detection helpers that internal scripts call.

## Local services and the dev environment

| Command | What it does |
|---|---|
| `kit external-services start` | Start the devkit Docker Compose services (PostgreSQL 18 and `ankole-function-runtime`). Aliased as `bun run services:start`. |
| `kit external-services stop` | Stop the devkit Compose services. Aliased as `bun run services:stop`. |
| `kit external-services status` | Report devkit service health. Aliased as `bun run services:status`. |
| `kit dev` | Start the full development stack — PostgreSQL 18, `ankole-function-runtime`, Phoenix, frontend assets, and the Docker Worker backend that launches one Worker container per Agent. Aliased as `bun run dev`. Keep this terminal open. |

`kit dev` brings up the entire local stack: it starts or verifies PostgreSQL 18 and `ankole-function-runtime`, creates and migrates the local control-plane database (`ankole_dev`), builds the Worker image if it is missing or stale, and boots the control plane with the Docker Worker backend. When `BASE_DB_URLS` is unset, the control plane's development bootstrap also creates and prepares the four local Base shard databases (`ankole_base_00` through `ankole_base_03`).

Whenever you create an Agent, the control plane starts a dedicated Worker container that runs the local Agent Computer source under `bun --watch`. You can inspect those containers with `docker ps -a --filter label=ankole.installation=dev`. Never run two `kit dev` processes at once. Press `Ctrl+C` in the `kit dev` terminal to shut down the stack and remove all Worker containers belonging to the `dev` installation; on the next start, the control plane recreates each existing Agent's Worker container as soon as that Agent needs one.

## Database lifecycle

`kit app-db` manages the local control-plane database:

| Command | What it does |
|---|---|
| `kit app-db create` | Create the application database if it does not already exist. |
| `kit app-db drop` | Drop the application database. Requires `--yes` to confirm the destructive operation. |
| `kit app-db rebuild` | Drop, recreate, and migrate the application database. Requires `--yes` and runs Ecto migrations immediately after creation. |
| `kit app-db migrate` | Run control-plane Ecto migrations against the configured local database. |

`create`, `drop`, and `rebuild` share three service flags: `--start-services` starts Docker Compose beforehand, `--pull` pulls the latest service images first, and `--wait-timeout` sets how many seconds to wait for health checks (default `60`). Because `app-db rebuild` wipes your local `ankole_dev` database, run it only when your local data is disposable.

## Setup and inspection

| Command | What it does |
|---|---|
| `kit show bootstrap-activation-code` | Print the current setup activation code. Useful when the first-visit setup page prompts for the code and your `kit dev` terminal is out of view. |
| `kit logs pretty` | Format structured JSON log lines from Ankole on `stdin` for human-readable local output. |

## Code generation and analysis

| Command | What it does |
|---|---|
| `kit generate [collection-name:]<schematic-name> [options]` | Generate or update files from a schematic. For example, `bun run kit g code-workspace` (aliased as `bun run workspace:update`) regenerates the VS Code workspace file. |
| `kit analyze all` | Run every repository static check. Aliased as `bun run analyze`. |
| `kit analyze smells` | Report code smells. Aliased as `bun run analyze:smells`. |
| `kit analyze unused` | Report unused code. Aliased as `bun run analyze:unused`. |
| `kit analyze structure` | Report repository boundary and structure violations. Aliased as `bun run analyze:structure`. |
| `kit analyze cycles` | Report module dependency cycles. Aliased as `bun run analyze:cycles`. |

## Worker test runner

`kit agent-computer-test` runs the tests for the Agent Computer Worker package inside the canonical Worker container image, ensuring that tests execute in the same runtime environment that a real Agent turn uses. Pass `--suite unit` or `--suite integration` to choose the test suite, and pass `--image <ref>` to test against a prebuilt Worker Docker image instead of building one locally.

## Discovering more

```bash
bun run kit --help
```

Because `kit` is built on `@crustjs`, every subcommand exposes `--help`. The tables above cover the commands that operators and contributors run directly; pass `--help` to any subcommand (such as `bun run kit app-db --help`) to inspect its full flag list.

## Next steps

- For the local-environment walkthrough that uses these commands, read [Quick start](../quickstart/).
- For what `kit dev` starts, read the [architecture overview](../architecture/).
