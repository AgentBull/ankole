import { HostedTool } from '../../fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { positiveInteger } from '../../common/numbers'
import type { AIGatewayAPIKeyResponse } from '../../lanes/rpc_lane'
import type { AIGatewayAPIKeyRequester } from './options'
import type { TurnStart } from '../../lanes/session_lane'
import { type JsonObject as JSONObject } from '@agentbull/active-support'

/** Reasoning effort values accepted from the frozen model projection. */
export const CODEX_MODEL_REASONING_EFFORTS = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
  'ultra'
] as const

export type CodexModelReasoningEffort = (typeof CODEX_MODEL_REASONING_EFFORTS)[number]

export type CodexAIGatewayModelProfile = {
  model: string
  selector: string
  providerOptions: JSONObject
  supportsParallelToolCalls: boolean
  inputModalities: string[]
  visionFallback?: CodexAIGatewayModelTarget
  modelReasoningEffort?: CodexModelReasoningEffort
  contextLength?: number
}

export type CodexAIGatewayModelTarget = {
  selector: string
  providerOptions: JSONObject
  inputModalities: string[]
}

export type CodexRuntimeConfig = {
  aiGatewayKey: AIGatewayAPIKeyResponse
  modelProfile: CodexAIGatewayModelProfile
  /** The hosted Brain declaration AIGateway adds to the Job's requests, when memory is on. */
  brain?: { operations: Array<'recall' | 'get_page'>; signalID: string }
}

export async function resolveCodexRuntimeConfig(input: {
  turnStart: TurnStart
  requestAIGatewayAPIKey: AIGatewayAPIKeyRequester
}): Promise<CodexRuntimeConfig> {
  const brainDeclared = (input.turnStart.hosted_tools ?? []).includes(HostedTool.BRAIN)
  return {
    aiGatewayKey: await input.requestAIGatewayAPIKey(),
    modelProfile: codexJobModelProfile(input.turnStart),
    // codex composes its own Responses requests, so the frozen binding carries
    // the read-only subset and the Signal that scopes its memory.
    ...(brainDeclared
      ? { brain: { operations: ['recall', 'get_page'], signalID: input.turnStart.turn.signal_id } }
      : {})
  }
}

/** The real Codex model and effort that the frozen `model_ref` binds for this Job turn. */
export function codexJobModelProfile(turnStart: TurnStart): CodexAIGatewayModelProfile {
  const modelRef = turnStart.model_ref
  if (!modelRef) throw new Error('Background Agent Job turn is missing its model_ref')

  const providerID = requiredText(modelRef.provider_id, 'provider_id')
  const upstreamModel = requiredText(modelRef.model, 'model')
  const providerOptions = modelRef.provider_options ?? {}
  const effort = optionalModelReasoningEffort(providerOptions.reasoningEffort)
  const contextLength = positiveInteger(modelRef.context_length)
  const inputModalities = modelInputModalities(modelRef.input_modalities)
  const visionFallback = visionFallbackTarget(modelRef.vision_fallback_model_ref)

  return {
    model: codexModel(modelRef.provider_kind, upstreamModel),
    selector: providerID === 'ai_gateway' ? upstreamModel : `${providerID}/${upstreamModel}`,
    providerOptions,
    supportsParallelToolCalls: modelRef.supports_parallel_tool_calls === true,
    inputModalities,
    ...(visionFallback ? { visionFallback } : {}),
    ...(effort ? { modelReasoningEffort: effort } : {}),
    ...(contextLength ? { contextLength } : {})
  }
}

function visionFallbackTarget(modelRef: TurnStart['model_ref']): CodexAIGatewayModelTarget | undefined {
  if (!modelRef) return undefined

  const inputModalities = modelInputModalities(modelRef.input_modalities)
  if (!inputModalities.includes('image')) return undefined

  const providerID = requiredText(modelRef.provider_id, 'vision_fallback_model_ref.provider_id')
  const model = requiredText(modelRef.model, 'vision_fallback_model_ref.model')

  return {
    selector: providerID === 'ai_gateway' ? model : `${providerID}/${model}`,
    providerOptions: modelRef.provider_options ?? {},
    inputModalities
  }
}

function requiredText(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`Background Agent Job model_ref.${field} must be a non-empty string`)
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

function modelInputModalities(value: unknown): string[] {
  if (!Array.isArray(value)) return ['text']
  const modalities = [...new Set(value.filter((item): item is string => typeof item === 'string' && item.length > 0))]
  return modalities.includes('text') ? modalities : ['text', ...modalities]
}
