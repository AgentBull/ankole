# Contributing to Ankole

Thank you for your interest in contributing to Ankole! We welcome bug reports, feature requests, documentation improvements, and code contributions.

> ⚠️ **Ankole is in early development.** The architecture is evolving rapidly — interfaces will change and significant refactors are expected between releases. Contributions may require substantial revision as subsystems stabilize.

## Development setup

### Prerequisites

- **Bun `1.3.14`** — pinned via `packageManager` in `package.json`; CI uses the same. Bun is the package manager, test runner, and bundler for the TypeScript/Bun workspaces, and the entry point for control-plane scripts.
- **Elixir / Erlang (OTP)** — required for the Phoenix control plane under `app/control_plane`.
- **Rust toolchain** (stable, with `clippy` and `rustfmt`) — required for the native kernel under `app/kernel`, which is loaded by Elixir (Rustler) and Bun (N-API).
- **Docker** — used to run local PostgreSQL and Redis through the devkit Compose file, and to build/run the Agent Computer worker image.

### First run

```sh
bun install              # install deps; also sets core.hooksPath via the prepare script
bun run services:start   # start local PostgreSQL + Redis (devkit Docker Compose)
bun run control-plane:setup   # mix setup: deps.get + ecto.create + ecto.migrate + seeds
bun run control-plane:dev     # start the Phoenix control plane with hot reload
```

The control plane owns durable state through Ecto migrations under `app/control_plane/priv/repo/migrations`. To drop, recreate, and migrate the local database, run `bun run control-plane -- ecto.reset`. The devkit Compose file lives at `tools/devkit/external-services.docker-compose.yml`.

### Git hooks

`bun install` runs the root `prepare` script, which points `core.hooksPath` at `.githooks/` when that tree is present. There is no separate install step, and the script intentionally no-ops if `.githooks/` is absent, so a missing hook tree does not break installs. If a `pre-commit` hook is present there, it auto-formats staged files and re-stages them; it deliberately does **not** run the full gate — run that yourself before pushing (see below).

### Checks before you push

These mirror what CI enforces and are runnable locally:

```sh
bun run lint        # oxlint + per-workspace lint (incl. mix format --check-formatted for the control plane)
bun run type-check  # turbo run type-check across workspaces
bun run fmt:check   # oxfmt formatting check (and cargo fmt --check / mix format for kernel)
bun run analyze     # kit static analysis: smells, unused, duplicates, cycles, topology
bun run test        # turbo run test across workspaces (incl. mix test for the control plane)
```

`bun run fmt` formats in place. CI runs the static gates above. If you changed Rust in `app/kernel`, also run `cargo fmt --check` and `cargo clippy` locally; if you changed Elixir, run `mix format --check-formatted` and `MIX_ENV=test mix compile --warnings-as-errors`.

Per-workspace commands let you run a single package's gate without turbo fan-out:

```sh
bun run agent-computer:test        # requires the built worker Docker image
bun run agent-computer:type-check
bun run webapps:build              # Vite + React frontend build
bun run feishu-openapi:test
bun run control-plane:test        # mix test
```

Heavier end-to-end checks are available but not part of the default gate:

```sh
bun run agent-computer:e2e        # control-plane-side worker runtime end-to-end (Docker-backed)
bun run --filter @ankole/control-plane e2e:actor-runtime-worker
```

### Repository toolkit (`kit`)

Most repo chores go through the devkit, exposed as `bun run kit`:

```sh
bun run kit --help          # list all commands
bun run services:status     # local services state
bun run workspace:update    # regenerate the VS Code workspace file
bun run analyze all          # static analysis across the workspaces
```

The Compose file lives at `tools/devkit/external-services.docker-compose.yml`.

## Architecture overview

