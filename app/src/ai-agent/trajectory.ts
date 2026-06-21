// Trajectory replay is a README-pillar capability. The rebuild functions below
// currently have test-only consumers; runtime wiring arrives with the replay
// surface, so do not treat them as dead code.
import { eq } from 'drizzle-orm'
import type { Message } from '@/llm'
import { DB } from '@/common/database'
import { AiAgentLlmTurns, AiAgentMessages, type JsonObject, type JsonValue } from '@/common/db-schema'
import { isJsonObject, numberFromPath, stringFromPath } from '@/common/json'
import { convertToLlm, createCompactionSummaryMessage, createUserMessage, type AgentMessage } from './core'
import { textFromContent } from './conversation-service'

export type AiAgentLlmTurnRow = typeof AiAgentLlmTurns.$inferSelect
export type AiAgentMessageRow = typeof AiAgentMessages.$inferSelect

/** The reconstructed LLM request for one turn: what was (or would have been) sent to the provider. */
export interface ReconstructedLlmTurnRequest {
  /** The agent-level messages the request was built from, after applying any stored overrides. */
  agentMessages: AgentMessage[]
  /**
   * True when a verbatim `llm_request` patch was stored, so `messages`/`systemPrompt` are the EXACT bytes
   * sent. False means they were re-derived from refs + overrides and are a faithful but rebuilt copy.
   */
  exactLlmRequest: boolean
  /** Provider-shaped messages, either replayed from the exact patch or converted from `agentMessages`. */
  messages: Message[]
  patches: JsonValue[]
  refs: JsonValue[]
  systemPrompt: string | null
  tools: JsonValue[]
}

export interface ReconstructedLlmTurn {
  agentUid: string
  branchId: string | null
  callIndex: number | null
  completedAt: Date | null
  conversationId: string
  kind: string
  leaseId: string | null
  llmTurnId: string
  model: string
  parentBranchId: string | null
  profile: string
  provider: string
  providerMetadata: JsonObject
  request: ReconstructedLlmTurnRequest
  response: JsonObject
  startedAt: Date
  status: string
  toolResults: JsonValue[]
  triggerMessageId: string | null
  usage: JsonObject
}

/**
 * One generation lease selected for export: the winning attempt at responding to a single trigger
 * message, collapsing any retries within that lease into one entry.
 */
export interface ExportableGenerationLease {
  callCount: number
  completedAt: Date | null
  conversationId: string
  kind: string
  leaseId: string
  startedAt: Date
  /** Aggregate over the lease's turns; `mixed` when they disagree and no single category dominates. */
  status: 'succeeded' | 'failed' | 'cancelled' | 'started' | 'mixed'
  triggerMessageId: string
  turnIds: string[]
}

/** Loads every llm_turn and message for a conversation and reconstructs the full ordered trajectory. */
export async function loadLlmTurnTrajectory(conversationId: string): Promise<ReconstructedLlmTurn[]> {
  const [turns, messages] = await Promise.all([
    DB.select()
      .from(AiAgentLlmTurns)
      .where(eq(AiAgentLlmTurns.conversationId, conversationId))
      .orderBy(AiAgentLlmTurns.startedAt, AiAgentLlmTurns.id),
    DB.select()
      .from(AiAgentMessages)
      .where(eq(AiAgentMessages.conversationId, conversationId))
      .orderBy(AiAgentMessages.createdAt, AiAgentMessages.id)
  ])
  return reconstructLlmTurnTrajectory({ turns, messages })
}

/**
 * Rebuilds the ordered per-turn trajectory from raw llm_turn and message rows (the pure core of
 * {@link loadLlmTurnTrajectory}, also driven directly by tests).
 *
 * Each turn's request is reconstructed one of two ways. When the turn stored a verbatim `llm_request`
 * patch, those exact messages/system prompt are replayed (`exactLlmRequest`). Otherwise the messages are
 * re-derived: resolve the stored refs back to their messages, apply any `message_override` patches (the
 * model-view transforms recorded by the renderer), and convert to provider shape. The second path is why
 * a turn can be inspected even when the exact bytes were not captured.
 */
