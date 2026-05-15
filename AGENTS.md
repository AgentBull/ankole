# BullX Agent Guidelines

BullX is a general-purpose Agent Operating System built on Elixir/OTP and PostgreSQL for long-running digital work. It can serve enterprises, teams, and one-person companies; the current architecture assumes one BullX Installation as the operating domain rather than a SaaS-style multi-tenant product boundary. This branch is an infra shell after a subtractive cleanup: legacy business subsystems have been removed so the next product shape can be rebuilt from design docs. PostgreSQL is the system of record for durable facts; process-local state must be ephemeral and reconstructible on restart.

## The Zen of BullX Development

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

Prefer deletion over addition.

Prefer reuse over invention.

Prefer boring contracts over clever machinery.

Prefer the chosen guarantee over an imagined stronger one.

Functional programming is not the goal of the Erlang VM.

It is a means to reliable, concurrent, inspectable systems.

Purity is useful when it protects a boundary.

Purity is harmful when it becomes ceremony.

Processes are fault boundaries, not nouns.

Supervision is architecture, not decoration.

If no failure boundary changed, do not move the supervision tree.

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

## Subsystems

BullX is currently an infra-shell branch. Legacy business subsystems were removed so the next product shape can be rebuilt from design docs instead of pre-cleanup implementation history.

The active in-tree concerns are:

- **Core infra** (`lib/bullx/`) — application boot, Repo, config, UUIDv7, NIF boundary, i18n, and an empty Runtime shell.
- **Web shell** (`lib/bullx_web/`, `webui/src/`) — Phoenix, Inertia/SPA boot, UIKit, static setup placeholder, health endpoints, and OpenAPI description plumbing.
- **Externally reusable packages** (`packages/<x>/`) — publishable libraries whose semantics do not depend on BullX.

Do not recreate deleted legacy business implementations or compatibility shims without a design doc that explicitly defines the new scope.

Confirm which area you are editing before applying framework-specific rules below. The Elixir, Mix, Test, and Ecto rules apply everywhere. The Phoenix / LiveView / HEEx / Tailwind rules apply only to code under `lib/bullx_web`.

## Product Direction

The long-term product direction is BullX as a general-purpose AgentOS for durable digital work. It should work for an enterprise department, a small team, or an OPC operator with the same core model: Workflows are reactive process definitions over BPMN-shaped DAGs of Nodes whose Catch, Throw, and Executor attributes describe how each step participates; the engine executes those Workflows as short-lived stateless Segments; Process Instance identity is structural, carried by domain object reference chains in PostgreSQL; Agents carry intelligent responsibility; Brain accumulates memory; and real Segment execution facts drive improvement. The detailed schema and runtime design are not committed yet, so code and docs should stay at the user-story and invariant level unless a design doc specifies implementation detail. `docs/Architecture.md` is the source of truth for the vocabulary and invariants below.

Stable vocabulary for user stories:

