# Ankole Agent Guidelines

Ankole is a general-purpose Agent Operating System for long-running digital work. It can serve enterprises, teams, and one-person companies.

## Scope and authorization

Requests to answer, explain, review, audit, diagnose, or plan authorize read-only inspection and non-mutating checks; do not edit repository files or durable or external state unless the request also asks for a change. Requests to implement, fix, change, create, refactor, or build a named feature or artifact authorize the necessary in-scope repository edits and non-destructive local validation without further approval. A request to run or verify a build authorizes the build command and its transient outputs, not source or retained repository edits, unless it also asks to fix failures.

Do not commit, push, publish, mutate issues or pull requests, change credentials, make purchases or other external writes, run destructive actions, or materially expand scope unless explicitly requested. A diagnostic reproduction that changes durable or external state also requires approval. If a repository rule conflicts with the requested deliverable, report the conflict and ask instead of silently weakening either.

## Collaboration

Other agents may work on the same branch. Preserve unrelated diffs and re-read each target file immediately before editing it. If an unexpected change overlaps the target or invalidates an assumption, pause that edit and coordinate through `HEY.md`; otherwise keep moving. For a dirty changelog, use the commit-ownership rule below. Add a uniquely delimited `HEY.md` block and later remove only that block.

## Changelog

The Git commit is the sole changelog and version unit. Every commit must add exactly one root `CHANGELOG.md` version, and that version must describe every retained source, test, documentation, configuration, schema, migration, manifest, lockfile, and required generated-file change in that commit. One version must not span multiple commits, and one commit must not contain multiple versions. Chat-only work, discarded edits, diagnostics without a retained diff, and temporary `HEY.md` coordination do not allocate versions.

A change confined to `internals/` that does not affect the FOSS part of Ankole is the sole exception: omit it from the root `CHANGELOG.md` and record it in `internals/CHANGELOG.md`.

Normally use 1–4 concise bullets for each version. Write for the product's end users: describe the outcomes they observe and any required operator action, and give a change that users do not experience one brief factual bullet. Do not include file or test inventories or implementation narratives. The bullets must still cover every material retained change in the commit.

Versions use Semantic Versioning as `MAJOR.MINOR.PATCH`, with no leading zeroes, and may add a pre-release suffix `-alpha`, `-beta`, or `-rc`, optionally followed by `.N` for an increasing pre-release number (for example `1.0.0-alpha.1`). Change `MAJOR` only after an explicit human decision, and the same decision sets any pre-release suffix. `PATCH` is the default increment. Increment `MINOR`, and then reset `PATCH` to `0`, only when the commit passes one of these two tests:

1. **New capability.** A user or an operator can now do something with the product that they could not do before. Write that new thing in the bullet. A task that only becomes correct, faster, more reliable, or easier to understand was already possible, so it fails this test.
2. **Breaking technical change.** The commit removes or alters existing behavior, so something that worked stops working, or a person must change configuration, stored data, or an external caller to keep the current behavior. Write the required action in the bullet. Semantic Versioning puts an incompatible change in `MAJOR`, but `MAJOR` waits for a human decision, so it goes here. A retired option, moved boundary, or renamed field that the upgrade migrates on its own fails this test.

Every other change increments `PATCH`, even when users see the difference at once. A bug fix stays `PATCH`, however severe, long-lived, or visible it is, and so does a repair that makes an existing capability match its documentation. Better speed, reliability, limits, defaults, error messages, logs, telemetry, and layout inside an existing capability stay `PATCH`. So do an internal architecture replacement, a large diff, and a change across many subsystems that adds no capability, together with development and test tooling, internal tools, dependency upgrades, and documentation.

If one commit contains both classes, increment `MINOR`, but only when one change passes a test above on its own. `PATCH`-class changes never add up to a `MINOR`. Use `PATCH` when the argument for `MINOR` needs qualification, because `MINOR` is only useful while it marks the commits where the product itself changed.

Write the entry when you complete the work, not when you commit. `CHANGELOG.md` itself tells you which version to write into: when the file has uncommitted changes, add to the newest version in the file, because that version and your change go into the same next commit; when the file matches `HEAD`, add a new version above the newest one according to these increment rules. Keep the entry correct while the retained diff changes. All uncommitted work belongs to the same next commit and therefore to the one pending version, even when it mixes unrelated tasks from different agents; do not flag that mix as a version violation. Split versions only when you intentionally prepare more than one commit, and then give each planned commit its own consecutive version.

