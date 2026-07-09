import { jsonObject, match } from '@pleisto/active-support'
import type { JsonObject } from '@pleisto/active-support'
import type { JsonRpcMessage } from './app-server-client'
import type { SubagentDelegationStatus } from '../../lanes/rpc_lane'

export type CodexNotificationProjection =
  | { type: 'stderr'; params: JsonObject }
  | { type: 'turn_started'; turnId?: string }
  | { type: 'agent_delta'; delta: string }
  | { type: 'token_usage'; usage: JsonObject }
  | { type: 'turn_diff'; diff: string }
  | {
      type: 'turn_completed'
      codexTurnStatus: string
      terminalStatus: SubagentDelegationStatus
      error: JsonObject
    }
  | { type: 'ignored' }

export function projectCodexNotification(message: JsonRpcMessage): CodexNotificationProjection {
  const method = typeof message.method === 'string' ? message.method : ''
  const params = jsonObject(message.params)

  if (method === '$stderr') return { type: 'stderr', params }

  if (method === 'turn/started') {
    const turn = jsonObject(params.turn)
    return { type: 'turn_started', turnId: stringValue(turn.id) }
  }

  if (method === 'item/agentMessage/delta' && typeof params.delta === 'string') {
    return { type: 'agent_delta', delta: params.delta }
  }

  if (method === 'thread/tokenUsage/updated') {
    return { type: 'token_usage', usage: jsonObject(params.tokenUsage) }
  }

  if (method === 'turn/diff/updated' && typeof params.diff === 'string') {
    return { type: 'turn_diff', diff: params.diff }
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

export function textInput(text: string): Array<JsonObject> {
  return [{ type: 'text', text, text_elements: [] }]
}

export function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value : undefined
}

export function approvalRequestMethod(method: string): boolean {
  return method.endsWith('/requestApproval') || method === 'execCommandApproval' || method === 'applyPatchApproval'
}

export function approvalRejection(method: string): JsonObject {
  return match(method)
    .with('execCommandApproval', 'applyPatchApproval', () => ({ decision: 'denied' }))
    .otherwise(() => ({ decision: 'decline' }))
}

export function userInputResponse(
  params: JsonObject,
  fallbackAnswer: string,
  suppliedAnswers?: Record<string, string | string[]>
): JsonObject {
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
