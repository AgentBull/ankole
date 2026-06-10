// Trajectory replay is a README-pillar capability. The rebuild functions below
// currently have test-only consumers; runtime wiring arrives with the replay
// surface, so do not treat them as dead code.
import { eq } from 'drizzle-orm'
import type { Message } from '@earendil-works/pi-ai'
import { DB } from '@/common/database'
import { AiAgentLlmTurns, AiAgentMessages, type JsonObject, type JsonValue } from '@/common/db-schema'
import { isJsonObject, numberFromPath, stringFromPath } from '@/common/json'
import { convertToLlm, createCompactionSummaryMessage, createUserMessage, type AgentMessage } from './core'
import { textFromContent } from './conversation-service'

export type AiAgentLlmTurnRow = typeof AiAgentLlmTurns.$inferSelect
export type AiAgentMessageRow = typeof AiAgentMessages.$inferSelect

export interface ReconstructedLlmTurnRequest {
  agentMessages: AgentMessage[]
  exactLlmRequest: boolean
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

export interface ExportableGenerationLease {
  callCount: number
  completedAt: Date | null
  conversationId: string
  kind: string
  leaseId: string
  startedAt: Date
  status: 'succeeded' | 'failed' | 'cancelled' | 'started' | 'mixed'
  triggerMessageId: string
  turnIds: string[]
}

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

export function reconstructLlmTurnTrajectory(input: {
  messages: AiAgentMessageRow[]
  turns: AiAgentLlmTurnRow[]
}): ReconstructedLlmTurn[] {
  const messagesById = new Map(input.messages.map(row => [row.id, row] as const))
  const turnsById = new Map(input.turns.map(row => [row.id, row] as const))
  const sortedTurns = [...input.turns].sort(compareTurns)
  let tools: JsonValue[] = []

  return sortedTurns.map(turn => {
    const patches = jsonArray(turn.requestPatches)
    for (const patch of jsonObjects(patches)) {
      if (patch.type === 'llm_tool_definitions') tools = jsonArray(patch.tools)
    }

    const exactRequest = [...jsonObjects(patches)].reverse().find(patch => patch.type === 'llm_request')
    const requestContext = jsonObjectOrEmpty(turn.requestContext)
    const systemPrompt =
      stringFromPath(exactRequest ?? {}, ['system_prompt']) ?? stringFromPath(requestContext, ['system_prompt']) ?? null
    const refs = jsonArray(turn.requestRefs)
    const agentMessages = resolveAgentMessages(refs, messagesById, turnsById)
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

export function selectExportableGenerationLeases(
  turns: AiAgentLlmTurnRow[],
  messages: AiAgentMessageRow[] = []
): ExportableGenerationLease[] {
  const hasTranscript = messages.length > 0
  const visibleAssistantTurnIds = new Set(
    messages.flatMap(row => {
      if (row.role !== 'assistant') return []
      if (row.metadata.transcript_effect) return []
      const llmTurnId = row.metadata.llm_turn_id
      return typeof llmTurnId === 'string' && llmTurnId.length > 0 ? [llmTurnId] : []
    })
  )
  const groups = new Map<string, AiAgentLlmTurnRow[]>()

  for (const turn of turns) {
    if (!isGenerationExportTurn(turn)) continue
    if (!turn.leaseId || turn.callIndex === null || !turn.triggerMessageId) continue
    const key = `${turn.conversationId}:${turn.triggerMessageId}`
    const bucket = groups.get(key) ?? []
    bucket.push(turn)
    groups.set(key, bucket)
  }

  return [...groups.values()]
    .flatMap(group => {
      const leases = groupLeases(group)
      const committed = leases.filter(lease => lease.turnIds.some(id => visibleAssistantTurnIds.has(id)))
      const candidates = hasTranscript ? committed : leases.filter(lease => lease.status === 'succeeded')
      const selected = latestLease(candidates)
      return selected ? [selected] : []
    })
    .sort(
      (left, right) => left.startedAt.getTime() - right.startedAt.getTime() || left.leaseId.localeCompare(right.leaseId)
    )
}

function isGenerationExportTurn(turn: AiAgentLlmTurnRow): boolean {
  return (
    turn.profile === 'primary' &&
    (turn.kind === 'generation' || turn.kind === 'retry_generation' || turn.kind === 'overflow_retry')
  )
}

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

function latestLease(leases: ExportableGenerationLease[]): ExportableGenerationLease | undefined {
  return leases
    .slice()
    .sort(
      (left, right) => right.startedAt.getTime() - left.startedAt.getTime() || right.leaseId.localeCompare(left.leaseId)
    )
    .at(0)
}

function leaseStatus(rows: AiAgentLlmTurnRow[]): ExportableGenerationLease['status'] {
  const statuses = new Set(rows.map(row => row.status))
  if (statuses.size === 1) return rows[0]?.status as ExportableGenerationLease['status']
  if (statuses.has('failed')) return 'failed'
  if (statuses.has('cancelled')) return 'cancelled'
  if (statuses.has('started')) return 'started'
  return 'mixed'
}

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

function toolResultFromTurn(turn: AiAgentLlmTurnRow, toolCallId: string): AgentMessage | undefined {
  return jsonObjects(turn.toolResults).find(
    result => result.toolCallId === toolCallId || result.tool_call_id === toolCallId
  ) as AgentMessage | undefined
}

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
