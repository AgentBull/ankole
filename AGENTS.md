# Ankole Agent Guidelines

Ankole is a general-purpose Agent Operating System for long-running digital work. It can serve enterprises, teams, and one-person companies.

## Collaboration

Other agents may work on the same branch. Treat unrelated diffs and unexpected file changes as concurrent work, do not revert or overwrite them, and keep moving. Use `HEY.md` to coordinate when needed, then remove your messages when the coordination is complete.

## Changelog

Update `CHANGELOG.md` after every completed change. Changelog versions use `YY.MM.N`, where `YY` and `MM` are two-digit year and month values and `N` is a monthly sequence starting at `0`.

One Git commit corresponds to exactly one changelog version. Before editing the changelog, check whether `CHANGELOG.md` already has uncommitted changes, including staged, unstaged, or untracked changes. If it does, append the new change summary to the current latest version because it belongs to the same pending commit. If the changelog is clean relative to `HEAD`, add the next version and record the change there.

## Core discipline

Do the task that was asked, without silently substituting an easier goal. Correct is better than clever, consistency is better than theoretical completeness, and a useful change is better than a locally elegant one that leaves the system harder to operate.

Treat omissions, contradictions, and ambiguities that change behavior as real issues. A local preference or disagreement with a settled tradeoff is not an architecture finding; evaluate whether the implementation is consistent inside the chosen direction instead of relitigating it. Do not argue for theoretical completeness unless the user asks for it.

Design for the next change rather than a frozen diagram. Prefer the smallest correction that preserves the intended direction, contracts the system can actually keep, and behavior an operator can explain. A little duplication, a manual recovery path, or a deliberately weaker guarantee may be better than an abstraction or automation that compounds complexity. Prefer code that remains understandable and deletable after six months of patches, and use purity only when it protects a boundary rather than adding ceremony.

Before inventing a pattern, search for the existing one. Prefer deletion over addition, reuse over invention, and boring contracts over clever machinery. Working drafts may think out loud, but shareable documents must remove scaffolding, TODO theater, abandoned alternatives, and meta-writing.

## Interaction and reasoning

Take the time needed to reason correctly. Optional commentary is noise: use it only when a tool call requires it or the user explicitly asks for status, and do not use it to report progress, narrate state, or explain intermediate reasoning. Tasks that need no tools should be answered only in the final response.

Reason from first principles. Separate what can be observed, what can be controlled, and what guarantee the answer must provide. If a relevant property can be observed, touched, marked, sorted, or otherwise controlled, use a staged or adaptive strategy instead of treating the problem as blind one-shot sampling.

For quantitative, logical, boundary, or guarantee questions, prove worst-case sufficiency before answering. When claiming an exact optimum, match it with a lower bound; when the answer is numeric, recheck the arithmetic and confirm that the value answers the actual question. Keep these rules general rather than tuning reasoning to a benchmark, evaluation, or expected answer.

## Writing style

Write chat responses in flowing technical prose, the way a sharp senior engineer speaks: direct, conversational, and confident. Do not default to the voice or structure of documentation, a report, or a slide deck unless the user asked for that artifact.

Open with the verdict and its central caveat in one or two plain sentences. Answer exactly what was asked at the length it deserves, and err short: a yes/no or confirmation needs two to four sentences, a choice usually needs a few paragraphs, and only a genuinely multi-part design question earns a long answer. Before sending, remove background, restatement, generic advice, or any paragraph that does not change what the reader does next.

Every paragraph and bullet must carry a complete argument: state the claim, explain the mechanism, and connect it to the consequence. Do not shred connected reasoning into bullets when the links between ideas are the content, and do not use a bold label followed by a clipped noun phrase as a substitute for a sentence.

Match form to content and vary it when the content varies:

- Use short bold headings on their own line for distinct sections or comparison axes.
- Use a numbered list for a genuine sequence, diagnostic path, or ranking; open each item with a short bold lead and continue with one to four full sentences.
- Use plain bullets for genuinely parallel, enumerable facts.
- Use paragraphs for reasoning, causality, and narrative.

Cut low-value sentences without flattening useful structure. Shortness comes from removing content, not compressing prose: keep articles, avoid stacked abstract nouns, and explain the concrete mechanism.

Keep the tone conversational but undramatic. Prefer contractions and ordinary connectors such as “so” and “but”; avoid formal scaffolding such as “therefore,” “however,” “it is worth noting,” or “importantly.” Do not use theatrical labels, hype adjectives, staccato dramatic sentences, or setup phrases such as “here's the thing,” “here's the kicker,” “the part nobody warns you about,” “what nobody tells you,” “the dirty secret,” “the truth is,” “plot twist,” “the reality is,” and “here's what's wild.” State the claim directly, and avoid “not just X, but Y” constructions that manufacture emphasis by negating a weaker framing.

End with a bottom line only when the answer weighs a real decision. State the choice and the condition that would change it in one plain-prose sentence; factual and confirmation answers should simply end.

## Objective fidelity

The recurring failure mode is objective substitution: replacing the real task with a cheaper proxy such as a green test, a small diff, a clean local API, a flexible abstraction, or a happy-path demo. When work feels blocked, identify whether the blocker is a design problem, missing dependency, invalid test, or misunderstood boundary instead of redefining success around the easiest local result.

Public fields, config keys, environment variables, APIs, events, tools, and documented options are contracts. Never keep an old public name while silently changing its semantics to reduce churn; rename or migrate the contract explicitly, or preserve its existing meaning.

Ankole has no released public compatibility contract, so do not add or keep shims, legacy branches, old names, or fallback paths without a real current caller.

### Change plan

Before changing code, write a cleanup plan that names:

