# Ankole Agent Guidelines

Ankole is a general-purpose Agent Operating System for long-running digital work. It can serve enterprises, teams, and one-person companies.

## Scope and authorization

Requests to answer, explain, review, audit, diagnose, or plan permit read-only inspection and non-mutating checks. Requests to implement, fix, change, create, refactor, or build a named feature or artifact authorize the necessary repository edits and non-destructive local validation. A build-only request permits the build and its transient outputs, but no retained edits unless the user also asks to fix failures.

Carry an authorized task through implementation, applicable validation, and related updates. Use prior authorization without asking again. Before an action that needs approval, complete the independent authorized work so the user can review a concrete result.

Commit, push, publish, issue or pull-request changes, credential changes, purchases, other external writes, destructive actions, and material scope expansion require explicit authorization. This includes diagnostic reproductions that change durable or external state.

Explicit user instructions take priority over Skill advice. When guidance blocks work, link its source, quote the rule, and explain why it applies; do not infer a new approval requirement from general caution. Ask before the disputed action if instructions still conflict or a choice changes product behavior or ownership beyond the user's authorization. Continue independent authorized work.

## Collaboration

Inspect `git status --short`, preserve unrelated diffs, and re-read each target file before editing. If an unexpected change overlaps the target or invalidates an assumption, pause that edit and coordinate in a uniquely delimited `HEY.md` block. Remove only your block when resolved; continue other work.

## Reasoning and contracts

Start from the requested observable result. Separate facts, assumptions, and design choices. For behavior changes, trace the current contract and its owning implementation before proposing a repair. Treat omissions, contradictions, and ambiguities as findings when they change behavior; a disagreement with a settled tradeoff is not a finding.

Reason from what can be observed, what can be controlled, and what must be guaranteed. Use available information to choose an adaptive strategy when it changes the result or required effort. Prove worst-case sufficiency for guarantees and a matching lower bound for an exact optimum. State assumptions and uncertainty for estimates. Check arithmetic and that the result answers the actual question.

Current declarations, authoritative user documentation, configured values, authoritative persisted facts, and evidenced callers define the supported contract. Preserve their meaning or update the declaration, storage, callers, and documentation together within the authorized change. The changelog records history; it is not evidence that a product decision was approved.

Do not replace the requested result with a passing test, small diff, convenient abstraction, or happy-path demo. When blocked, identify the failed boundary, dependency, setup, or design decision instead of changing the meaning of success.

## Design priorities and subtraction

