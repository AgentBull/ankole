# core

App-local fork of [`@earendil-works/pi-agent-core`](https://github.com/earendil-works/pi/tree/main/packages/agent),
vendored from upstream and trimmed to what BullX uses. See [NOTICE.md](./NOTICE.md) for the pinned upstream
commit, license, the exact kept/removed list, and the re-sync procedure.

## Why a fork (not a dependency)

The Pi agent loop is consumed as a tightly-integrated component. BullX owns the transcript in **Postgres**
instead of Pi's JSONL session storage, so the storage/`Session` layer is removed and `AiAgentRuntime`
rebuilds the pi `Context` from PG rows each turn (projecting them into `SessionTreeEntry[]` for compaction).
core exposes the real upstream API; the integration glue lives in the BullX modules (`runtime.ts`,
`compression.ts`, `conversation-service.ts`).

## Layout

| Area | Files |
| --- | --- |
| Agent loop + state | `agent.ts`, `agent-loop.ts`, `types.ts` |
| Message shapes / context conversion | `harness/messages.ts` |
| Session-tree projection (PG → pi context) | `harness/session/session.ts` (`buildSessionContext`), `harness/types.ts` |
| Compaction | `harness/compaction/compaction.ts`, `harness/compaction/utils.ts` |
| Skills (future capability) | `harness/skills.ts`, `harness/system-prompt.ts` |
| BullX helpers (not upstream) | `bullx.ts` |

Everything is re-exported from `index.ts`.

## What's intentionally not here

JSONL/in-memory session storage, the `Session` class, `AgentHarness`, branch summarization / tree
navigation, prompt templates, the Node filesystem env, and the proxy transport were removed (see NOTICE.md).
The `AgentHarness` mechanisms BullX needed (provider request policy + observability, abort settlement, tool
call policy, context transform + threshold preflight) were ported into `AiAgentRuntime`, not kept here.

Tools and skills keep their upstream type shapes but are not wired into a closed loop in v1 (plain-text only).

## Upgrading `@earendil-works/pi-ai`

It is a normal dependency; after bumping it, smoke-test the import:

```sh
cd app
bun -e "import('@earendil-works/pi-ai').then(m => console.log(Object.keys(m).length))"
```