export function reconstructLlmTurnTrajectory(input: {
  messages: AiAgentMessageRow[]
  turns: AiAgentLlmTurnRow[]
}): ReconstructedLlmTurn[] {
  const messagesById = new Map(input.messages.map(row => [row.id, row] as const))
  const turnsById = new Map(input.turns.map(row => [row.id, row] as const))
  const sortedTurns = [...input.turns].sort(compareTurns)
  // Tool definitions are recorded only on the turn where they change, so they are carried forward across
  // turns: each turn inherits the last-seen set until a new `llm_tool_definitions` patch overrides it.
  let tools: JsonValue[] = []

  return sortedTurns.map(turn => {
    const patches = jsonArray(turn.requestPatches)
    for (const patch of jsonObjects(patches)) {
      if (patch.type === 'llm_tool_definitions') tools = jsonArray(patch.tools)
    }

    // Last `llm_request` patch wins — if a turn was rewritten, the freshest capture is the one that ran.
    const exactRequest = [...jsonObjects(patches)].reverse().find(patch => patch.type === 'llm_request')
    const requestContext = jsonObjectOrEmpty(turn.requestContext)
    // Prefer the system prompt from the exact request; fall back to the lighter requestContext snapshot
    // when only that was stored.
    const systemPrompt =
      stringFromPath(exactRequest ?? {}, ['system_prompt']) ?? stringFromPath(requestContext, ['system_prompt']) ?? null
    const refs = jsonArray(turn.requestRefs)
    const agentMessages = resolveAgentMessages(refs, messagesById, turnsById)
    // Overrides are already baked into an exact request, so they are applied only on the rebuilt path.
    const patchedAgentMessages = exactRequest ? agentMessages : applyMessageOverrides(agentMessages, patches)
    const messages = exactRequest ? llmMessagesFromPatch(exactRequest) : convertToLlm(patchedAgentMessages)

    return {
      agentUid: turn.agentUid,
      branchId: turn.branchId,
      callIndex: turn.callIndex,
      completedAt: turn.completedAt,
      conversationId: turn.conversationId,
      kind: turn.kind,
      leaseId: turn.leaseId,
      llmTurnId: turn.id,
      model: turn.model,
      parentBranchId: turn.parentBranchId,
      profile: turn.profile,
      provider: turn.provider,
      providerMetadata: jsonObjectOrEmpty(turn.providerMetadata),
      request: {
        agentMessages: patchedAgentMessages,
        exactLlmRequest: Boolean(exactRequest),
        messages,
        patches,
        refs,
        systemPrompt,
        // Deep-copied because `tools` is the carry-forward accumulator shared across iterations; without
        // the clone, a later turn's tool change would retroactively mutate this turn's recorded tools.
        tools: structuredClone(tools)
      },
      response: jsonObjectOrEmpty(turn.response),
      startedAt: turn.startedAt,
      status: turn.status,
      toolResults: jsonArray(turn.toolResults),
      triggerMessageId: turn.triggerMessageId,
      usage: jsonObjectOrEmpty(turn.usage)
    }
  })
}

/**
 * Picks the single authoritative generation lease per trigger message, so an export shows one clean run
 * for each user prompt rather than every retry and abandoned attempt.
 *
 * A trigger may have been answered across multiple leases (crash takeover, overflow retry). The selection
 * prefers GROUND TRUTH: when a transcript is available, the winning lease is the one whose turn actually
 * produced a visible assistant message (`committed`) — that is the reply the user really saw, even if
 * another lease also reported success. Without a transcript it falls back to any `succeeded` lease. Among
 * the candidates the latest start wins, and the result is sorted into chronological conversation order.
 *
 * `transcript_effect` rows (edited/redacted history) are excluded from the visible set so a rewritten
 * message does not anoint the wrong lease.
 */
export function selectExportableGenerationLeases(
  turns: AiAgentLlmTurnRow[],
  messages: AiAgentMessageRow[] = []
): ExportableGenerationLease[] {
  const hasTranscript = messages.length > 0
  // The turn ids that produced an assistant message still present in the transcript — i.e. replies the
  // user actually saw. This is the evidence used to pick the committed lease below.
  const visibleAssistantTurnIds = new Set(
    messages.flatMap(row => {
      if (row.role !== 'assistant') return []
      if (row.metadata.transcript_effect) return []
      const llmTurnId = row.metadata.llm_turn_id
      return typeof llmTurnId === 'string' && llmTurnId.length > 0 ? [llmTurnId] : []
    })
  )
  // Group export-eligible turns by (conversation, trigger message): one bucket per user prompt.
  const groups = new Map<string, AiAgentLlmTurnRow[]>()

  for (const turn of turns) {
    if (!isGenerationExportTurn(turn)) continue
    // Skip turns missing the identity needed to attribute them to a lease+trigger.
    if (!turn.leaseId || turn.callIndex === null || !turn.triggerMessageId) continue
    const key = `${turn.conversationId}:${turn.triggerMessageId}`
    const bucket = groups.get(key) ?? []
    bucket.push(turn)
    groups.set(key, bucket)
  }

  return [...groups.values()]
    .flatMap(group => {
      const leases = groupLeases(group)
      // Committed = a lease whose turn left a visible assistant message. With a transcript this is the
      // trusted signal; without one, fall back to leases that merely reported success.
      const committed = leases.filter(lease => lease.turnIds.some(id => visibleAssistantTurnIds.has(id)))
      const candidates = hasTranscript ? committed : leases.filter(lease => lease.status === 'succeeded')
      const selected = latestLease(candidates)
      return selected ? [selected] : []
    })
    .sort(
      (left, right) => left.startedAt.getTime() - right.startedAt.getTime() || left.leaseId.localeCompare(right.leaseId)
    )
}

