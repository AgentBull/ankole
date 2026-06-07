# core NOTICE

`core` is a BullX-local fork of the `@earendil-works/pi-agent-core` package (`packages/agent`) from the
Pi project.

- Upstream: https://github.com/earendil-works/pi/tree/main/packages/agent
- Forked at commit: `89a92207f1c9303d53d822fd9b0ac21578834cb4` (`@earendil-works/pi-agent-core@0.78.1`)
- License: MIT

The companion provider package `@earendil-works/pi-ai` (same version line) is consumed as a normal npm
dependency, not vendored. Upstream's runtime deps `ignore`, `typebox`, and `yaml` were added to
`app/package.json` so the vendored harness compiles.

```
MIT License

Copyright (c) 2025 Mario Zechner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Fork method

The upstream `packages/agent/src` tree was copied in verbatim, then trimmed to what BullX uses. The agent
loop, compaction, session-tree projection, message shapes, and skill formatting are upstream code with no
behavioral deltas.

## What is vendored (kept, ~verbatim apart from formatting/import paths)

- `agent.ts`, `agent-loop.ts`, `types.ts` — low-level `Agent`, the agent loop, and core agent types.
- `harness/messages.ts` — `convertToLlm` and the compaction/custom/bash message shapes + constructors.
- `harness/compaction/compaction.ts` + `compaction/utils.ts` — the real compaction helpers
  (`prepareCompaction`, `compact`, `generateSummary`, `estimate*`, `shouldCompact`, `findCutPoint`, …).
- `harness/session/session.ts` — the pure `buildSessionContext` projection only.
- `harness/types.ts` — `Result`/`CompactionError` helpers, `Skill`, the filesystem capability shapes
  (`FileSystem`/`Shell`/`ExecutionEnv`), and the `SessionTreeEntry` types + `SessionContext`.
- `harness/skills.ts`, `harness/system-prompt.ts` — the `Skill` shape and pure system-prompt formatting,
  kept as a future capability (no filesystem loader is wired in v1).

## BullX additions

- `bullx.ts` — `createUserMessage` (upstream keeps it private) and `textFromAgentMessage` (not in upstream),
  needed because BullX rebuilds the pi context from Postgres rows.

## Removed from upstream

- **JSONL session storage** (`session/jsonl-storage`, `session/jsonl-repo`) and **in-memory storage**
  (`session/memory-storage`, `session/memory-repo`, `session/repo-utils`, `session/uuid`), plus the
  `Session` class and `SessionStorage`/`SessionRepo` interfaces. BullX owns the transcript in Postgres
  (`ai_agent_messages` / `ai_agent_conversations`) and projects rows into `SessionTreeEntry[]` on demand
  (`conversation-service.ts` `sessionEntries`); only `buildSessionContext` and the entry shapes are needed.
- **`AgentHarness`** (`harness/agent-harness.ts`). BullX's `AiAgentRuntime` is the harness. Its useful
  mechanisms were ported into the runtime before deletion (see below); the now-dead harness event/option/
  result types were pruned from `harness/types.ts`.
- **Branch summarization / tree navigation** (`compaction/branch-summarization.ts`, `BranchSummary*` entry/
  message types, `Session.moveTo`, `navigateTree`). BullX has no branch feature.
- **Prompt templates** (`harness/prompt-templates.ts`). Not used.
- **Node/filesystem env** (`harness/env/nodejs.ts`, `node.ts`) and **shell/truncate utils**
  (`harness/utils/*`). No filesystem `ExecutionEnv` in v1 (the `FileSystem` *shape* is kept for the future).
- **`proxy.ts`** (RPC/proxy transport). BullX calls pi-ai's `streamSimple` directly.

## AgentHarness capabilities ported into `AiAgentRuntime` (outside core)

Before deleting `agent-harness.ts`, its load-bearing mechanisms were reimplemented in
`app/src/ai-agent/runtime.ts` / `run-registry.ts`:

- **Provider request policy + observability** — curated provider stream options (apiKey/maxTokens/
  temperature/cacheRetention) + per-turn `metadata` tags, plus `onPayload`/`onResponse` capture folded into
  `ai_agent_llm_turns.provider_metadata` (mirrors `before_provider_payload` / `after_provider_response`).
- **Abort settlement** — `AiAgentRunRegistry.abortAndWait()` aborts and awaits `Agent.waitForIdle()`; used
  by `/stop` and `/new` (mirrors `AgentHarness.abort` settlement).
- **Tool call policy** — a tool registry with `setTools` / `setActiveTools` + uniqueness/known-name
  validation, wired into the `Agent` via `beforeToolCall` / `afterToolCall` (dormant until tools exist).
- **Context transform + threshold preflight** — `transformContext` hook plus a `shouldCompact` preflight
  before each generation.

## Adaptations to vendored files

- Stripped `.ts` extensions from relative import / `declare module` specifiers (the app tsconfig does not
  enable `allowImportingTsExtensions`).
- Reformatted to the app style (oxfmt: 2-space, single-quote, no-semicolon) and fixed a few oxlint
  correctness nits (non-behavioral).

## Re-syncing with upstream

cp the upstream `packages/agent/src` at a newer commit, strip `.ts` import extensions, run oxfmt, then
re-apply the trims above. Update the pinned commit at the top of this file.