- **Installation** — one BullX deployment and its single operating domain. Do not introduce multi-tenant `Tenant` concepts without a design doc.
- **Principal** — an internal subject that can be authorized, audited, and held responsible. Human users, Agents, services, and system actors are all Principals.
- **Connected Realm** — an external identity and event space connected to BullX (Feishu tenant, Slack workspace, GitHub org). It is not a BullX tenant.
- **Workflow** — a reactive process definition: a structurally directed acyclic graph of Nodes describing how the system reacts to domain events. A Workflow does not "complete" or "fail" as a whole; only Segments do.
- **Node** — the only first-class structural element of a Workflow. Every Node carries Catch, Throw, and Executor attributes. The legacy Signal Trigger / Action Node distinction is retired.
- **Catch** — a Node attribute. When true, the Node is a valid entry for matching Signals. Catch declares correlation criteria, which may be open (any Signal of a kind) or keyed (matching a domain object reference stored by a prior Segment).
- **Throw** — a Node attribute. When true, the Node produces an external side effect. Destination identifies the target, which may be a specific external system or the originating Catch context of the current Segment (called Reply).
- **Executor** — a Node attribute. Identifies what runs the Node: deterministic logic, an Agent, a Capability, a SubAgent runtime, a human task, or an external integration.
- **Segment** — one stateless execution of a connected path inside a Workflow, from a Catch Node to a Sink position. Segments are the unit of execution; the engine holds no cross-Segment state. "Run" is a synonym for Segment.
- **Sink position** — a derived property of edge topology and Catch placement: a Node with no outgoing edges, or any downstream Catch Node. Not a Node attribute. The legacy `sink=true` attribute is retired.
- **Correlation** — selects, for each incoming Signal, which Catch on which Workflow Node should start a Segment. Open correlation matches by Signal kind; keyed correlation matches against domain references stored by prior Segments.
- **Process Instance** — the structural identity of a business process across Segments, formed by the reference chain among domain objects in PostgreSQL. The engine does not assign or hold a Process Instance ID.
- **Agent** — a digital work subject with AI work capability: identity, responsibility, long-term memory, permissions, outbound identity, and KPIs. When it runs inside a Workflow it appears as a Node Executor. An Agent is not automatically an LLM process, a chat bot, or a long-lived runtime process.
- **Agentic Loop** — one reasoning and tool-use loop of an Agent. Can run as a Node Executor inside a Workflow or as the body of a one-off SubAgent.
- **Capability** — a governed atomic ability a Node may call: model, tool, browser, sandbox, messaging channel, or external API. External Agent harnesses (Codex, Claude Code, Gemini CLI, ACP) are carried by SubAgent runtime Capability providers, not as new top-level subjects. Approval is not a Capability; it is Node semantics (a Wait Node).
- **Skill** — a procedural knowledge asset whose durable truth lives in PostgreSQL, projected through a virtual file system. A Skill provides knowledge and materials; it does not grant execution power.
- **SubAgent** — a child Agentic Loop. One-off temporary delegation is an ephemeral SubAgent; repeated delegation belongs in a Workflow.
- **Human-in-the-loop** — a Workflow participation pattern implemented as a Wait Node specialized for human input (Human Task, Approval, Policy Gate).
- **Work** — a durable work responsibility that persists across Segments. A Segment may create, advance, pause, resume, or complete Work.
- **Budget** — a governance constraint over tokens, model cost, runtime, tool calls, external spend, or quota.
- **Brain** — the long-term memory and reasoning world model. Brain durable truth lives in PostgreSQL.

Core product stories to keep in mind:

- A customer-success Agent can watch a group conversation, process a risk signal silently, create Work, and notify the account owner privately without speaking in the group.
- One Catch on one Node can fan out into multiple branches inside the same Segment, with irrelevant branches ending at a Node with no outgoing edges — the Workflow graph itself expresses branching and termination.
- A research Agent can combine conversation memory with external market events and retrieve context through an ontology-backed world model.
- An Agent can learn from recorded outcomes of prior Segments, so future Work planning reflects previous failures and successful patterns.
- Customer-facing, financial, legal, or otherwise risky outbound actions must pass through an explicit approval or policy-gate Wait Node before the producing Throw Node executes.

Do not encode the long-term table design, queue topology, adapter list, or runtime process model as if it were already implemented. Those details need a committed design doc before implementation.

## Design-doc-first workflow

BullX implements meaningful features, architectural changes, and complex bug fixes through committed design docs. Formal design docs live under `docs/design-docs/` and describe the current intended design, not a debate transcript or roadmap.

1. A human writes or approves a design doc when the work changes a durable product concept, public contract, schema, supervision boundary, storage model, runtime behavior, or cross-subsystem interaction. The doc should specify the scope of the work, expected module shapes or ownership boundaries, invariants, and acceptance criteria.
2. If no design doc exists, decide whether one is actually required. For narrow fixes, cleanup, tests, wording changes, and other local patches, make the smallest viable inline plan before editing. Do not invent broad architecture for a narrow task.
3. Write a cleanup plan before modifying code.

   The cleanup plan must answer:

   - What can be deleted?

   - What existing utility or pattern can be reused?

   - What code path, process, schema, Node attribute (Catch / Throw / Executor), or public contract is actually changing?

   - What invariant must remain true?

   - What command will verify the result?
4. A coding agent executes the design doc or inline plan. The plan is the source of truth; deviations require explicit justification.
5. A design doc that guided implementation stays committed in the repo as the record of design intent. Keep it aligned with the implemented system; do not leave obsolete alternatives, timeline notes, or proposal scaffolding behind.

Design-doc skills are for creating, rewriting, or editing design docs. Do not invoke them merely to read an existing design doc or inspect its current content; read the file directly.

## Review settled designs correctly

When reviewing an existing design doc, inline plan, architecture note, or user decision, distinguish four things:

1. Omission.
   Something required by the stated design is missing.

2. Contradiction.
   Two stated decisions cannot both be true.