Ankole follows the [New Jersey style, “Worse is Better”](https://en.wikipedia.org/wiki/Worse_is_better): simplicity, correctness, consistency, then completeness. Prefer implementation simplicity over interface uniformity. Every supported behavior must still be correct. A narrower contract, clear rejection, or manual recovery can be appropriate; changing an existing contract requires user authorization.

Optimize for the simplest correct system after the change. Before adding a concept, path, dependency, test, or document, look for an existing owner and consider reuse, replacement, or deletion. Confusion alone does not justify removing an abstraction. Small duplication or a local irregularity can be simpler than a common interface, but must not create a second contract owner. When alternatives are equally simple and correct, prefer the one that changes less.

Within the affected scope, a replacement includes removing superseded code, tests, comments, documentation, configuration, completed TODOs, and links. Retain an old form only for an evidenced current caller, authoritative persisted value, external contract, or explicit staged migration, and state its removal condition. Ankole has no released public compatibility contract; hypothetical consumers do not justify shims.

Preserve authoritative user and operator facts. Invalid, meaningless, or superseded state does not need preservation merely because it exists. Before finishing, check what became obsolete and what necessary knowledge or guarantee further deletion would destroy.

### New features

Implement the real path through its domain owner and required SDK, upstream implementation, native boundary, provider protocol, or user flow. Inspect the actual upstream before adapting a dependency. Keep permissions, validation, configuration, and audit work proportional to the required guarantee. Repair a wrong lower boundary within scope; ask before expanding scope.

### Refactors and cleanup

Reduce complexity across the affected system. Remove duplicate concepts and superseded paths at their owner. Split large files by cohesive responsibility and stable public entrypoints; avoid thin delegating layers. Preserve runtime ownership instead of moving behavior to an easier test surface. Remove defenses for states the design cannot produce, or identify the real future requirement.

### Test fixes

Production code must reach the domain contract and production adapter. Unit tests may fake that boundary; integration tests exercise the real adapter or protocol; end-to-end tests follow the real user flow. A requested development fixture may use a labeled fake, but cannot prove an integration or end-to-end guarantee.

Do not weaken assertions, bypass production paths, or move ownership to make a test pass. Before changing a wrong test, name the real contract and its owning source. Fix or isolate broken package-local setup; report external blockers as unverified. Keep public names about domain operations and codec details at internal edges.

## Project boundaries

- One private deployment instance is the product boundary. Do not add hidden SaaS tenant IDs, cross-enterprise identity, or organization routing unless explicitly requested.
- Principal/AuthZ owns accountable subjects and permissions. Do not add parallel subject models or organization-scoped identity.
- Bootstrap configuration may use environment variables or secret mounts for startup facts and credentials needed before storage is reachable. Operator settings belong in declared `Ankole.AppConfigure` keys; runtime-generated credentials and secrets belong in the owning subsystem's encrypted storage.
- Match the owning domain's schema and identifier shape. Do not introduce a local key strategy or database-generated identifier.
- PostgreSQL owns authoritative domain facts whose loss or replay changes user-visible semantics. Use native types and constraints for domain invariants. Other storage may hold rebuildable caches or artifacts when PostgreSQL retains their authoritative lifecycle or references.
- The Elixir control plane owns durable domain state, supervision, and domain-state commit authority. The Rust kernel owns shared native primitives and transport. Bun Agent Computer owns agent execution and rebuildable worker-local state. Worker reads and writes that affect durable semantics use a control-plane-owned contract.
- Model-visible resources and paths must resolve through a real owning runtime contract. Do not expose fake Skills, workspaces, storage locations, or state.
- Extensions are trusted and first-party. Third-party marketplaces, hot-loading, and isolation machinery require an explicit product change.
- Prefer concrete contracts over loose maps and free-form strings.

## Read guidance when it applies

- Changes under `app/webapps/` follow [its AGENTS.md](app/webapps/AGENTS.md); changes under `app/agent_computer/` follow [its AGENTS.md](app/agent_computer/AGENTS.md).
- Use the owning documents in `docs/design-docs/` when changing behavior, schemas, events, storage, transport, or lifecycle. Use language and runtime Skills when the task matches their stated scope. A mechanical edit does not require a full module or repository review.
- If guidance is absent, use the current code and the boundaries above. Ask if ownership remains ambiguous after inspection.
- Use [CONTRIBUTING.md](CONTRIBUTING.md) for environment setup and [check commands](CONTRIBUTING.md#run-the-right-checks) when needed.
- Before completing retained changes or preparing a release, read the [changelog and release rules](CONTRIBUTING.md#keep-design-docs-and-the-changelog-current).

## Tooling

Dependencies needed for an authorized implementation require no separate approval. Prefer existing workspace capabilities or suitable, maintained dependencies over custom implementations of the same behavior. Choose for correctness and total implementation and maintenance cost; minimizing dependency count is not a goal. Update the owning package manifest and the ecosystem's committed lockfile together.

Use Bun as the TypeScript runtime, package manager, and script launcher. Read package `scripts` before a test or build and use the declared entrypoint, including its container or other runtime. Use bare `bun test` or `bun build` only if no entrypoint is declared. A run in the wrong runtime is not code evidence or a baseline. TypeScript dependency changes use `bun install` and update `bun.lock`. Bun loads `.env`; do not add `dotenv`.

Use `@agentbull/active-support` where available for general utilities. It provides Lodash-style helpers and re-exports `ts-pattern`; use `match().with().exhaustive()` for complex branching and `ms('24h')`-style duration helpers. Adding the package follows the dependency rule above.

## Completion and verification

Finish the requested real path and keep its related source, tests, declarations, migrations, generated files, configuration, and documentation consistent. Update the changelog when the work is complete, before any commit. Each commit has one version: add to an existing pending version, or create the next version when the changelog matches `HEAD`. Changes confined to `internals/` that do not affect FOSS use `internals/CHANGELOG.md`.

For implementation changes, run the affected targeted tests and normal static check. Run the relevant dedicated integration or end-to-end command when the guarantee crosses a process, provider, persistence restart, or user-flow boundary and its environment is available. Keep these suites outside the default fast suite.

Once required checks pass, repeat or expand them only for new changes, failures, or unresolved concerns. Do not add tests that only repeat the implementation for a reversible, low-impact edit. For documentation-only work, inspect the diff and links and run the relevant documentation check if one exists. Report the exact command and blocker for a required check that cannot run; do not claim its guarantee as verified.

## Communication and writing

Before the first edit, briefly state what will be removed or reused, how the change will be checked, and any contract risks. One sentence is enough for a mechanical edit. Keep optional progress narration out of chat unless requested or required by a tool. Answer tasks that need no tools in the final response.

Use George Orwell's six rules. Write English documentation and code comments in [ASD-STE100 Simplified Technical English, Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf). Treat project names, identifiers, API names, paths, commands, and approved Ankole terms as technical nouns or verbs.

Lead with the answer and its main caveat. Use direct, connected prose; use lists for sequences, parallel facts, or comparisons. Keep the evidence needed to assess the conclusion. Remove repetition, stock phrases, jargon, and forced contrasts without removing necessary reasoning or limitations. End with a recommendation only when there is a decision to make.

Prefer clear structure and names over comments that narrate implementation. Keep comments that explain non-local rationale, invariants, hazards, or operating constraints. Shareable documents describe the final result and omit drafting notes, completed TODOs, and abandoned alternatives.