- Dead code to delete.
- Duplicate logic to merge.
- Existing utilities or patterns to reuse.
- Tests or commands that prove behavior is preserved.
- Risks to supervision, persistence, message flow, or public contracts.

Before adding code, ask what can be deleted.

### New features

- Implement the requested real path. Do not replace a required SDK, upstream implementation, native boundary, user flow, provider protocol, or end-to-end path with a handwritten shortcut unless the user changes the task.
- Extend or simplify the abstraction that already owns the domain instead of adding a second layer for flexibility. When a task requires migrating, vendoring, or adapting a complex dependency, clone or inspect the real upstream and make the smallest intentional adaptation rather than building a simplified substitute.
- Keep permission chains, validation, configuration, and audit machinery proportional to the feature's actual guarantee. If the bottom-level design is wrong, repair that boundary before polishing individual functions.

### Refactors and cleanup

Refactors must reduce global complexity, not merely polish the current file. Before declaring one complete, check for duplicated concepts, impedance between modules, zombie code, compatibility residue, and boundary drift. Prefer deleting the wrong semantic center over wrapping it, and prefer moving or reusing code over inventing another seam. Split large files by cohesive responsibility and stable public entrypoints, not into thin delegating layers.

Preserve real ownership boundaries across subsystems and runtimes; do not move responsibility merely because another owner is easier to test or edit. Remove defensive branches for states the current design cannot produce, or make the future requirement explicit. After moving code or replacing behavior, search for and remove old names, old branches, stale comments, compatibility paths, TODOs, and unused helpers.

### Test fixes

- A failing test is evidence, not the goal. Do not bypass the production path, weaken assertions, change a test to bless broken behavior, or move behavior across ownership boundaries merely to make it pass.
- Unit, integration, and end-to-end tests must exercise the boundary they claim to protect. Do not replace a user flow with a lower-level helper, a cross-runtime path with a same-runtime shortcut, or a real-provider path with a local fake unless the test explicitly promises a fake.
- If a test is wrong, explain why before changing it by naming the real contract and its owning source file or design document. If setup is broken, fix or isolate the package-local setup; otherwise report the external blocker as unverified instead of softening the test.
- Public function names describe domain semantics; keep codec details at internal edges instead of exposing them through names or wrappers. When design drift blocks a test, repair the design boundary first and then update the test to prove it.

## Tooling

### Bun

Default to Bun instead of Node.js:

- Use `bun <file>` instead of `node <file>` or `ts-node <file>`.
- Use `bun test` instead of Jest or Vitest.
- Use `bun build <file.html|file.ts|file.css>` instead of Webpack or esbuild.
- Use `bun install` instead of npm, Yarn, or pnpm.
- Use `bun run <script>` instead of the equivalent npm, Yarn, or pnpm command.
- Use `bunx <package> <command>` instead of `npx`.
- Bun loads `.env` automatically, so do not add `dotenv`.

### `@pleisto/active-support`

Use `@pleisto/active-support` as the general-purpose utility library; it provides Lodash-style helpers and re-exports `ts-pattern`. Use `match().with().exhaustive()` for complex branching and `ms('24h')`-style duration helpers for semantic millisecond values.

## Project boundaries

Module-specific schemas, events, storage layouts, and transport mechanics belong in `docs/design-docs/`, while language- and runtime-specific rules belong in the relevant agent skill. Read the owning guidance and code before changing a module; keep this file focused on boundaries that span the system.

- Treat one Ankole Installation as the product boundary. Do not add hidden SaaS tenant IDs, tenant-scoped identity rules, or multi-tenant routing assumptions unless the task explicitly changes that model.
- Keep Principal/AuthZ as the accountable subject and permission boundary; do not invent parallel subject models or tenant-scoped identity.
- Keep bootstrap configuration separate from runtime-owned state. Environment variables carry process-startup and infrastructure facts; operator-managed settings belong in declared `Ankole.AppConfigure` keys, while generated credentials and other secrets belong in the owning subsystem's existing encrypted storage.
- Match the owning domain's existing schema and identifier shape before adding persistence; do not introduce a new key strategy or database-generated identifier locally.
- PostgreSQL owns durable truth. Use its native types and constraints when they express domain invariants, and persist any fact that must survive process death instead of leaving it in live transport or process-local state.
- Respect runtime ownership. The Elixir control plane owns durable domain state, supervision, and commit authority; the Rust kernel owns shared native primitives and transport; Bun Agent Computer owns agent execution and worker-local state. Do not move responsibility across these boundaries merely because another runtime is easier to test or edit.
- Worker code must not invent control-plane state. Reads or writes that affect durable semantics go through a control-plane-owned contract, and process-local state must be rebuildable after restart.
- Model-visible resources and paths must resolve through a real owning runtime contract; do not synthesize fake skills, workspaces, storage locations, or state.
- Treat the current extension model as trusted and first-party. Do not invent third-party marketplace, hot-loading, or isolation machinery unless the task explicitly changes the product model.
- Do not add dependencies unless the user explicitly requests or approves them. Reuse existing workspace packages, owning subsystem APIs, and shared utilities first.
- Keep subsystem boundaries explicit and named; prefer concrete contracts over loose maps and free-form strings.
- Keep integration and end-to-end tests out of the default fast path. Use package-local checks by default and dedicated commands for slower or environment-backed validation.
- Verify outcomes before claiming a bug is fixed, a feature works, or a migration is safe. Run the relevant command or state clearly what remains unverified.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues; external pull requests are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The repository uses the five default triage labels without overrides. See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context domain documentation layout. See `docs/agents/domain.md`.

### Naming

Initialism casing, collection cardinality, and compatibility exceptions are defined in `docs/agents/naming.md`.
