/**
 * Per-turn state shared between `stream-fn.ts` (writer) and `agent-loop.ts`'s
 * `beforeToolCall`/`afterToolCall` hooks (readers). One instance per Ankole
 * turn, created and owned by `agent-loop.ts`.
 */

import type { UserMessage as PiUserMessage } from '@earendil-works/pi-ai'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import type { ToolCaller, TruncatedToolCall } from '../llm'

/** One tool call `beforeToolCall` has validated and is about to hand to the wrapped `execute` — see `PiTurnState.activeToolCalls`. */
export interface ActiveToolCall {
  /** The zod-parsed (not pi's typebox-coerced) argument value — see the field doc on `activeToolCalls`. */
  parsedArgs: unknown
  /** `null` means the tool explicitly suppressed its activity row; never re-derived once computed. */
  activity: JSONObject | null
  startedAt: number
}

/**
 * AIGateway wire facts about one tool call that pi-ai's own `ToolCall`/
 * `ToolResultMessage` types have no field for. Written by `stream-fn.ts` when
 * it translates an assistant message's tool calls outbound (the only place a
 * call's `caller`/`type`/`namespace` are known); read by `agent-loop.ts`'s
 * `beforeToolCall` (caller gating) and `afterToolCall` (the `program`-caller
 * terminate exception).
 */
export interface ToolCallWireMeta {
  type: 'function' | 'custom'
  namespace?: string
  caller?: ToolCaller
}

export interface PiTurnState {
  /** Keyed by pi-ai `ToolCall.id` / `ToolResultMessage.toolCallId`. */
  toolCallMeta: Map<string, ToolCallWireMeta>
  /** Lifecycle ActorEvents to complete on the next `recordToolResults` call. */
  pendingCompleteActorEventIDs: string[]
  /**
   * Image/summary adaptation and repeated-failure-nudge follow-ups for the
   * tool call(s) in the current round, collected by `afterToolCall` as plain
   * data (not `agent.steer()` — pi only flushes a steered message into
   * `context.messages` if another round happens, but a follow-up must reach
   * AIGateway in the same `recordToolResults` call as the tool result it
   * belongs to, whether or not the round continues). Drained by
   * `stream-fn.ts`'s `recordToolResultsEagerly`.
   */
  pendingToolResultFollowUps: PiUserMessage[]
  /**
   * Shared with `stream-fn.ts`'s `run()`: the boundary in `context.messages`
   * already sent to AIGateway (via `.call()` or `recordToolResultsEagerly`).
   * Owned jointly because tool results are recorded eagerly, from
   * `agent-loop.ts`'s `prepareNextTurnWithContext`, not from `run()` — see
   * `stream-fn.ts`'s module doc for why that split exists.
   */
  cursor: number
  /**
   * True once a tool call this round has already returned `terminate:true`.
   * pi executes every tool call the model requested in one round regardless
   * of an earlier one's `terminate` (unlike the old hand-rolled loop, which
   * stopped there) — `beforeToolCall` blocks the rest of the round once this
   * is set, so a dangling model-requested call still gets a paired result
   * (just an immediate "turn already ended" one) instead of actually running.
   * Consumed (read and reset) once per round by `shouldStopAfterTurn`, the
   * last hook of a round — pi's own batch-terminate check requires *every*
   * call in the round to terminate, so this flag, not pi, is what ends the
   * turn when a terminating call shares its round with an ordinary one.
   */
  roundTerminated: boolean
  /**
   * Set by `stream-fn.ts` when a round's assistant message hit the output
   * token limit mid-tool-call. pi's own `stopReason:'length'` handling would
   * execute or fail these calls and record a generic message; the diagnostic
   * ("stopped inside the value of...") one is ours, and never anchors on the
   * cut response (see `session.ts`'s `anchorable` check) — so `stream-fn.ts`
   * drops the dangling tool-call content from what pi sees entirely, and
   * `agent-loop.ts`'s `prepareNextTurnWithContext` reads this instead to
   * steer the real salvage message, once per turn.
   */
  pendingTruncatedToolCalls: TruncatedToolCall[]
  /**
   * Keyed by `ToolCall.id`. `beforeToolCall` validates arguments and computes
   * the "running" activity row before pi ever calls `execute()`; the wrapped
   * `execute` (`wrapToolExecute`) reads `parsedArgs` (so a tool truly
   * receives `z.output<TZod>`, not pi's looser typebox-coerced view — see
   * `ActiveToolCall`'s doc); `afterToolCall` reads `activity`/`startedAt` to
   * emit the matching "completed"/"failed" row and duration, then deletes
   * the entry. One entry only ever lives between those two hooks for the
   * same call — never carried across rounds.
   */
  activeToolCalls: Map<string, ActiveToolCall>
  /**
   * The raw error `run()`'s catch block last converted into an
   * `errorAssistantMessage` (a plain pi-ai `AssistantMessage`, whose
   * `errorMessage` field is only ever a string). A terminal, retry-exhausted
   * failure — `stream-fn.ts`'s `terminalModelError` — tags properties like
   * `.retryable` onto the real `Error` object; those would otherwise vanish
   * at that string boundary. `agent-loop.ts` throws this object directly
   * (not a new `Error` built from the string) so a caller inspecting the
   * rejection still sees them. A terminal round always ends `agent.prompt()`
   * immediately, so this can never be stale by the time it's read.
   */
  lastError: unknown
}

export function createPiTurnState(): PiTurnState {
  return {
    toolCallMeta: new Map(),
    pendingCompleteActorEventIDs: [],
    pendingToolResultFollowUps: [],
    cursor: 0,
    roundTerminated: false,
    pendingTruncatedToolCalls: [],
    activeToolCalls: new Map(),
    lastError: undefined
  }
}