For a `main` push that runs the runtime-image workflow, the newest changelog version is also the release identity. After the control-plane and Worker image pair passes verification, the workflow adds the version's immutable image tags and creates the matching `vVERSION` GitHub Release from that changelog section; a version with a pre-release suffix publishes as a GitHub pre-release and moves the `canary` image tag instead of `main-latest`. It must fail instead of moving an existing version to another commit, replacing an existing image tag with another digest, or publishing release notes that differ from the changelog.

## Core discipline

Treat omissions, contradictions, and ambiguities that change behavior as real issues. A local preference or disagreement with a settled tradeoff is not an architecture finding; evaluate whether the implementation is consistent inside the chosen direction instead of relitigating it. Do not argue for theoretical completeness unless the user asks for it.

Optimize for the simplest correct system after the change. Do not optimize for the smallest diff, the fewest touched files, or the fastest removal of the current symptom. A root repair can require an atomic replacement across multiple owners and the deletion of every superseded path. When alternatives leave equally simple and correct systems, prefer the one that changes less. A small evidenced duplication, a manual recovery path, or a deliberately weaker guarantee can be better than an abstraction or automation that compounds complexity, but it must not duplicate the normative owner or preserve a superseded path.

Working drafts may think out loud, but shareable documents must remove scaffolding, TODO theater, abandoned alternatives, and meta-writing.

## Subtraction discipline

Treat subtraction as a first-class design operation. Optimize for the smallest set of concepts and retained knowledge that still makes required behavior, ownership, and real contracts explicit; line count is not the objective. Before adding a concept, path, dependency, comment, test, or document, search for the existing owner and consider reuse, replacement, unification, or deletion. Confusion is a prompt to investigate an abstraction, not proof that the abstraction is wrong.

Within the authorized task and affected ownership surface, a replacement is incomplete until the superseded code, tests, comments, documentation, configuration, completed TODOs, and links are removed. Keep an old form only for an evidenced current caller, persisted value, external contract, or explicit staged migration, and state its removal condition. Do not use cleanup as authority for unrelated edits.

Prefer structure and naming over comments that narrate implementation, especially inside function bodies. Retain comments and prose only when they preserve non-local rationale, invariants, hazards, or operational constraints. Before finishing a retained change, ask both: what became obsolete, and what necessary knowledge or guarantee would further deletion destroy?

## Design priorities

