---
title: Contributing
description: The path to a merged Ankole contribution — where the rules live, how to set up, how to run the right checks, and the changelog and PR discipline the project requires.
section: Guides
order: 321
---

Contributing to Ankole means reading two documents before the first edit, and following the path they define. This page is the map: it points at the authoritative sources, names the path through them, and stops short of duplicating either. If this page and a source document disagree, the source document is right.

The decisive property, stated up front: Ankole's contribution rules are not optional conventions — they are enforced by the project's review process and by the changelog rule that gates every commit. A contribution that skips [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md) or [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) will be asked to go back and read them. Read them first.

## The two documents that own the rules

- **[`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md)** — the project-wide rules: scope and authorization, the changelog-as-version-unit rule, core discipline (smallest correct change, worse-is-better), the design priorities (simplicity > correctness > consistency > completeness), objective fidelity, and the subsystem boundaries. This is the document that decides *how* to make a change.
- **[`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)** — the contribution path: the six-step local setup, the Feishu end-to-end acceptance, the troubleshooting order, the repository map, the quality gates, the changelog and PR steps. This is the document that decides *what to do* to land a change.

Both are the source of truth for their domain. This guide and the rest of the docs link to them; nothing here overrides them.

## The setup path (six steps)

`CONTRIBUTING.md` walks the setup in six steps, and it is the authoritative version. The shape, so you know what you are walking into:

1. **Get the repository and choose an environment** — clone, and pick macOS/Linux/WSL2 or GitHub Codespaces.
2. **Install and verify the system tools** — `bash tools/devkit/scripts/env-setup.sh`, then verify `bun`, `elixir`, `rustc`, `cargo clippy`, and `docker` all work. See the [kit CLI reference](../kit-cli/) for what each `kit` command does.
3. **Install dependencies and initialize PostgreSQL** — `bun install`, `bun run services:start`, `bun run control-plane:setup`.
4. **Start the complete development environment** — `bun dev`.
5. **Complete first-time product setup** — activate, create the Feishu test app, configure OIDC, configure the runtime in the Console.
6. **Prove the end-to-end path** — a real Feishu message reaches the agent and returns the expected reply.

The setup is not done when the page opens. It is done when a real message round-trips. See [Quick start](../quickstart/) for the short path and [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) for the full acceptance.

## How to make the change

Read `AGENTS.md` before the first edit. The rules that come up most often:

- **Scope and authorization.** A request to answer or plan authorizes read-only inspection; a request to implement authorizes the edits. Do not expand scope without approval.
- **The changelog is the version unit.** Every commit adds exactly one `CHANGELOG.md` version, and that version describes every retained change in the commit. One version does not span commits; one commit does not contain multiple versions. See the section below.
- **Smallest correct change.** Prefer the smallest change that follows the chosen direction, preserves contracts the system can keep, and stays understandable. A little duplication is better than an abstraction that compounds complexity.
- **Worse is better.** Simlicity beats interface uniformity or theoretical completeness. When simplicity wins, narrow the contract or reject the unsupported case explicitly, rather than silently producing a wrong result.
- **Objective fidelity.** Do the requested task, not a cheaper proxy. A green test is not the goal; the real path through the owning abstraction is.
- **Subsystem boundaries.** PostgreSQL owns durable facts; the Elixir control plane owns durable state and supervision; the Rust kernel owns shared native primitives; Bun Agent Computer owns execution. A change that crosses a boundary should respect it, not paper over it.

## The changelog rule

This is the rule that gates every commit, and the one most contributions get wrong on the first try. From `AGENTS.md`:

- Every commit adds exactly one root `CHANGELOG.md` version.
- That version describes every retained source, test, doc, config, schema, migration, manifest, lockfile, and required generated-file change in that commit.
- One version must not span multiple commits; one commit must not contain multiple versions.
- Versions use `YY.MM.N`, where `N` is the monthly sequence starting at `0`.
- Prepare the entry from the exact staged diff immediately before committing.

The changelog is the *sole* changelog and version unit — there is no separate release notes file. Treat it as part of the change, not as paperwork afterward.

## Run the right checks

`CONTRIBUTING.md` names the checks, and the [kit CLI reference](../kit-cli/) documents the commands. The shape:

- **Targeted tests and the normal static check** for the package you changed — run the affected package's tests, not the whole suite.
- **The affected integration or end-to-end suite** when the change crosses a process, provider, persistence-restart, or user-flow boundary — and do not skip it.
- **`bun run analyze`** (`kit analyze all`) for repository-wide smells, unused code, structure, and cycles.
- **`bun run lint`** and **`bun run fmt:check`** before committing.

If a required command cannot run in your environment, report the exact command and blocker — do not claim the guarantee as verified.

## Submit the pull request

`CONTRIBUTING.md` covers the PR step. The short shape: the PR's commits follow the changelog rule (one version per commit), the change respects the boundaries in `AGENTS.md`, and the PR description says what changed and why in the terms the documents use. The review will check the same things.

## What this guide is not

It is not a substitute for the two documents — it is the doorway to them. It is not a license to edit without reading; `AGENTS.md` is short on purpose, and reading it is the cheapest thing a contribution can do. And it is not a place to argue the rules; the rules are settled tradeoffs, and a local preference is not a finding — evaluate whether the implementation is consistent inside the chosen direction instead.

## Next steps

- Read [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md) before the first edit.
- Follow [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) for setup and acceptance.
- Use the [kit CLI reference](../kit-cli/) for the devkit commands.
- Read the [architecture overview](../architecture/) to understand the subsystem boundaries a change crosses.
