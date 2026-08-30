import { compareCodePointStrings } from '../../common/ordering'
import { jsonObject, match } from '@agentbull/active-support'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { sanitizeBinaryOutput, truncateUTF8Safe, utf8ByteLength } from '../../common/text-sanitize'
import type { JSONRPCMessage } from './runtime/app-server-client'
import type { BackgroundAgentJobStatus, BackgroundAgentJobTurnUsage } from '../background-agent-job-documents'
import { boundedBackgroundAgentJobPaths, type BackgroundAgentJobPathHandoff } from '../background-agent-job-handoff'
import { codexCredentialPoolExhaustion, type CodexCredentialPoolExhaustion } from './job/recovery-policy'

/** `threadID` is the notification's thread scope; the session resolves
 * lead-versus-child against its own runtime thread. */
export type CodexNotificationProjection = { threadID?: string } & (
  | { type: 'stderr' }
  | { type: 'turn_started'; turnID?: string }
  | { type: 'item_started'; item: JSONObject; turnID?: string }
  | { type: 'agent_completed'; text: string }
  | { type: 'compaction_completed'; turnID?: string }
  | { type: 'mcp_server_startup_failed'; server: string; failureReason?: string; error: string }
  | { type: 'credential_pool_exhausted'; exhaustion: CodexCredentialPoolExhaustion }
  | { type: 'token_usage'; usage: BackgroundAgentJobTurnUsage }
  | { type: 'turn_diff'; filesChanged: BackgroundAgentJobPathHandoff }
  | {
      type: 'turn_completed'
      turnID?: string
      codexTurnStatus: string
      terminalStatus: BackgroundAgentJobStatus
      error: JSONObject
    }
  | { type: 'ignored' }
)

export function projectCodexNotification(message: JSONRPCMessage): CodexNotificationProjection {
  const method = typeof message.method === 'string' ? message.method : ''
  const params = jsonObject(message.params)
  const threadID = stringValue(params.threadId)

  if (method === '$stderr') return { type: 'stderr' }

  if (method === 'turn/started') {
    const turn = jsonObject(params.turn)
    return { type: 'turn_started', threadID, turnID: stringValue(turn.id) }
  }

  if (method === 'item/started') {
    return { type: 'item_started', threadID, item: jsonObject(params.item), turnID: stringValue(params.turnId) }
  }

  if (method === 'item/completed') {
    const item = jsonObject(params.item)
    if (item.type === 'agentMessage' && typeof item.text === 'string') {
      return { type: 'agent_completed', threadID, text: item.text }
    }
    if (item.type === 'contextCompaction') {
      return { type: 'compaction_completed', threadID, turnID: stringValue(params.turnId) }
    }
  }

  if (method === 'mcpServer/startupStatus/updated' && params.status === 'failed') {
    return {
      type: 'mcp_server_startup_failed',
      threadID,
      server: stringValue(params.name) ?? 'unknown',
      failureReason: stringValue(params.failureReason),
      error: boundedMCPStartupError(stringValue(params.error) ?? 'Codex MCP server failed to start')
    }
  }

  if (method === 'error') {
    const exhaustion = codexCredentialPoolExhaustion(jsonObject(params.error))
    if (exhaustion) return { type: 'credential_pool_exhausted', threadID, exhaustion }
  }

  if (method === 'thread/tokenUsage/updated') {
    const usage = normalizeCodexThreadUsage(params.tokenUsage)
    return usage ? { type: 'token_usage', threadID, usage } : { type: 'ignored' }
  }

  if (method === 'turn/diff/updated' && typeof params.diff === 'string') {
    return { type: 'turn_diff', threadID, filesChanged: boundedFilesChangedFromCodexDiff(params.diff) }
  }

  if (method === 'turn/completed') {
    const turn = jsonObject(params.turn)
    const codexTurnStatus = stringValue(turn.status) ?? 'unknown'
    return {
      type: 'turn_completed',
      threadID,
      turnID: stringValue(turn.id),
      codexTurnStatus,
      terminalStatus: terminalStatusFromCodexTurn(codexTurnStatus),
      error: jsonObject(turn.error)
    }
  }

  return { type: 'ignored' }
}

/** Maximum MCP startup diagnostic stored in a Worker log field. */
const maxMCPStartupErrorBytes = 2_048

function boundedMCPStartupError(value: string): string {
  const sanitized = sanitizeBinaryOutput(value)
  if (utf8ByteLength(sanitized) <= maxMCPStartupErrorBytes) return sanitized
  const suffix = '...[truncated]'
  return `${truncateUTF8Safe(sanitized, maxMCPStartupErrorBytes - utf8ByteLength(suffix))}${suffix}`
}

