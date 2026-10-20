# Ankole Agent Guidelines

Setup, the repository map, and the check commands are in [CONTRIBUTING.md](CONTRIBUTING.md#run-the-right-checks). `app/webapps/` and `app/agent_computer/` have their own `AGENTS.md`.

## Authorization

A request to answer, explain, review, audit, diagnose, or plan is read-only. Commit, push, publish, a write to an external service, a destructive action, and work outside the requested scope need explicit authorization. Before you ask for a decision, finish the authorized work, so that the user approves a concrete result.

User instructions take priority over a Skill or a rule file. When a rule stops you, quote it and say why it applies.

## Shared worktree

Other agents edit this worktree at the same time. Preserve diffs that are not yours. Report a conflict that you cannot resolve in a uniquely delimited block in `HEY.md`, and remove your block when it is resolved.

## Design

Follow Worse is Better: simplicity first, then correctness, consistency, and completeness. A simple implementation beats a uniform interface. A narrower contract, a clear rejection, or manual recovery is often simpler than a fallback path.

Produce the result that the user asked for. A passing test, a smaller diff, a new abstraction, or a demo does not replace it. When you are blocked, name the boundary, dependency, or decision that blocks you.

Before you add a concept, path, dependency, or document, find the existing owner and reuse, replace, or delete it. One contract has one owner. Ankole has no public compatibility contract: keep an old form only for an evidenced caller, a persisted value, an external contract, or a staged migration.

## Tests

Production code must reach the real domain contract and adapter. Only a unit test may fake that boundary; an integration test uses the real adapter or protocol, and an end-to-end test follows the real user flow. Do not weaken an assertion, bypass a production path, or move ownership to make a test pass.

## Boundaries

- A site owns the infrastructure; each tenant owns its organization and data. One site uses one PostgreSQL database. A tenant query needs an explicit process context through `Ankole.Repo`, and a missing context must fail. See [Tenants](docs/design-docs/Tenants.md).
- Principal/AuthZ owns subjects and permissions. A Principal belongs to one tenant and has one globally unique opaque UID. Do not add another subject or authorization model.
- An environment variable or a secret mount holds only a startup fact or credential that is needed before storage is reachable. Operator settings are declared `Ankole.AppConfigure` keys. Runtime-generated secrets live in the owning subsystem's encrypted storage.
- Use the owning domain's schema and identifier shape. Do not add a local key strategy or a database-generated identifier.
- PostgreSQL owns every domain fact whose loss or replay changes user-visible behavior, with native types and constraints for invariants. Other storage holds only rebuildable caches and artifacts that PostgreSQL references.
- The Elixir control plane owns durable state, supervision, and commit authority. The Rust kernel owns native primitives and transport. The Bun Agent Computer owns agent execution and rebuildable worker-local state; a worker write with durable meaning goes through a control-plane contract.
- A model-visible resource or path resolves through a real runtime contract. Do not expose a fake Skill, workspace, storage location, or state.
- Extensions are trusted and first-party. A marketplace, hot-loading, or isolation machinery needs an explicit product change.
- When you change behavior, schemas, events, storage, transport, or lifecycle, follow and update the owning document in `docs/design-docs/`.

## Tooling

Use Bun and the scripts in `package.json`; they select the right runtime. Use `@agentbull/active-support` for a general utility that it already provides.

## Completion

Finish the requested path: source, tests, declarations, migrations, generated files, configuration, and documentation change together. Before you finish, read the whole diff and remove dead code, empty branches, unused imports, completed TODOs, and anything that the change superseded.

Run the checks in CONTRIBUTING.md that protect the changed boundary. When a required check cannot run, report the command and the blocker; do not report its guarantee as verified.

Write the [changelog entry](CONTRIBUTING.md#changelog) before any commit. Write English documentation and comments in ASD-STE100 Simplified Technical English.
