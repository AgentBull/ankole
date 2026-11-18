# Ankole Agent Guidelines

Before acting, consider what the user is trying to accomplish. Their words may express that intent indirectly or only in part. Interpret the request in light of the conversation, the product context, and the user's decisions. Refine your understanding as the work unfolds and the user responds. Pursue the intended outcome within the authorized scope and judge completion against it.

[CONTRIBUTING.md](CONTRIBUTING.md) covers setup, the repository map, and verification. Follow the directory-specific `AGENTS.md` in `app/webapps/`, `app/agent_computer/`, and `tools/formal/` when working there.

## Authorization and collaboration

When the user wants an answer, explanation, review, audit, diagnosis, or plan, the work is strictly read-only. Commits, pushes, package publication, writes to external services, destructive actions, and out-of-scope changes require explicit authorization. User instructions take precedence over Skills and rule files. If a rule blocks an action, quote it and explain why it applies. Act on authorization already given without asking for it again.

Finish the authorized work before asking for a decision. Explain the conflict and what the choice would change. When asked for a judgment, state your view, explain the evidence or trade-off behind it, and identify any uncertainty that could change it. Write the final answer so it stands on its own.

## Shared worktree

Preserve other agents' changes. Never run `git stash`, `git reset`, or `git pull --autostash` here. If a dirty tree blocks a pull, fetch and merge in place, resolving conflicts by hand. Record conflicts you cannot safely resolve in a uniquely delimited block in `HEY.md`, and remove your block once resolved.

## Design and review

Code, tests, and documents show how Ankole works today. Align them with approved intent when making changes, and carry settled decisions forward in reviews.

Follow Worse is Better. Choose the simplest implementation that delivers the intended experience and meets operating requirements, then prioritize correctness, consistency, and completeness within that scope. Keep everyday workflows smooth. Explicit rejection or manual recovery can suffice for peripheral cases. Judge simplification by the total cost to users, operators, and maintainers, including friction, performance, capacity, infrastructure, and recovery. When recommending removal, explain the savings and what users or operators would lose.

Every contract has one owner. Before adding a concept, path, dependency, or document, find that owner and consider what you can reuse, replace, or delete. Let the UI or caller coordinate its flow when existing operations suffice. Add backend coordination only when a domain guarantee requires it. Partial success with explicit retry can be acceptable. Keep legacy forms only for evidenced callers, persisted data, external contracts, or staged migrations. Ankole makes no public backwards-compatibility promise.

Trace the real user flow in designs and reviews. For each finding, identify the agreed user story or contract, the concrete failure path, and what users experience or must repeat. Keep accepted limitations and unpromised guarantees out of the blocker list. Handle ordinary wiring and migrations within scope. Preserve domain meanings and ownership. Changes beyond the approved scope to an identifier's meaning, a responsibility boundary, or a user-visible guarantee require a product decision.

## Shared responsibility security model

Functionality and user experience always take precedence over security. Ankole enforces its declared identity, authorization, and isolation contracts. Users and administrators own their authorized choices and the consequences, including harmful ones. Honor those choices without blocking or reconfirming them merely because they carry risk. For a proposed security change, show how a concrete path violates a declared contract and what that means for the approved user flow. Expanding Ankole's responsibilities requires a product decision.

## Boundaries

- **Site and tenant.** A site owns shared infrastructure and uses one control-plane PostgreSQL database. Each tenant owns its organization and data, with physical Base tables on its assigned shard. Tenant-scoped queries fail immediately without explicit process context through `Ankole.Repo`. See [Tenants](docs/design-docs/Tenants.md).
- **Identity and authorization.** Principal and AuthZ own all subjects and permissions. A Principal's identity is `(tenant_id, uid)`. Its `uid` is a meaningful name unique within its tenant. Resolve the tenant from credentials or explicit context before looking up a `uid`.
- **Identifiers.** Use the owning domain's schema and identifier format without relying on database-generated IDs.
- **Configuration and secrets.** Reserve environment variables and secret mounts for bootstrap facts and credentials needed before PostgreSQL is reachable. Declare operator settings in `Ankole.AppConfigure`. Keep runtime-generated secrets in their owner's encrypted storage.
- **State and runtime.** PostgreSQL owns facts whose loss or replay would change user-visible behavior. Enforce invariants with native types and constraints. Other stores hold only rebuildable caches and external artifacts referenced by PostgreSQL. The Elixir control plane owns durable state, supervision, and commit authority. The Rust kernel provides stateless native primitives and transport. The Bun Agent Computer runs agent tools and holds rebuildable Worker state. Worker actions with durable business meaning go through a control-plane contract.
- **Ash.** Ash resources and domains own control-plane persistence and cross-domain interfaces. The `Ankole.Ash.Resource` and `Ankole.Ash.Domain` Spark extensions enforce tenant, upsert, and transaction contracts at compile time. Use `Ankole.Ash` for all resource queries and changesets to bind both tenant context and `Ankole.LockOrder`. Root `Ash.Domain` modules declare external `define` interfaces. Keep procedures in submodules. Resource create, update, and destroy actions set `transaction? false` and omit transaction hooks. Run `after_commit` hooks only once the outer transaction commits. Use plain functions with `Ankole.Repo.transact_top_level` for private intra-domain multi-step writes and stateless `Ash.DataLayer.Simple` resources for typed `/api/v2` JSON:API generic actions. Follow the [persistence boundary](CONTRIBUTING.md#persistence-boundary).
- **Model-visible contracts.** Expose only resources and paths backed by real runtime contracts.
- **Extensions.** Extensions are trusted first-party code. A marketplace, hot-loading, or untrusted plugin isolation requires a product decision.

## Delivery and verification

Use Bun and the workspace's `package.json` scripts. Prefer `@agentbull/active-support` for utilities it already provides. Deliver the requested behavior with the code, tests, declarations, migrations, generated clients, configuration, and docs it requires. Review the full diff for this task and remove dead code, unused imports, resolved TODOs, superseded paths, and unsupported guarantees.

Use the real domain contract and adapter in production. Derive assertions from approved user-visible behavior and update superseded tests. Only unit tests may fake the boundary. Integration tests exercise the real adapter or protocol. End-to-end tests follow the real user flow. Never bypass a production code path or shift ownership to make a test pass. Run the [checks for the boundaries touched](CONTRIBUTING.md#run-the-right-checks). For a required check you could not run, report the exact command and what blocked it.

Update the owning specification in `docs/design-docs/` for changes to behavior, schemas, events, storage, transport, or lifecycle. Follow the [changelog rules](CONTRIBUTING.md#changelog) before committing code. In docs and comments, name who acts, unpack dense noun phrases, and connect new information to what the reader already knows. Follow the [documentation rules](CONTRIBUTING.md#keep-design-docs-and-the-changelog-current) in every language.
