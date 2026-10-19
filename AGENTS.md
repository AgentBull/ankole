# Ankole Agent Guidelines

## Authorization

A request to answer, explain, review, audit, diagnose, or plan permits read-only inspection and non-mutating checks. A request to implement, fix, change, create, refactor, or build a named feature or artifact permits the repository edits and non-destructive local validation that the task needs. A build-only request permits the build and its transient outputs. Retained edits also need a request to fix failures.

Complete the authorized task, including its validation and related updates. Use authorization the user already gave. Before an action that needs approval, complete the independent authorized work so the user can review a concrete result.

These actions need explicit authorization: commit, push, publish, issue or pull request, credential change, purchase, other external write, destructive action, material scope expansion, and a diagnostic reproduction that changes durable or external state.

User instructions take priority over Skill advice. When a written rule blocks the work, link its source, quote the rule, and explain why it applies. Ask only when instructions still conflict, or when a choice changes product behavior or ownership beyond the user's authorization. Continue the independent authorized work.

## Shared worktree

Preserve unrelated diffs. Re-read each target file before you edit it. When an unexpected change overlaps the target or invalidates an assumption, pause that edit and write a uniquely delimited block in `HEY.md`. Remove only your block after it is resolved. Continue the other work.

## Contracts

The supported contract is the current declaration, the authoritative user documentation, the configured values, the authoritative persisted facts, and the evidenced callers. Preserve that meaning, or update the declaration, storage, callers, and documentation together. The changelog records history only.

Do the requested observable result. A passing test, a smaller diff, a new abstraction, or a happy-path demo does not replace that result. When blocked, name the failed boundary, dependency, setup, or design decision. A disagreement with a settled tradeoff is not a finding.

Changing an existing contract needs user authorization. Ankole has no released public compatibility contract. Keep an old form only for an evidenced current caller, an authoritative persisted value, an external contract, or an explicit staged migration, and state when to remove it.

Follow Worse is Better, in this order: simplicity, correctness, consistency, completeness. Prefer a simple implementation over a uniform interface. Every supported behavior must stay correct. A narrower contract, a clear rejection, or manual recovery can be the right result.

Before you add a concept, path, dependency, test, or document, find the existing owner and reuse, replace, or delete it. A replacement in the affected scope removes the superseded code, tests, comments, documentation, configuration, completed TODOs, and links. Do not add a second owner for one contract. When two alternatives are equally simple and correct, make the smaller change. Keep authoritative user and operator facts. Remove invalid or superseded state when no required guarantee depends on it.

Production code must reach the domain contract and the production adapter. A unit test may fake that boundary. An integration test uses the real adapter or protocol. An end-to-end test follows the real user flow. A labeled fake does not prove an integration or end-to-end guarantee. Do not weaken an assertion, bypass a production path, or move ownership to make a test pass. Before you change a test, name the contract and the code that owns it. Fix a broken package-local setup. Keep public names on domain operations, and keep codec details at internal edges.

## Boundaries

- A site owns the infrastructure. Each tenant owns its organization and data. One site uses one PostgreSQL database. A tenant query needs an explicit process context through `Ankole.Repo`. Missing context must fail. Add SaaS account, billing, self-service, or tenant-console paths only when the user requests them. See [Tenants](docs/design-docs/Tenants.md).
- Principal/AuthZ owns accountable subjects and permissions. Each Principal belongs to one tenant and has one globally unique opaque UID. Do not add another subject or authorization model.
- Use an environment variable or a secret mount only for a startup fact or credential that is required before storage is reachable. Operator settings go in declared `Ankole.AppConfigure` keys. Runtime-generated credentials and secrets go in the owning subsystem's encrypted storage.
- Match the owning domain's schema and identifier shape. Do not add a local key strategy or a database-generated identifier.
- PostgreSQL owns an authoritative domain fact when its loss or replay changes user-visible semantics. Use native types and constraints for domain invariants. Other storage may hold a rebuildable cache or artifact when PostgreSQL keeps its lifecycle or reference.
- The Elixir control plane owns durable domain state, supervision, and domain-state commit authority. The Rust kernel owns shared native primitives and transport. The Bun Agent Computer owns agent execution and rebuildable worker-local state. A worker read or write that changes durable semantics uses a control-plane-owned contract.
- A model-visible resource or path must resolve through a real owning runtime contract. Do not expose a fake Skill, workspace, storage location, or state.
- Extensions are trusted and first-party. Third-party marketplaces, hot-loading, and isolation machinery need an explicit product change.
- When you change behavior, schemas, events, storage, transport, or lifecycle, follow the owning document in `docs/design-docs/` when one exists.
- Files under `app/webapps/` and `app/agent_computer/` also follow the `AGENTS.md` in that directory.

## Tooling

An authorized implementation may add a needed dependency. Update the owning package manifest and the committed lockfile together.

Use Bun as the TypeScript runtime, package manager, and script launcher. Run the script declared in `package.json`, including a container or other runtime that the script selects. Use bare `bun test` or `bun build` only when no script exists. A run in the wrong runtime is not evidence. Install TypeScript dependencies with `bun install` and update `bun.lock`. Bun loads `.env`. Do not add `dotenv`.

Use `@agentbull/active-support` for a general utility it already provides. Import it directly. Setup and the repository check table are in [CONTRIBUTING.md](CONTRIBUTING.md#run-the-right-checks).

## Completion

Finish the requested path. Keep its source, tests, declarations, migrations, generated files, configuration, and documentation consistent.

Update the changelog when the retained work is complete and before any commit. Follow [one version per commit](CONTRIBUTING.md#one-version-per-commit). A change only in `internals/` that does not affect FOSS goes in `internals/CHANGELOG.md`.

For an implementation change, run the affected targeted tests and the normal static check. When the guarantee crosses a process, provider, persistence restart, or user-flow boundary, run that dedicated integration or end-to-end command if its environment is available. Keep those suites out of the default fast suite. For a documentation-only change, inspect the diff and the links. When a required check cannot run, report the command and the blocker. Do not report that guarantee as verified.

Write English documentation and code comments in [ASD-STE100 Simplified Technical English, Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf). Project names, identifiers, API names, paths, commands, and approved Ankole terms are technical nouns or verbs.

<!-- BEGIN:turborepo-agent-rules -->

# This is NOT the Turborepo you know

Turborepo configuration, task behavior, and CLI commands can vary between installed versions and may differ from your training data. Resolve the `turbo` package from this file's directory or relevant workspace; in monorepos, it may not be visible from the repository root. For example, run `node -p "require.resolve('turbo/package.json')"` from a workspace that depends on `turbo`.

Read `docs/README.md` inside that installed package first, then read the relevant pages from its `docs/` directory before changing Turborepo configuration or commands. Heed deprecation notices. These bundled docs match the installed package version and are available without network access.

This block is written and re-added by `turbo` before repository-scoped commands when an AI agent is detected. In the Turborepo source repository, its template is defined in `crates/turborepo-cli/src/cli/agent_guidance.rs`. Removing the managed block while updates are enabled means a later qualifying invocation will add it again. Set `"agentGuidance": false` in the root `turbo.json` or `turbo.jsonc` to opt out; this does not remove an existing block. Keep the block committed with your work to avoid an uncommitted change on the next agent invocation.
<!-- END:turborepo-agent-rules -->