export function textInput(text: string): Array<JSONObject> {
  return [{ type: 'text', text, text_elements: [] }]
}

export function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value : undefined
}

export function normalizedCollaborationToolName(tool: string | undefined): string {
  return match(tool)
    .with('spawnAgent', () => 'spawn_agent')
    .with('sendInput', () => 'send_message')
    .with('resumeAgent', () => 'followup_task')
    .with('wait', () => 'wait_agent')
    .with('closeAgent', () => 'interrupt_agent')
    .otherwise(() => tool ?? 'agent_interaction')
}

export function normalizeCodexThreadUsage(value: unknown): BackgroundAgentJobTurnUsage | undefined {
  const usage = jsonObject(value)
  const threadTotal = usageBreakdown(usage.total)
  const lastModelCall = usageBreakdown(usage.last)
  if (!threadTotal || !lastModelCall) return undefined
  const modelContextWindow = nonnegativeInteger(usage.modelContextWindow)
  return {
    thread_total: threadTotal,
    last_model_call: lastModelCall,
    ...(modelContextWindow !== undefined ? { model_context_window: modelContextWindow } : {})
  }
}

export function boundedFilesChangedFromCodexDiff(diff: string): BackgroundAgentJobPathHandoff {
  const handoff = boundedBackgroundAgentJobPaths(codexChangedPaths(diff))
  return { ...handoff, paths: [...handoff.paths].sort(compareCodePointStrings) }
}

function* codexChangedPaths(diff: string): Generator<string> {
  const fileHeader =
    /^---\s+(?:[ab]\/)?([^\t\r\n]+)(?:\t[^\r\n]*)?\r?\n\+\+\+\s+(?:[ab]\/)?([^\t\r\n]+)(?:\t[^\r\n]*)?\r?$/gm
  for (const match of diff.matchAll(fileHeader)) {
    const oldPath = match[1]
    const newPath = match[2]
    const path = newPath && newPath !== '/dev/null' ? newPath : oldPath
    if (path && path !== '/dev/null') yield path
  }
}

function usageBreakdown(value: unknown): BackgroundAgentJobTurnUsage['thread_total'] | undefined {
  const breakdown = jsonObject(value)
  const totalTokens = nonnegativeInteger(breakdown.totalTokens)
  const inputTokens = nonnegativeInteger(breakdown.inputTokens)
  const cachedInputTokens = nonnegativeInteger(breakdown.cachedInputTokens)
  const outputTokens = nonnegativeInteger(breakdown.outputTokens)
  const reasoningOutputTokens = nonnegativeInteger(breakdown.reasoningOutputTokens)
  if (
    totalTokens === undefined ||
    inputTokens === undefined ||
    cachedInputTokens === undefined ||
    outputTokens === undefined ||
    reasoningOutputTokens === undefined
  ) {
    return undefined
  }
  return {
    total_tokens: totalTokens,
    input_tokens: inputTokens,
    cached_input_tokens: cachedInputTokens,
    output_tokens: outputTokens,
    reasoning_output_tokens: reasoningOutputTokens
  }
}

function nonnegativeInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : undefined
}

export function approvalRequestMethod(method: string): boolean {
  return method.endsWith('/requestApproval') || method === 'execCommandApproval' || method === 'applyPatchApproval'
}

export function approvalAcceptance(method: string, params: JSONObject): JSONObject {
  return match(method)
    .with('execCommandApproval', 'applyPatchApproval', () => ({ decision: 'approved_for_session' }))
    .with('item/permissions/requestApproval', () => ({
      permissions: jsonObject(params.permissions),
      scope: 'session'
    }))
    .otherwise(() => ({ decision: 'acceptForSession' }))
}

export function userInputResponse(
  params: JSONObject,
  fallbackAnswer: string,
  suppliedAnswers?: Record<string, string | string[]>
): JSONObject {
  const questions = Array.isArray(params.questions) ? params.questions : []
  const answers: Record<string, { answers: string[] }> = {}

  for (const question of questions) {
    const questionObject = jsonObject(question)
    const id = stringValue(questionObject.id)
    if (!id) continue
    const supplied = suppliedAnswers?.[id]
    const values = match(supplied)
      .when(Array.isArray, value => value)
      .when(
        value => typeof value === 'string',
        value => [value]
      )
      .otherwise(() => [fallbackAnswer])
    answers[id] = { answers: values }
  }

  return { answers }
}

function terminalStatusFromCodexTurn(status: string): BackgroundAgentJobStatus {
  return match(status)
    .with('completed', () => 'succeeded' as const)
    .with('interrupted', () => 'stopped' as const)
    .otherwise(() => 'failed' as const)
}