Ankole explicitly follows the [New Jersey style, “Worse is Better”](https://en.wikipedia.org/wiki/Worse_is_better) in the Unix tradition, not the MIT/Stanford “The Right Thing” approach. We believe implementation simplicity gives software better survival, operability, and evolutionary properties than interface uniformity, theoretical completeness, or lossless support for every historical state. A stored row, old shape, or uncommon case does not become a product contract merely because it exists.

The priority order is simplicity, correctness, consistency, then completeness. This ordering does not authorize incorrect behavior inside a declared contract. When simplicity wins, narrow the contract, reject or discard the unsupported case explicitly, or retain a manual recovery path rather than silently producing a wrong result. Preserve authoritative user and operator facts; do not preserve invalid, meaningless, or superseded state merely to make a migration or abstraction appear complete.

1. **Simplicity.** Keep implementation and interface simple, with implementation simplicity taking priority. Prefer a small direct owner and a narrower contract over indirection, policy machinery, or a uniform interface whose implementation is harder to understand, operate, and remove.
2. **Correctness.** Make every supported behavior correct in its observable effects and failure modes. If an uncommon case cannot be handled correctly without disproportionate complexity, do not pretend to support it; fail clearly or leave it outside the contract.
3. **Consistency.** Keep consistency when it reduces the user or maintainer's mental model, but do not force different owners through one abstraction. A small explicit irregularity is better than a complex implementation or hidden semantic mismatch; interface uniformity has the lowest priority when it conflicts with a simple, correct owner.
4. **Completeness.** Cover important and reasonably expected cases. If broader coverage remains simple, accept a local interface irregularity; if it complicates the implementation, leave the uncommon case unsupported and add it only when evidence makes that complexity part of the real product guarantee.

## Interaction and reasoning

Take the time needed to reason correctly. Optional commentary is noise: use it only when a tool call requires it or the user explicitly asks for status, and do not use it to report progress, narrate state, or explain intermediate reasoning. Tasks that need no tools should be answered only in the final response.

Reason from first principles. Separate what can be observed, what can be controlled, and what guarantee the answer must provide. If a relevant property can be observed, touched, marked, sorted, or otherwise controlled, use a staged or adaptive strategy instead of treating the problem as blind one-shot sampling.

For quantitative, logical, boundary, or guarantee questions, prove worst-case sufficiency before answering. When claiming an exact optimum, match it with a lower bound; when the answer is numeric, recheck the arithmetic and confirm that the value answers the actual question. Keep these rules general rather than tuning reasoning to a benchmark, evaluation, or expected answer.

## Writing style

> Use **George Orwell's six rules for writing**

Write all English documentation and code comments in [ASD-STE100 Simplified Technical English, Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf).
Treat project names, code identifiers, API names, file paths, commands, and approved Ankole terms as technical nouns or technical verbs.

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

Do the requested task without substituting a cheaper proxy such as a green test, small diff, clean local API, flexible abstraction, or happy-path demo. When blocked, identify whether the cause is the design, a missing dependency, invalid setup or test, or a misunderstood boundary instead of redefining success around the easiest local result.

Current declarations, authoritative user-facing documentation, persisted or configured values, and evidenced callers are contracts; update them atomically or preserve their meaning. Ankole has no released public compatibility contract, so hypothetical consumers of unused shapes do not justify shims. Preserve an old name only for a current caller or persisted value, or for an explicitly required staged migration that updates the declaration, storage, callers, and documentation.

### Change plan

Before the first repository edit, state a concise cleanup plan in tool-call commentary; this is required context, not optional progress narration. One sentence is enough for a mechanical edit. Otherwise cover relevant dead or duplicate code to remove, existing utilities to reuse, validation, and risks to supervision, persistence, message flow, or public contracts. Treat “what can be deleted?” as an internal scope check, not authority to delete unrelated code or a mandatory user question.

### New features

- Implement the requested real path through the abstraction that owns the domain. Do not replace a required SDK, upstream implementation, native boundary, user flow, provider protocol, or end-to-end path with a handwritten shortcut or parallel flexibility layer. When adapting a complex dependency, inspect the real upstream and make the simplest intentional adaptation in the resulting system.
- Keep permission chains, validation, configuration, and audit machinery proportional to the feature's actual guarantee. Repair a wrong lower boundary when it is within the authorized scope; otherwise report it and request the necessary expansion.

### Refactors and cleanup

Refactors must reduce global complexity, not merely polish the current file. Check for duplicated concepts, impedance between modules, zombie code, compatibility residue, and boundary drift; delete the wrong semantic center rather than wrapping it. Split large files by cohesive responsibility and stable public entrypoints, not into thin delegating layers.

Preserve real ownership boundaries across subsystems and runtimes; do not move responsibility merely because another owner is easier to test or edit. Remove defensive branches for states the current design cannot produce, or make the future requirement explicit. After moving code or replacing behavior, remove only remnants made obsolete by the current change within its affected ownership surface.

### Test fixes

- Production code must reach the domain-owning contract and production adapter. Unit tests may replace that documented boundary with a deterministic fake; integration tests exercise the real adapter or protocol; end-to-end tests traverse the real user flow. An explicitly labeled development fixture may use a fake only when the requested deliverable is the fixture, not to satisfy a feature, integration, or end-to-end requirement.
- A failing test is evidence, not the goal. Do not bypass the production path, weaken assertions, bless broken behavior, or move behavior across ownership boundaries merely to make it pass.
- If a test is wrong, explain why before changing it by naming the real contract and its owning source file or design document. If setup is broken, fix or isolate the package-local setup; otherwise report the external blocker as unverified instead of softening the test.
- Keep public function names domain-semantic and codec details at internal edges. When design drift blocks a test, repair the design boundary first and then update the test to prove it.

## Tooling

### Dependencies

Before adding a dependency in any ecosystem, confirm that an existing workspace package, the owning subsystem API, or a shared utility does not already provide the capability. Add it only as part of an authorized implementation, in the owning package manifest, and update that ecosystem's committed lockfile in the same change.

### Bun

Use Bun as the TypeScript runtime, package manager, installer, and script launcher (`bun`, `bun install`, `bun run`, and `bunx`). Run package-declared test and build tools through Bun and do not replace them solely because of this rule; when a package declares no alternative, default to `bun test` and `bun build`. TypeScript dependency changes use `bun install` and update the committed `bun.lock`. Bun loads `.env` automatically, so do not add `dotenv`.

Read the package `scripts` before you run a test or build. A declared script is the only correct entrypoint, including when it starts a container or another runtime, and a bare `bun test` or `bun build` never substitutes for it. A bare run that reaches the wrong runtime produces environment failures that say nothing about the code; do not report those results, and do not treat them as a baseline.

### `@agentbull/active-support`

Use `@agentbull/active-support` as the general-purpose utility library where it is already available; adding it follows the dependency rule above. It provides Lodash-style helpers and re-exports `ts-pattern`; use `match().with().exhaustive()` for complex branching and `ms('24h')`-style duration helpers.

## Project boundaries

Module-specific schemas, events, storage layouts, and transport mechanics belong in `docs/design-docs/`, while language- and runtime-specific rules belong in the applicable agent skill. Before editing a module, read its scoped guidance, owning design documentation and code, and available language or runtime skill. If no explicit guidance exists, proceed only when ownership is unambiguous from the current code and the boundaries below; if multiple owners remain plausible, ask instead of inventing one. If guidance sources conflict in a way that could change files, commands, ownership, external effects, or claimed outcomes, do not perform the disputed action; report the conflict and ask for resolution.

- For each change under `app/webapps/`, also read and follow `app/webapps/AGENTS.md`.
- For each change under `app/agent_computer/`, also read and follow `app/agent_computer/AGENTS.md`.
- Treat one Ankole private deployment instance as the product boundary. Each enterprise operates its own instance. Do not add hidden SaaS tenant IDs, cross-enterprise identity rules, or routing between organizations unless the task explicitly changes that model.
- Keep Principal/AuthZ as the accountable subject and permission boundary; do not invent parallel subject models or organization-scoped identity.
- Keep bootstrap configuration separate from runtime-owned state. Environment variables or infrastructure secret mounts may carry process-startup facts and credentials required before application storage is reachable. Operator-managed settings belong in declared `Ankole.AppConfigure` keys, while runtime-generated credentials and secrets belong in the owning subsystem's encrypted storage.
- Match the owning domain's existing schema and identifier shape before adding persistence; do not introduce a new key strategy or database-generated identifier locally.
- PostgreSQL owns authoritative domain facts whose loss or replay would change user-visible semantics. Use its native types and constraints for domain invariants; rebuildable caches and artifacts may use owner-specific storage only when PostgreSQL retains their authoritative lifecycle or reference state.
- Respect runtime ownership. The Elixir control plane owns durable domain state, supervision, and domain-state commit authority; the Rust kernel owns shared native primitives and transport; Bun Agent Computer owns agent execution and rebuildable worker-local state. Worker code must not invent control-plane state, and reads or writes that affect durable semantics go through a control-plane-owned contract.
- Model-visible resources and paths must resolve through a real owning runtime contract; do not synthesize fake skills, workspaces, storage locations, or state.
- Treat the current extension model as trusted and first-party. Do not invent third-party marketplace, hot-loading, or isolation machinery unless the task explicitly changes the product model.
- Prefer concrete contracts over loose maps and free-form strings.
- Keep integration and end-to-end tests out of the default fast suite, but do not skip them when the claimed behavior crosses a process, provider, persistence-restart, or user-flow boundary. For implementation changes, run the affected package's targeted tests and normal static check, then the affected dedicated integration or end-to-end command when its environment is available. If a required command cannot run, report the exact command and blocker and do not claim that guarantee as verified. For documentation-only edits, inspect the diff and run the relevant documentation check when one exists.