// Only primary-model answer-producing turns are exportable. Compaction/light-model turns and other
// profiles are infrastructure, not part of the user-visible run, so they are excluded.
function isGenerationExportTurn(turn: AiAgentLlmTurnRow): boolean {
  return (
    turn.profile === 'primary' &&
    (turn.kind === 'generation' || turn.kind === 'retry_generation' || turn.kind === 'overflow_retry')
  )
}

/** Collapses a trigger's turns into per-lease summaries (one entry per lease, with aggregate status). */
function groupLeases(turns: AiAgentLlmTurnRow[]): ExportableGenerationLease[] {
  const grouped = new Map<string, AiAgentLlmTurnRow[]>()
  for (const turn of turns) {
    if (!turn.leaseId) continue
    const bucket = grouped.get(turn.leaseId) ?? []
    bucket.push(turn)
    grouped.set(turn.leaseId, bucket)
  }

  return [...grouped.entries()].flatMap(([leaseId, rows]) => {
    const ordered = rows.sort(compareTurns)
    const first = ordered[0]
    const last = ordered.at(-1)
    if (!first || !last || !first.triggerMessageId) return []
    return [
      {
        callCount: ordered.length,
        // Completion time only when EVERY turn finished; an unfinished turn leaves the lease open-ended.
        completedAt: ordered.every(row => row.completedAt) ? last.completedAt : null,
        conversationId: first.conversationId,
        kind: last.kind,
        leaseId,
        startedAt: first.startedAt,
        status: leaseStatus(ordered),
        triggerMessageId: first.triggerMessageId,
        turnIds: ordered.map(row => row.id)
      }
    ]
  })
}

// The most recently started lease (id breaks ties deterministically). Used to pick the freshest among
// equally-valid candidates — a later attempt supersedes an earlier one for the same trigger.
function latestLease(leases: ExportableGenerationLease[]): ExportableGenerationLease | undefined {
  return leases
    .slice()
    .sort(
      (left, right) => right.startedAt.getTime() - left.startedAt.getTime() || right.leaseId.localeCompare(left.leaseId)
    )
    .at(0)
}

/**
 * Reduces a lease's per-turn statuses to one. A unanimous status passes through; otherwise it picks the
 * most operationally significant present status in priority order (failed > cancelled > started),
 * defaulting to `mixed`. Ordered so a partial failure or an unfinished turn is never masked by a sibling
 * success.
 */
function leaseStatus(rows: AiAgentLlmTurnRow[]): ExportableGenerationLease['status'] {
  const statuses = new Set(rows.map(row => row.status))
  if (statuses.size === 1) return rows[0]?.status as ExportableGenerationLease['status']
  if (statuses.has('failed')) return 'failed'
  if (statuses.has('cancelled')) return 'cancelled'
  if (statuses.has('started')) return 'started'
  return 'mixed'
}

/**
 * Resolves a turn's stored request refs back into the actual agent messages it was built from.
 *
 * A ref is a typed pointer rather than inline content, so the same message is not duplicated across every
 * turn that used it. Four pointer kinds are understood: a persisted message by id, an inlined message
 * carried in the ref itself (for content that was never stored as a row), an assistant message rebuilt
 * from another turn's response, and a single tool result pulled out of another turn. Any ref that fails
 * to resolve (a referenced row/turn is missing) is silently dropped — a best-effort reconstruction is
 * better than failing the whole trajectory.
 */
function resolveAgentMessages(
  refs: JsonValue[],
  messagesById: Map<string, AiAgentMessageRow>,
  turnsById: Map<string, AiAgentLlmTurnRow>
): AgentMessage[] {
  return refs.flatMap(ref => {
    const object = jsonObject(ref)
    if (!object) return []

    if (object.type === 'ai_agent_message' && typeof object.id === 'string') {
      const row = messagesById.get(object.id)
      return row ? [agentMessageFromRow(row)] : []
    }

    if (object.type === 'inline_agent_message') {
      const message = object.message
      return isJsonObject(message) ? [message as unknown as AgentMessage] : []
    }

    if (object.type === 'llm_turn_response' && typeof object.llm_turn_id === 'string') {
      const turn = turnsById.get(object.llm_turn_id)
      return turn ? [assistantMessageFromTurn(turn)] : []
    }

    if (
      object.type === 'llm_turn_tool_result' &&
      typeof object.llm_turn_id === 'string' &&
      typeof object.tool_call_id === 'string'
    ) {
      const turn = turnsById.get(object.llm_turn_id)
      const toolResult = turn ? toolResultFromTurn(turn, object.tool_call_id) : undefined
      return toolResult ? [toolResult] : []
    }

    return []
  })
}

