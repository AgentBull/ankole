# Ankole Agent Guidelines

Ankole is a general-purpose Agent Operating System for long-running digital work. It can serve enterprises, teams, and one-person companies; the current architecture assumes one Ankole Installation as the operating domain rather than a SaaS-style multi-tenant product boundary. 

## The Zen of Ankole Development

Do the task that was asked.

Do not silently change the task.

Correct is better than clever.

Consistent is better than complete.

Useful is better than theoretically perfect.

A deliberate tradeoff is not a bug.

A local preference is not an architecture finding.

Omissions matter.

Contradictions matter.

Ambiguities matter when they change behavior.

Mere disagreement is usually noise.

Reality is not smooth.

Production systems are negotiated with time, cost, failure, and change.

Code is not static.

Code grows, bends, splits, merges, and dies.

Design for the next change, not for a frozen diagram.

Simplicity is not shallowness.

Completeness is not always responsibility.

Edge cases have diminishing returns.

Complexity compounds.

Rot compounds faster.

Simplicity and ROI are measured in the system a change leaves behind, not in the writing or changing of the code.

The cheapest change to make is often the most expensive system to live with.

Prefer deletion over addition.

Prefer reuse over invention.

Prefer boring contracts over clever machinery.

Prefer the chosen guarantee over an imagined stronger one.

Purity is useful when it protects a boundary.

Purity is harmful when it becomes ceremony.

Before changing code, write the cleanup plan.

Before adding code, ask what can be deleted.

Before inventing a pattern, search for the existing one.

Before criticizing a tradeoff, check whether it was already settled.

If it was settled, inspect inside it.

Do not relitigate it.

Working drafts may think out loud.

Shareable documents must not.

Remove scaffolding, TODO theater, abandoned alternatives, and meta-writing before committing docs.

### Scope fidelity

When a document says a tradeoff is final, evaluate consistency inside that tradeoff.

Do not argue for theoretical completeness unless the user asked for it.
Do not optimize for a perfect static design. This system will change.

A design that handles every imagined edge case today may become the source of tomorrow's rot.

Prefer the smallest correction that preserves the chosen direction.

If something looks risky, first ask:
- Is it actually inconsistent with the stated goal?
- Is it an omission inside the chosen design?
- Is it a contradiction against another explicit decision?
- Or am I merely disagreeing with the tradeoff?

Only the first three are useful by default. The fourth is noise unless explicitly requested.

### Reality bias

Real systems are uneven.

Do not assume the cleanest theoretical model is the responsible one.

A little duplication may be better than a premature abstraction.

A manual recovery path may be better than a complex automatic one.

A weaker guarantee may be better than code that nobody can safely change.

Prefer designs that remain understandable after six months of patches.

Prefer code that can be deleted.

Prefer behavior that can be explained to an operator.

Prefer guarantees that the system can actually keep.

## Bun

Default to using Bun instead of Node.js.

- Use `bun <file>` instead of `node <file>` or `ts-node <file>`
- Use `bun test` instead of `jest` or `vitest`
- Use `bun build <file.html|file.ts|file.css>` instead of `webpack` or `esbuild`
- Use `bun install` instead of `npm install` or `yarn install` or `pnpm install`
- Use `bun run <script>` instead of `npm run <script>` or `yarn run <script>` or `pnpm run <script>`
- Use `bunx <package> <command>` instead of `npx <package> <command>`
- Bun automatically loads .env, so don't use dotenv.

## PostgreSQL

Make good use of PostgreSQL's data types and features to achieve better designs, instead of using the database in the crude, lowest-common-denominator way typical of MySQL.

## @pleisto/active-support

Use `@pleisto/active-support` as the general-purpose utility library. It provides Lodash-style helper functions and also re-exports `ts-pattern`.

- For complex if/else logic, use its `match().with().exhaustive()` syntax.
- For millisecond durations, use its exported `ms('24h')`-style functions to keep them semantic.

## Cleanup and refactor rules
For cleanup or refactor work, write the cleanup plan before modifying code.

A cleanup plan must list:

- Dead code to delete.

- Duplicate logic to merge.

- Existing utilities or patterns to reuse.

- Tests or commands that prove behavior is preserved.

- Risks to supervision, persistence, message flow, or public contracts.

Prefer deleting obsolete code to wrapping it.

