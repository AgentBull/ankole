import { jsonObject, match } from '@pleisto/active-support'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { JSONRPCMessage } from './app-server-client'
import type { SubagentDelegationStatus, SubagentTurnUsage } from '../../lanes/rpc_lane'

export type CodexNotificationProjection =
  | { type: 'stderr'; params: JSONObject }
  | { type: 'turn_started'; turnID?: string }
  | { type: 'agent_completed'; text: string }
  | { type: 'token_usage'; usage: SubagentTurnUsage }
  | { type: 'turn_diff'; filesChanged: string[] }
  | {
      type: 'turn_completed'
      codexTurnStatus: string
      terminalStatus: SubagentDelegationStatus
      error: JSONObject
    }
  | { type: 'ignored' }

export function projectCodexNotification(message: JSONRPCMessage): CodexNotificationProjection {
  const method = typeof message.method === 'string' ? message.method : ''
  const params = jsonObject(message.params)

  if (method === '$stderr') return { type: 'stderr', params }

  if (method === 'turn/started') {
    const turn = jsonObject(params.turn)
    return { type: 'turn_started', turnID: stringValue(turn.id) }
  }

  if (method === 'item/completed') {
    const item = jsonObject(params.item)
    if (item.type === 'agentMessage' && typeof item.text === 'string') {
      return { type: 'agent_completed', text: item.text }
    }
  }

  if (method === 'thread/tokenUsage/updated') {
    const usage = normalizeCodexThreadUsage(params.tokenUsage)
    return usage ? { type: 'token_usage', usage } : { type: 'ignored' }
  }

  if (method === 'turn/diff/updated' && typeof params.diff === 'string') {
    return { type: 'turn_diff', filesChanged: filesChangedFromCodexDiff(params.diff) }
  }

  if (method === 'turn/completed') {
    const turn = jsonObject(params.turn)
    const codexTurnStatus = stringValue(turn.status) ?? 'unknown'
    return {
      type: 'turn_completed',
      codexTurnStatus,
      terminalStatus: terminalStatusFromCodexTurn(codexTurnStatus),
      error: jsonObject(turn.error)
    }
  }

  return { type: 'ignored' }
}

export function textInput(text: string): Array<JSONObject> {
  return [{ type: 'text', text, text_elements: [] }]
}

export function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value : undefined
}

export function normalizeCodexThreadUsage(value: unknown): SubagentTurnUsage | undefined {
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

export function filesChangedFromCodexDiff(diff: string): string[] {
  const files = new Set<string>()
  for (const line of diff.split('\n')) {
    const match = /^(?:\+\+\+|---)\s+(?:[ab]\/)?([^\t]+)(?:\t.*)?$/.exec(line)
    const path = match?.[1]
    if (path && path !== '/dev/null') files.add(path)
  }
  return [...files].sort()
}

function usageBreakdown(value: unknown): SubagentTurnUsage['thread_total'] | undefined {
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

function terminalStatusFromCodexTurn(status: string): SubagentDelegationStatus {
  return match(status)
    .with('completed', () => 'succeeded' as const)
    .with('interrupted', () => 'stopped' as const)
    .otherwise(() => 'failed' as const)
}
