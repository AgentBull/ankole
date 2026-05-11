# Contributing to BullX

Thank you for your interest in contributing to BullX! We welcome bug reports, feature requests, documentation improvements, and code contributions.

> ⚠️ **BullX is in early development.** The architecture is evolving rapidly — interfaces will change and significant refactors are expected between releases. Contributions that work ahead of the current RFC phase may require substantial revision before merging.

## Development Setup

### Prerequisites

- Elixir 1.19+
- PostgreSQL 18+
- Bun

### First run

```sh
bun setup              # install deps, create and migrate the database, build assets
bun dev                # start Phoenix and the Rsbuild dev server
```

### Git hooks (lefthook)

A git pre-commit hook is wired up via [lefthook](https://lefthook.dev) — it
runs the same `bun precommit` gate documented for local development.

Install the binary once (`brew install lefthook`, or see the
[installation docs](https://lefthook.dev/installation/) for other platforms),
then run:

```sh
lefthook install   # writes .git/hooks/* from lefthook.yml
```

### Tests

```sh
bun run test     # run frontend tests
mix test         # run the Elixir test suite
bun precommit    # full precommit gate — must pass before committing
```

### Storybook and UI kit work

BullX uses Storybook for `webui/src/uikit` component development and visual
review. Stories live in `webui/src/uikit/stories/`, while Storybook config lives
under `.storybook/`.

```sh
bun run storybook        # start Storybook on http://localhost:6006
bun run build-storybook  # build the static Storybook bundle
```

Use Storybook when changing UI kit components, design tokens, or global UI
styles. Check the relevant component stories in both light and dark themes
before calling a visual change done. The theme toggle in the Storybook toolbar
sets `data-theme`, matching the app token model.

For focused visual debugging, open the iframe URL directly, for example:

```text
http://localhost:6006/iframe.html?id=components-card--default&globals=theme:dark&viewMode=story
```

UI kit styles and assets should flow through Rsbuild. Keep shared tokens in
`webui/src/globals.css`, keep component stories close to the component surface
they document, and do not add Phoenix static handling for Storybook-only needs.

## Architecture overview

BullX is organized into subsystems, all booting under a single OTP supervision tree. Before contributing to a specific area, read [`AGENTS.md`](AGENTS.md) for the subsystem descriptions, coding conventions, and any non-obvious design constraints.

| Subsystem | Location | Concern |
| --- | --- | --- |
| Gateway | `lib/bullx/gateway/` | Multi-transport ingress and egress |
| Runtime | `lib/bullx/runtime/` | Session processes, task pools, sub-agents, scheduling |
| AIAgent | `lib/bullx/ai_agent/` | Agent behaviors and reasoning strategies (library, no process) |
| Brain | `lib/bullx/brain/` | Persistent memory and knowledge graph |
| Skills | `lib/bullx/skills/` | Capability registry |
| Control plane | `lib/bullx_web/` | HTTP API and operator UI |

PostgreSQL is the system of record for all durable state. Process-local state is considered ephemeral.

## Plans and agent-assisted development

BullX uses a plan-first workflow for implementing features and complex fixes with a coding agent (Claude Code, Codex, or similar):

1. **Write a plan** in `rfcs/plans/` that fully specifies the change: which files to create or modify, what each module should look like, and what the acceptance criteria are.
2. **Run the coding agent** against the plan. The plan is the source of truth; the agent should not make significant decisions outside its scope.
3. **The plan stays in the repo** permanently, serving as a record of design intent for future contributors and reviewers.

This is not a traditional RFC process (no community consensus stage). The primary audience for a plan is the coding agent that will execute it — but because the plan is committed alongside the code, it also documents *why* things were done a particular way.

For purely manual changes and minor bug fixes, a plan is encouraged but not required.

## Project structure

- `lib/bullx/` — Core application code, organized by subsystem.
- `lib/bullx_web/` — Control plane (HTTP API and operator UI).
- `priv/repo/` — Database migrations and seeds.
- `test/` — Test suite, organized to mirror `lib/`.
- `packages/` — Local Hex packages (path dependencies).
- `rfcs/plans/` — Plans that specify what a coding agent should implement; stays in the repo as a record of design intent.
- `internals/` — Private submodule for the AgentBull team, used to test BullX against real-world scenarios before features land in this repo. You can safely ignore this directory.

## Submitting a pull request

1. Fork the repository and create a branch from `main`.
2. Make your changes with tests where applicable. `bun precommit` must pass.
3. If your change implements or extends an RFC, reference it in the PR description.
4. Open a pull request with a concise title and a summary of what changed and why.

For large or cross-subsystem contributions, open an issue first to align on direction before investing significant effort.