Ankole runs as three cooperating layers: a Phoenix/OTP control plane (`app/control_plane`) that owns durable state and runtime authority, a Bun + TypeScript Agent Computer worker (`app/agent_computer`) that executes agent turns inside a Linux container, and a shared Rust kernel (`app/kernel`) loaded by Elixir (Rustler) and Bun (N-API) for crypto, identifiers, AuthZ evaluation, and ZeroMQ RuntimeFabric transport. Before contributing to a specific area, read [`AGENTS.md`](AGENTS.md) for coding conventions and the *Zen of Ankole* (symlinked as `CLAUDE.md`); [`README.md`](README.md) has the fuller architecture narrative.

The control plane is organized into subsystems under `app/control_plane/lib/ankole/`:

| Subsystem | Location | Concern |
| --- | --- | --- |
| SignalsGateway | `signals_gateway/` | Multi-transport ingress and egress; Postgres input and outbox projections |
| Actor Runtime | `actor_runtime/` | Actor sessions, turn lifecycle, worker admission, RuntimeFabric transport, recovery |
| AI Gateway | `ai_gateway/` | Model/provider requests, responses, credential brokering |
| AI Agent | `ai_agent/` | Agent conversations, messages, summaries, and turns |
| Principals | `principals/` | Principal identity, groups, external identities, and permission grants |
| AuthZ | `authz/` | Authorization rule evaluation and policy |
| AppConfigure | `app_configure/` | Operator-managed runtime application configuration |
| I18n | `i18n/` | Translation catalogs and locale handling |
| Plugins | `plugins/` | Plugin host and integration surface |
| Setup | `setup/` | First-admin bootstrap and provider/channel configuration |
| Schedule | `schedule/` | Scheduled and long-running work |

PostgreSQL is the system of record for all durable state. Process-local worker state is considered ephemeral and rebuildable after restart. The frontend surfaces live under `app/webapps` (Vite + React) and are built into the Phoenix static shell.

## Design docs and agent-assisted development

Ankole is built largely with coding agents (Claude Code and similar). Two living references guide that work:

- [`AGENTS.md`](AGENTS.md) — conventions and principles that both agents and humans follow.
- [`docs/design-docs/`](docs/design-docs/) — design intent for non-trivial subsystems, committed alongside the code so the *why* survives for future contributors and reviewers.

A significant or cross-subsystem change should come with a design doc (new or updated) in `docs/design-docs/`. For minor fixes a design doc is encouraged but not required.

## Project structure

- `app/control_plane` — Phoenix/OTP control plane; subsystems live under `lib/ankole/`, Ecto migrations under `priv/repo/migrations/`.
- `app/agent_computer` — Bun + TypeScript Agent Computer worker; runs only inside its Docker image (see `app/agent_computer/README.md`).
- `app/kernel` — shared Rust crate loaded via Rustler (Elixir) and N-API (Bun).
- `app/webapps` — Vite + React frontend surfaces built into the Phoenix static shell.
- `app/library` — built-in agent skills and starter templates (`MISSION.md`, `SOUL.md`).
- `app/locales` — shared TOML translation catalogs.
- `libs/uikit`, `libs/feishu_openapi` — shared UI primitives and the local Lark/Feishu OpenAPI client.
- `plugins/` — first-party plugins (e.g. `lark_adapter`).
- `tools/devkit` — the `kit` repository toolkit and local-services Compose file.
- `docs/design-docs/` — design intent documents.
- `internals/` — private first-party tree for provider/plugin code and real-world scenario testing; it is not the public plugin boundary.

## Submitting a pull request

1. Fork the repository and create a branch from `main`.
2. Make your changes with tests where applicable. The checks above must pass — the static gates (`lint`, `type-check`, `fmt:check`, `analyze`) and `bun run test`, plus `cargo fmt --check` and `cargo clippy` if you touched Rust.
3. If your change implements or revises a design doc, reference it in the PR description.
4. Open a pull request with a concise title and a summary of what changed and why.

For large or cross-subsystem contributions, open an issue first to align on direction before investing significant effort.

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md). To report a security vulnerability, please follow [SECURITY.md](SECURITY.md) rather than opening a public issue.
