---
title: Contributing
description: The path to a merged Ankole contribution — where the rules live, how to set up, how to run the right checks, and the changelog and PR discipline the project requires.
section: Guides
order: 321
---

Before making your first edit in Ankole, read two root documents and follow the workflow that they define. This page maps out those authoritative sources and summarizes the path through them without duplicating either—whenever this overview and a root document disagree, the root document wins.

Ankole's contribution rules are enforced directly by code review and by the changelog gate on every product-changing commit. Maintainers will ask contributors who skip [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md) or [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) to read them before review proceeds—so read both first.

## The two documents that own the rules

- **[`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md)** — project-wide engineering rules: scope and authorization, changelog discipline, smallest correct change, worse-is-better design priorities (simplicity > correctness > consistency > completeness), objective fidelity, and subsystem boundaries. Read this to understand *how* to design and implement a change.
- **[`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)** — the practical contribution workflow: six-step local setup, Feishu end-to-end acceptance, troubleshooting order, repository map, verification gates, and changelog/PR mechanics. Read this to know *what steps to run* to land a change.

Each file is the single source of truth for its domain; nothing in the website docs overrides them.

## The setup path (six steps)

`CONTRIBUTING.md` walks through local setup in six steps—here is the high-level shape so you know what to expect:

1. **Get the repository and choose an environment** — clone the repo on macOS, Linux, WSL2, or GitHub Codespaces.
2. **Install and verify the system tools** — run `bash tools/devkit/scripts/env-setup.sh`, then verify that `bun`, `elixir`, `rustc`, `cargo clippy`, and `docker` all succeed. See the [kit CLI reference](../kit-cli/) for each `kit` subcommand.
3. **Install dependencies and initialize local services** — run `bun install`, `bun run services:start` (which starts PostgreSQL 18 and `Function Runtime` / `ankole-function-runtime`), and `bun run control-plane:setup`.
4. **Start the complete development environment** — run `bun dev`.
5. **Complete first-time product setup** — activate at `/setup`, sign in the first administrator via passwordless SMTP Email OTP or Feishu app OAuth (create a Feishu test app when running the full Feishu end-to-end check), and configure the runtime in the Site Admin Console at `/site-admin-console`.
6. **Prove the end-to-end path** — send a real Feishu message to your Agent and verify that it replies as expected.

Local setup is not finished merely because the web UI loads—it is finished once a real message completes the round trip. See [Quick start](../quickstart/) for deployment basics and [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) for the full acceptance checklist.

## How to make the change

Read `AGENTS.md` before writing code. Six principles come up on nearly every review:

- **Scope and authorization.** Requests to explain, diagnose, or plan are strictly read-only; only an implementation request authorizes code edits, and expanding scope requires explicit sign-off.
- **The changelog is for users and operators.** Every commit that changes product behavior adds one `CHANGELOG.md` version describing what users or operators will notice; documentation-only commits add none.
- **Smallest correct change.** Favor the smallest change that follows the architecture, preserves contracts that the system guarantees, and stays easy to read—modest local duplication beats premature abstraction.
- **Worse is better.** Prioritize simplicity ahead of uniform abstractions or theoretical completeness; narrow the contract or reject unsupported cases explicitly rather than adding fragile fallbacks.
- **Objective fidelity.** Deliver the exact outcome requested through the real production boundary—a green unit test or mocked demo is never a substitute.
- **Subsystem boundaries.** PostgreSQL owns durable domain facts; the Elixir control plane owns durable state, supervision, and commit authority; the Rust kernel provides stateless native primitives; the Bun Agent Computer Worker runs per-Agent tools and workspaces; and `Function Runtime` (`app/function_runtime/`) runs stateless Applet backend and deterministic program isolates. Keep cross-boundary changes aligned with those owners.

## The changelog rule

Every product-changing commit is gated by `CHANGELOG.md`—the rule that first-time PRs miss most often:

- Commits that touch only documentation or `CHANGELOG.md` itself add no version entry. Every other commit adds **exactly one** new version section in root `CHANGELOG.md`, and a single version never spans multiple commits.
- Describe what an operator or end user notices on upgrade: new capabilities, behavioral changes, removals, user-visible bug fixes, and any required operator actions. Omit internal refactors, tests, docs, tooling, and dependency bumps—if a commit has no user-visible effect, write `Internal changes only.`
- Follow `MAJOR.MINOR.PATCH`: default to `PATCH`, bump `MINOR` for a brand-new product capability or a breaking change requiring operator action, and leave `MAJOR` or pre-release tags to maintainer decisions.

Root `CHANGELOG.md` is the sole release-notes and versioning source: once a `main` build passes verification across all three co-versioned runtime images (`ankole-control-plane`, `ankole-agent-computer`, and `ankole-function-runtime`), CI tags those images with the top changelog version and publishes the immutable GitHub Release directly from that section. Write the changelog entry as part of your change, not as an afterthought.

## Run the right checks

Run the verification gates listed in `CONTRIBUTING.md` (with CLI details in the [kit CLI reference](../kit-cli/)):

- **Targeted unit tests and static type/compile checks** for each package you touched—avoid running unrelated suites unnecessarily.
- **Integration and end-to-end tests** whenever your change crosses a process, external provider, persistence/restart, or user-flow boundary.
- **`bun run analyze`** (`kit analyze all`) to catch repository-wide smells, dead code, boundary violations, and dependency cycles.
- **`bun run lint`** and **`bun run fmt:check`** before committing.

If your environment blocks a required check from running, report the exact command and what blocked it—never present an unexecuted check as verified.

## Submit the pull request

Before opening a PR, verify that each product-changing commit carries its own `CHANGELOG.md` version, all subsystem boundaries in `AGENTS.md` hold, and your PR description states what changed and why using Ankole's domain terms—reviewers check those exact criteria.

## What this guide is not

This page is an entry point to `AGENTS.md` and `CONTRIBUTING.md`, not a replacement for reading them—`AGENTS.md` is intentionally concise, and reading it upfront saves review round-trips. Nor is PR review the place to relitigate settled project trade-offs; evaluate and build changes consistently within Ankole's established architecture.

## Next steps

- Read [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md) before your first edit.
- Follow [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) for local setup and acceptance checks.
- Consult the [kit CLI reference](../kit-cli/) for workspace commands.
- Read the [architecture overview](../architecture/) to see the subsystem boundaries that your change touches.
