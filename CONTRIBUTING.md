# Contributing to Ankole

Thank you for your interest in contributing to Ankole! We welcome bug reports, feature requests, documentation improvements, and code contributions.

> ⚠️ **Ankole is in early development.** The architecture is evolving rapidly — interfaces will change and significant refactors are expected between releases. Contributions may require substantial revision as subsystems stabilize.

## Development setup

### Prerequisites

- **Bun `1.3.14`** — the version is pinned via `packageManager` in `package.json`; CI uses the same. Bun is the package manager, test runner, and bundler for the whole monorepo.
- **Docker** — used to run local PostgreSQL and Redis through the devkit Compose file. (You can also point the app at your own Postgres/Redis via `app/.env.local`.)
- **Rust toolchain** (stable, with `clippy` and `rustfmt`) — only needed if you touch the native packages (`packages/native-addons`, `packages/computer`).

### First run

```sh
bun install             # install deps; also wires git hooks via core.hooksPath
bun run services:start  # start local Postgres + Redis (Docker Compose)
bun run db:create       # create the app database
bun run db:migrate:up   # apply Drizzle migrations
bun run dev             # start the app with hot reload
```

Default local ports (from `app/.env.development`): Postgres `localhost:5433`, Redis `localhost:6379`. To wipe and recreate a local database, run `bun run db:rebuild --yes`.

### Git hooks

`bun install` points `core.hooksPath` at `.githooks/` (via the root `prepare` script) — there is no separate install step. The `pre-commit` hook auto-formats staged TypeScript/JSON files with `oxfmt` and re-stages them, so commits always land formatted. It deliberately does **not** run the full gate — run that yourself before pushing (see below).

### Checks before you push

These mirror what CI enforces and are runnable locally:

```sh
bun run lint        # oxlint + per-workspace lint
bun run type-check  # tsc across all workspaces (via turbo)
bun run fmt:check   # oxfmt formatting check
bun run analyze     # kit static analysis: smells, unused, duplicates, cycles, topology
bun run test        # bun test across all workspaces (via turbo)
```

`bun run fmt` formats in place. CI runs the static gates above; if you changed Rust, it also runs `cargo fmt --check` and `cargo clippy` in `packages/native-addons`, so run those locally too.

Heavier end-to-end checks are available but not part of the default gate:

```sh
bun run test:computer:e2e  # computer/browser runtime end-to-end
bun run test:llm-e2e       # live LLM end-to-end
```

### Repository toolkit (`kit`)

Most repo chores go through the devkit, exposed as `bun run kit`:

```sh
bun run kit --help          # list all commands
bun run services:status     # local services state
bun run workspace:update    # regenerate the VS Code workspace file
bun run db:rebuild --yes    # drop, recreate, and migrate the app database
```

The Compose file lives at `tools/devkit/external-services.docker-compose.yml`.

## Architecture overview

Ankole runs as a single Bun + TypeScript application (`app/`, an Elysia backend with a React operator UI) backed by PostgreSQL, with performance-sensitive helpers in Rust. Before contributing to a specific area, read [`AGENTS.md`](AGENTS.md) for coding conventions and the *Zen of Ankole* (symlinked as `CLAUDE.md`); [`README.md`](README.md) has the fuller architecture narrative.

The backend is organized into subsystems under `app/src/`:

| Subsystem | Location | Concern |
| --- | --- | --- |
| SignalsGateway | `app/control_plane/lib/ankole/signals_gateway/` | Multi-transport ingress and egress; Postgres input and outbox projections |
| AIAgent | `app/src/ai-agent/` | Agent conversations, messages, summaries, and LLM turns |
| LLM providers | `app/src/llm-providers/` | LLM provider integrations and configuration |
| Principals | `app/src/principals/` | Principal identity, group membership, and permission grants |
| Scheduler | `app/src/scheduler/` | Scheduled and long-running work |
| Computer | `app/src/computer/` | Browser and computer runtime control |
| Console / Setup | `app/src/console/`, `app/src/setup/` | Operator API and UI; first-admin bootstrap and provider/channel configuration |
| Plugins | `app/src/plugins/` | Plugin host and integration surface |
| Core / Config / Common | `app/src/core/`, `config/`, `common/` | Composition root, configuration, and shared contracts (incl. `common/db-schema`) |

PostgreSQL is the system of record for all durable state. Process-local state is considered ephemeral.

## Design docs and agent-assisted development

Ankole is built largely with coding agents (Claude Code and similar). Two living references guide that work:

- [`AGENTS.md`](AGENTS.md) — conventions and principles that both agents and humans follow.
- [`docs/design-docs/`](docs/design-docs/) — design intent for non-trivial subsystems, committed alongside the code so the *why* survives for future contributors and reviewers.

A significant or cross-subsystem change should come with a design doc (new or updated) in `docs/design-docs/`. For minor fixes a design doc is encouraged but not required.

## Project structure

- `app/` — the Ankole application.
  - `app/src/` — backend subsystems (see the table above).
  - `app/webui/` — React + Tailwind operator UI.
  - `app/db/` — Drizzle migrations and snapshots (generate with `bun run db:migrate:gen`).
  - `app/library/` — bundled skills and templates.
  - `app/scripts/` — build and end-to-end scripts.
- `packages/` — workspace packages: `computer` (browser/computer runtime), `native-addons` (Rust/NAPI helpers), `sdk` (plugin SDK).
- `plugin/` — first-party plugins (e.g. `lark-adapter`).
- `tools/devkit/` — the `kit` repository toolkit.
- `docs/design-docs/` — design intent documents.
- `internals/` — private submodule for the AgentBull team, used to test Ankole against real-world scenarios. It is not checked out in CI; you can safely ignore it.

## Submitting a pull request

1. Fork the repository and create a branch from `main`.
2. Make your changes with tests where applicable. The checks above must pass — the static gates (`lint`, `type-check`, `fmt:check`, `analyze`) and `bun run test`, plus `cargo fmt --check` and `cargo clippy` if you touched Rust.
3. If your change implements or revises a design doc, reference it in the PR description.
4. Open a pull request with a concise title and a summary of what changed and why.

For large or cross-subsystem contributions, open an issue first to align on direction before investing significant effort.

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md). To report a security vulnerability, please follow [SECURITY.md](SECURITY.md) rather than opening a public issue.
