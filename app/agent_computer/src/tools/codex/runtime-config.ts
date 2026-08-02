import type { AIGatewayAPIKeyResponse } from '../../lanes/rpc_lane'
import type { AIGatewayAPIKeyRequester } from '../../core/turns/turn_options'
import type { TurnStart } from '../../lanes/actor_lane'
import type { JsonObject as JSONObject } from '@agentbull/active-support'

export const CODEX_MODEL_REASONING_EFFORTS = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'] as const

export type CodexModelReasoningEffort = (typeof CODEX_MODEL_REASONING_EFFORTS)[number]

export type CodexAIGatewayModelProfile = {
  model: string
  selector: string
  providerOptions: JSONObject
  supportsParallelToolCalls: boolean
  modelReasoningEffort?: CodexModelReasoningEffort
  contextLength?: number
}

export type CodexRuntimeConfig = {
  aiGatewayKey: AIGatewayAPIKeyResponse
  modelProfile: CodexAIGatewayModelProfile
}

export async function resolveCodexRuntimeConfig(input: {
  turnStart: TurnStart
  agentUID: string
  requestAIGatewayAPIKey: AIGatewayAPIKeyRequester
}): Promise<CodexRuntimeConfig> {
  return {
    aiGatewayKey: await input.requestAIGatewayAPIKey(input.agentUID),
    modelProfile: modelProfile(input.turnStart)
  }
}

function modelProfile(turnStart: TurnStart): CodexAIGatewayModelProfile {
  const modelRef = turnStart.model_ref
  if (!modelRef) throw new Error('Background Agent Job turn is missing its coding model_ref')
  if (modelRef.profile !== 'coding') {
    throw new Error('Background Agent Job turn did not resolve the coding model profile')
  }

  const providerID = requiredText(modelRef.provider_id, 'provider_id')
  const upstreamModel = requiredText(modelRef.model, 'model')
  const providerOptions = modelRef.provider_options ?? {}
  const effort = optionalModelReasoningEffort(providerOptions.reasoningEffort)
  const contextLength = positiveInteger(modelRef.context_length)

  return {
    model: codexModel(modelRef.provider_kind, upstreamModel),
    selector: providerID === 'ai_gateway' ? upstreamModel : `${providerID}/${upstreamModel}`,
    providerOptions,
    supportsParallelToolCalls: modelRef.supports_parallel_tool_calls === true,
    ...(effort ? { modelReasoningEffort: effort } : {}),
    ...(contextLength ? { contextLength } : {})
  }
}

function requiredText(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`Background Agent Job coding model_ref.${field} must be a non-empty string`)
  }
  return value.trim()
}

function codexModel(providerKind: string | undefined, model: string): string {
  if (providerKind !== 'openrouter') return model
  const separator = model.indexOf('/')
  return separator >= 0 && separator < model.length - 1 ? model.slice(separator + 1) : model
}

function optionalModelReasoningEffort(value: unknown): CodexModelReasoningEffort | undefined {
  return typeof value === 'string' && CODEX_MODEL_REASONING_EFFORTS.includes(value as CodexModelReasoningEffort)
    ? (value as CodexModelReasoningEffort)
    : undefined
}

function positiveInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) && value > 0 ? value : undefined
}
