# Ankole Agent Guidelines

Setup instructions, the repository map, and verification commands live in [CONTRIBUTING.md](CONTRIBUTING.md#run-the-right-checks). In addition, `app/webapps/`, `app/agent_computer/`, and `tools/formal/` each provide directory-specific `AGENTS.md` supplements.

## Authorization

Any request to answer, explain, review, audit, diagnose, or plan is strictly read-only. Commits, pushes, package publishes, writes to external services, destructive actions, and changes outside the requested scope require explicit authorization. Finish all authorized work before asking for a decision so the user can approve a concrete result.

User instructions take priority over any Skill or rule file. Whenever a rule blocks an action, quote that rule and explain why it applies.

## Shared worktree

Multiple agents edit this worktree concurrently. Always preserve diffs that belong to other agents. If you hit a conflict that you cannot resolve safely, document it inside a uniquely delimited block in `HEY.md` and remove your block once resolved.

## Design

Follow Worse is Better: prioritize simplicity first, then correctness, consistency, and completeness. A straightforward implementation beats a uniform abstraction, and a narrower contract, explicit rejection, or manual recovery path is usually simpler than an automatic fallback.

Deliver the exact outcome the user asked for—a passing test, a smaller diff, a new abstraction, or a demo is not a substitute. If you are blocked, name the specific boundary, dependency, or product decision standing in the way.

Before introducing a new concept, path, dependency, or document, find the existing owner and reuse, replace, or delete it. Every contract has a single owner. Ankole carries no public backwards-compatibility promise: keep legacy forms only for evidenced callers, persisted data, external contracts, or staged migrations.

Before adding complexity for a speculative or vanishingly unlikely race condition or security edge case, explain the concrete failure mode, its likelihood, and its complexity cost to the user and get explicit buy-in. Do not silently expand scope for theoretical robustness.

## Tests

Production code must exercise the real domain contract and adapter. Only unit tests may fake that boundary; integration tests must run against the real adapter or protocol, and end-to-end tests must follow the real user flow. Never weaken an assertion, bypass a production code path, or shift ownership just to make a test pass.

## Boundaries

- **Site vs. tenant**: A site owns shared infrastructure, while each tenant owns its organization and data. One site runs against one control-plane PostgreSQL database, whereas physical Base tables live on the tenant's assigned Base shard. Every tenant-scoped query requires an explicit process context via `Ankole.Repo`; queries missing that context fail immediately. See [Tenants](docs/design-docs/Tenants.md).
- **Identity and authorization**: Principal and AuthZ own all subjects and permissions. Every Principal belongs to a single tenant and carries one globally unique opaque UID. Never introduce a parallel subject or authorization model.
- **Configuration and secrets**: Environment variables and secret mounts hold only bootstrap facts or credentials needed before PostgreSQL is reachable. Operator-tunable settings belong in declared `Ankole.AppConfigure` keys, and runtime-generated secrets live in the owning subsystem's encrypted storage.
- **Identifiers**: Always use the owning domain's schema and identifier format rather than inventing local key strategies or relying on database-generated IDs.
- **Durable state**: PostgreSQL owns every domain fact whose loss or replay would change user-visible behavior, enforcing invariants with native types and constraints. Other storage systems hold only rebuildable caches and external artifacts referenced by PostgreSQL.
- **Runtime split**: The Elixir control plane owns durable state, supervision, and commit authority. The Rust kernel provides stateless native primitives and transport. The Bun Agent Computer runs agent tools and rebuildable worker-local state; any worker action with durable business meaning must go through a control-plane contract.
- **Ash persistence**: Ash resources and domains own control-plane persistence and cross-domain code interfaces; see [Persistence boundary](CONTRIBUTING.md#persistence-boundary). Spark extensions, transformers, and verifiers (`Ankole.Ash.Resource`, `Ankole.Ash.Domain`) enforce tenant, upsert, and transaction contracts at compile time, while Principal/AuthZ handles authorization instead of Ash policies. Run all resource queries and changesets through `Ankole.Ash` so every operation binds both the `Ankole.Repo` tenant context and `Ankole.LockOrder`.
- **Ash domain structure**: Keep root `Ash.Domain` modules focused on declarations and external `define` interfaces called by other domains, `ankole_web`, plugins, or the application, and place procedural domain logic in submodules. Resource `create`, `update`, and `destroy` actions set `transaction? false` without transaction hooks so they compose cleanly inside a single top-level transaction (`after_commit` hooks run only once that outer transaction commits). Use stateless `Ash.DataLayer.Simple` resources for typed `/api/v2` JSON:API generic actions, and use plain Elixir functions wrapped in `Ankole.Repo.transact_top_level` for private intra-domain multi-step writes rather than `:term` generic actions.
- **Model-visible contracts**: Every resource or path exposed to a model must resolve through a real runtime contract. Never expose stubbed Skills, fake workspaces, or simulated storage state.
- **Extensions**: Extensions are trusted, first-party code. Adding a marketplace, hot-loading, or untrusted plugin isolation requires an explicit product decision.
- **Architecture docs**: Whenever you change behavior, schemas, events, storage, transport, or lifecycle rules, update the owning specification in `docs/design-docs/`.

## Tooling

Run workspace tasks through Bun and the scripts defined in `package.json` so they select the right runtime. Prefer `@agentbull/active-support` whenever it already provides a general-purpose utility.

## Completion

Deliver the full path together—source code, tests, declarations, migrations, generated clients, configuration, and documentation. Before finishing, read your entire diff and remove dead code, empty branches, unused imports, resolved TODOs, and anything superseded by the change.

Run the verification checks in [CONTRIBUTING.md](CONTRIBUTING.md#run-the-right-checks) that cover the boundaries you touched. If a required check cannot run in your environment, report the exact command and what blocked it; never present an unexecuted check as verified.

Write the [changelog entry](CONTRIBUTING.md#changelog) before committing code changes. Write documentation and code comments in clear, natural prose tailored to human readers: put real actors (`Ankole`, the operator, the caller, or the owning module) in subject position rather than personifying inanimate values or missing states, unpack dense noun stacks, maintain smooth Given-before-New paragraph flow with explicit logical connectives, and write localized docs (`zh-Hans`, `ja`, `ko`) idiomatically in the target language rather than calquing English syntax. In timeless documentation (all docs except `CHANGELOG.md` and dedicated upgrade guides), state the current system contract directly: never use diff-relative phrasing (`after this upgrade`, `no longer`, `retains its existing`), negative-space descriptions of deleted paths, prompt-constraint echoes, or paragraphs tacked onto the end of a file outside their owning section.