Prefer moving code to inventing code.

Prefer one clear boundary to many clever seams.

Do not keep compatibility shims unless there is a real caller.

Do not leave old names, old branches, old TODOs, or old comments behind after replacing behavior.

When a refactor touches OTP structure, state which failure boundary changed.

If no failure boundary changed, avoid changing the supervision tree.

## Project guidelines

- Treat one Ankole Installation as the product boundary. Do not add hidden SaaS tenant ids, tenant-scoped identity rules, or multi-tenant routing assumptions unless the task explicitly changes that model.
- Keep Principal/AuthZ as the accountable subject and permission boundary. Principal UIDs are installation-wide lowercase subject keys; do not invent parallel user, agent, or external-subject models in Bun, plugins, or provider adapters.
- Keep bootstrap configuration and AppConfigure separate. Environment variables are for process startup and infrastructure facts; operator-managed runtime settings, generated worker auth keys, provider credentials, plugin settings, and model preferences belong in declared `Ankole.AppConfigure` keys.
- Match the existing persistence shape before adding schema. Principals use text `uid` keys, and provider mirrors/outbox rows may use domain or composite keys. When a row needs an opaque PostgreSQL UUID id, generate it in application code with `Ankole.Ecto.UUIDv7` for Ecto schemas or `Ankole.Kernel.gen_uuid_v7/0` for explicit row ids outside Ecto schema inserts; do not rely on PostgreSQL defaults such as `gen_random_uuid()`.
- Prefer PostgreSQL-native modeling when it clarifies the domain: native enums mapped through `Ecto.Enum`, `jsonb` for declared payloads, range/interval/numeric types where they fit, and database constraints for invariants that must survive process crashes.
- Keep SignalsGateway as the provider-ingress boundary: adapters produce ingress facts, provider mirror rows record observed external state, `actor_inputs` are the actor-facing handoff, and `signal_gateway_outbox` is the durable provider-visible side-effect path. Provider raw event names must not leak into runtime semantics when an `ActorInput.type` contract is needed.
- Keep RuntimeFabric as live transport, not durable truth. ZeroMQ carries actor, RPC, and worker-file traffic with bounded routing/backpressure; PostgreSQL owns replay, fences, reconciliation, and final commits. If a fact matters after process death, journal or commit it in PostgreSQL.
- Respect runtime ownership boundaries. Elixir owns PostgreSQL semantics, setup, supervision, AppConfigure, Principal/AuthZ facades, and actor commit authority. Rust kernel owns crypto, shared identifier helpers, AuthZ rule evaluation, protobuf validation, and ZeroMQ mechanics. Bun Agent Computer owns LLM loops, tools, MCP servers, terminal state, and worker-local filesystem behavior.
- Worker code must not invent control-plane state. Reads or writes that affect PG-owned semantics go through RuntimeFabric RPC or an explicit control-plane API; process-local worker state must be rebuildable after restart.
- Keep enabled skills and workspaces honest. Models may see `skill://enabled/...` references, but worker reads resolve from RuntimeFabric skill metadata, built-in image assets, managed shared skill storage, and PG skill overlays. Do not synthesize fake `/workspace/skills` or library-container paths.
- Treat plugins as trusted first-party Elixir code discovered at boot. Do not add dynamic third-party plugin loading, marketplace isolation, hot activation, or plugin-owned config stores unless the plugin design docs are updated first.
- Do not add dependencies unless the user explicitly requests or approves them. Reuse existing workspace packages, kernel bindings, Phoenix contexts, Bun utilities, and `@pleisto/active-support` helpers first.
- Keep public contracts boring and named: Ecto schemas, context facades, AppConfigure definitions, plugin declarations, RuntimeFabric envelopes, actor inputs, signal bindings, outbox entries, and explicit TypeScript/Rust types are better than loose maps and freeform strings at subsystem boundaries.
- Keep runtime and worker integration tests out of the default fast test path. Use package-local checks by default and dedicated Mix/Bun commands for Docker-backed Agent Computer or real-provider e2e flows.
- Multiple coding agents may work in parallel on the same branch. Unrelated files or diffs in Git status are normal; do not revert or touch them unless your task explicitly requires it.
- Verify outcomes before final claims. Do not say a bug is fixed, a feature works, or a migration is safe unless you ran the relevant command or clearly state what remains unverified.