/**
 * Rebuilds an agent message from a persisted row.
 *
 * Prefers the row's stored `agentMessage` snapshot when present. When it is absent (older rows, or rows
 * that only kept a content payload) the message is reconstructed from role/kind so legacy or
 * partially-stored history still replays — summary, user/ambient, assistant, and an
 * `unresolved_tool_row` catch-all for tool rows whose original shape was not retained.
 */
function agentMessageFromRow(row: AiAgentMessageRow): AgentMessage {
  if (isJsonObject(row.agentMessage)) return row.agentMessage as unknown as AgentMessage

  if (row.kind === 'summary') {
    return createCompactionSummaryMessage(
      textFromContent(row.content),
      numberFromPath(row.metadata, ['compression', 'tokens_before']) ?? 0,
      row.createdAt.toISOString()
    )
  }

  if (row.role === 'user' || row.role === 'im_ambient') {
    return createUserMessage(textFromContent(row.content), row.createdAt.getTime())
  }

  if (row.role === 'assistant') {
    return {
      role: 'assistant',
      content: jsonArray(row.content) as any,
      stopReason: row.kind === 'error' ? 'error' : 'stop',
      timestamp: row.createdAt.getTime()
    } as AgentMessage
  }

  return {
    role: 'custom',
    customType: 'unresolved_tool_row',
    content: textFromContent(row.content),
    display: false,
    timestamp: row.createdAt.getTime()
  } as AgentMessage
}

/**
 * Rebuilds the assistant message a turn produced from its stored response. When the response did not
 * record a stop reason, one is inferred from the turn's terminal status (failed → error, cancelled →
 * aborted, otherwise a normal stop) so the replayed message still reflects how the turn ended.
 */
function assistantMessageFromTurn(turn: AiAgentLlmTurnRow): AgentMessage {
  const response = jsonObjectOrEmpty(turn.response)
  return {
    role: 'assistant',
    content: jsonArray(response.content) as any,
    stopReason:
      typeof response.stop_reason === 'string'
        ? response.stop_reason
        : turn.status === 'failed'
          ? 'error'
          : turn.status === 'cancelled'
            ? 'aborted'
            : 'stop',
    errorMessage: typeof response.error_message === 'string' ? response.error_message : undefined,
    responseId: typeof response.response_id === 'string' ? response.response_id : undefined,
    timestamp:
      typeof response.timestamp === 'number' ? response.timestamp : (turn.completedAt ?? turn.startedAt).getTime()
  } as AgentMessage
}

// Finds one tool result inside a turn by its call id. Accepts both the camelCase and snake_case key
// spellings because tool-result payloads come from different serialization paths.
function toolResultFromTurn(turn: AiAgentLlmTurnRow, toolCallId: string): AgentMessage | undefined {
  return jsonObjects(turn.toolResults).find(
    result => result.toolCallId === toolCallId || result.tool_call_id === toolCallId
  ) as AgentMessage | undefined
}

/**
 * Replays the renderer's `message_override` patches onto the resolved messages, reproducing the
 * model-view transforms (context injection, microcompact, media strip) by index. The bounds and shape
 * guards ignore any patch whose index no longer lines up — e.g. against a tree edited since the turn ran.
 */
function applyMessageOverrides(messages: AgentMessage[], patches: JsonValue[]): AgentMessage[] {
  const result = [...messages]
  for (const patch of jsonObjects(patches)) {
    if (patch.type !== 'message_override' || typeof patch.index !== 'number') continue
    if (!isJsonObject(patch.message)) continue
    if (patch.index < 0 || patch.index >= result.length) continue
    result[patch.index] = patch.message as unknown as AgentMessage
  }
  return result
}

function llmMessagesFromPatch(patch: JsonObject): Message[] {
  return jsonObjects(patch.messages) as unknown as Message[]
}

// Total order on turns: start time first, id as the tie-breaker so turns started in the same instant
// still sort deterministically (important for stable replay and lease grouping).
function compareTurns(left: AiAgentLlmTurnRow, right: AiAgentLlmTurnRow): number {
  return left.startedAt.getTime() - right.startedAt.getTime() || left.id.localeCompare(right.id)
}

function jsonArray(value: unknown): JsonValue[] {
  return Array.isArray(value) ? value : []
}

function jsonObject(value: unknown): JsonObject | undefined {
  return isJsonObject(value) ? value : undefined
}

function jsonObjectOrEmpty(value: unknown): JsonObject {
  return jsonObject(value) ?? {}
}

function jsonObjects(value: unknown): JsonObject[] {
  return Array.isArray(value) ? value.filter(isJsonObject) : []
}