3. Ambiguity.
   The code or document leaves multiple plausible interpretations.

4. Disagreement.
   You would have chosen a different tradeoff.

Report omissions, contradictions, and harmful ambiguities.

Do not report mere disagreement as if it were a defect.

Do not relitigate durability, consistency, latency, availability, purity, normalization, or abstraction choices that the human has already marked as deliberate.

## Project guidelines

- Use `bun precommit` when you are done with all changes and fix any pending issues.
- Use the already included `:req` (`Req`) library for HTTP requests
- Prefer deletion over addition. If the same behavior can be preserved by removing code, remove code.
- Reuse existing utilities and patterns first. Search before creating a new helper, module, behaviour, process, schema, or dependency.
- If a PostgreSQL table primary key is UUID, BullX code must generate the value with `BullX.Ext.gen_uuid_v7/0` before insert. In Ecto schemas, standardize this as `@primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}` and do not rely on PostgreSQL-side UUID defaults such as `gen_random_uuid()`.
- Prefer PostgreSQL-native types and constraints when they model the domain directly. Use native `CREATE TYPE … AS ENUM` for closed sets mapped through `Ecto.Enum`, `jsonb` for structured payloads, native `interval` / `tstzrange` / `numeric(p,s)` for their domains, and table-level CHECK/EXCLUDE/foreign-key constraints rather than re-implementing the same invariant in Elixir. Only fall back to generic `:text` plus a CHECK constraint when the value set is genuinely open-ended or expected to change without a migration.
- Do not add dependencies unless the user explicitly requests or approves them.
- Do not introduce a new abstraction for a single use. Wait for repeated pressure or a clearly named domain boundary.
- Do not optimize for the local patch at the cost of future change. Code is not static. It will move, split, merge, and be deleted.
- Keep public contracts boring. Prefer explicit structs, schemas, Nodes with declared Catch / Throw / Executor attributes, and audit records over loose maps and freeform strings.
- Keep process state reconstructible. Process-local state is ephemeral and must be safe to rebuild on restart.
- Multiple coding agents may work in parallel on the same branch. Unrelated files or diffs in Git status are normal; do not revert or touch them unless your task explicitly requires it.
- Verify outcomes before final claims. Do not say a bug is fixed, a feature works, or a migration is safe unless you ran the relevant command or clearly state what remains unverified.

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

## Shareable document hygiene
Working drafts may be messy.

Shareable documents must be clean.

Do not leave meta-writing scaffolding in committed docs:
- no "draft below"
- no "here is a polished version"
- no "I will now"
- no outline markers that are not part of the document
- no unresolved TODOs unless the document intentionally tracks work
- no duplicated alternatives unless the document is explicitly comparing alternatives

When writing README, design doc, plan, prompt, policy, or operator-facing documentation:
- Write the final artifact, not a transcript of how you got there.
- Remove internal reasoning markers.
- Remove abandoned headings.
- Resolve placeholders.
- Keep examples consistent with the current codebase.
- Prefer direct instructions over commentary about the instructions.

## Elixir

Use `elixir-coding` skills (./.agents/skills/elixir-coding/SKILL.md) when working in Elixir files.

When deciding between `@moduledoc` and `@moduledoc false`:
- Add `@moduledoc` only when it contributes information that is not already obvious from the code.
- Keep `@moduledoc false` when the module is self-explanatory and the doc would only restate names, fields, callbacks, or standard Elixir / OTP / Ecto behavior.
- Add `@moduledoc` when the module carries BullX-specific conventions, assumptions, invariants, failure-boundary facts, durable-versus-ephemeral truth, protocol contracts, or business background that a competent Elixir engineer would not reliably infer from the implementation alone.
- Prefer short English `@moduledoc` focused on the non-obvious boundary or contract. Do not turn module docs into line-by-line paraphrases of the code.

## Phoenix subsystem (lib/bullx_web only)

> The following three sections — Phoenix v1.8, JS and CSS, UI/UX & design — apply only when editing code under `lib/bullx_web`.

Please use `phoenix-coding` skills (./.agents/skills/phoenix-coding/SKILL.md) when working in the Phoenix subsystem.

## Elixir Rust NIFs

We use `rustler` to build Rust NIFs for CPU-intensive tasks that require performance beyond what Elixir can provide. 

Please use `elixir-rust-nif-coding` skills (./.agents/skills/elixir-rust-nif-coding/SKILL.md) when working on Rust NIFs. 
