import {
  rpcMethods,
  type AIGatewayAPIKeyResponse,
  type BackgroundAgentJobResponse,
  type RPCRequester
} from '../../lanes/rpc_lane'
import { jsonObjectFromBytes } from '../../fabric/envelope_proto'
import type { AIGatewayAPIKeyRequester } from '../../core/turns/turn_options'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import type { JsonObject as JSONObject } from '@pleisto/active-support'

type CodexRuntimeRequesters = {
  requestAIGatewayAPIKey: AIGatewayAPIKeyRequester
  rpc: RPCRequester
}

export const CODEX_MODEL_REASONING_EFFORTS = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'] as const

export type CodexModelReasoningEffort = (typeof CODEX_MODEL_REASONING_EFFORTS)[number]

export type CodexSubscriptionModelProfile = {
  model: string
  modelReasoningEffort: CodexModelReasoningEffort
  fastMode: boolean
}

export type CodexAIGatewayModelProfile = {
  model: string
  selector: string
  providerOptions: JSONObject
  supportsParallelToolCalls: boolean
  modelReasoningEffort?: CodexModelReasoningEffort
}

export type CodexRuntimeConfig =
  | {
      mode: 'aigateway'
      accountID: 'aigateway'
      aiGatewayKey: AIGatewayAPIKeyResponse
      modelProfile: CodexAIGatewayModelProfile
    }
  | {
      mode: 'official_subscription'
      accountID: string
      authJSON: string
      authHash: string
      modelProfile: CodexSubscriptionModelProfile
    }

export async function resolveCodexRuntimeConfig(input: {
  turn: ActorTurnRef
  job: BackgroundAgentJobResponse
  requesters: CodexRuntimeRequesters
}): Promise<CodexRuntimeConfig> {
  if (input.job.codexAccountId === 'aigateway') {
    return {
      mode: 'aigateway',
      accountID: 'aigateway',
      aiGatewayKey: await resolveAIGatewayKey(input.job.agentUid, input.requesters),
      modelProfile: aigatewayModelProfile(input.job)
    }
  }

  const response = await input.requesters.rpc(
    rpcMethods.codexAccountResolve,
    { jobId: input.job.jobId },
    { turn: input.turn }
  )
  if (response.accountId !== input.job.codexAccountId) {
    throw new Error('Codex account resolve returned a different account')
  }
  return {
    mode: 'official_subscription',
    accountID: response.accountId,
    authJSON: response.authJson,
    authHash: response.authHash,
    modelProfile: {
      model: requiredModel(response.model),
      modelReasoningEffort: modelReasoningEffort(response.modelReasoningEffort),
      fastMode: response.fastMode
    }
  }
}

function requiredModel(value: string): string {
  const model = value.trim()
  if (!model) throw new Error('Codex account resolve returned an empty model')
  return model
}

function aigatewayModelProfile(job: BackgroundAgentJobResponse): CodexAIGatewayModelProfile {
  const metadata = jsonObjectFromBytes(job.metadataJson, 'background_agent_job.metadata_json') ?? {}
  const snapshot = jsonObject(metadata.codex_aigateway, 'background_agent_job.metadata.codex_aigateway')
  const providerOptions = jsonObject(
    snapshot.provider_options,
    'background_agent_job.metadata.codex_aigateway.provider_options'
  )
  const effort = optionalModelReasoningEffort(providerOptions.reasoningEffort)

  return {
    model: requiredSnapshotText(snapshot.model, 'model'),
    selector: requiredSnapshotText(snapshot.selector, 'selector'),
    providerOptions,
    supportsParallelToolCalls: requiredSnapshotBoolean(
      snapshot.supports_parallel_tool_calls,
      'supports_parallel_tool_calls'
    ),
    ...(effort ? { modelReasoningEffort: effort } : {})
  }
}

function jsonObject(value: unknown, field: string): JSONObject {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${field} must be a JSON object`)
  }
  return value as JSONObject
}

function requiredSnapshotText(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`background_agent_job.metadata.codex_aigateway.${field} must be a non-empty string`)
  }
  return value.trim()
}

function requiredSnapshotBoolean(value: unknown, field: string): boolean {
  if (typeof value !== 'boolean') {
    throw new Error(`background_agent_job.metadata.codex_aigateway.${field} must be a boolean`)
  }
  return value
}

function modelReasoningEffort(value: string): CodexModelReasoningEffort {
  if (CODEX_MODEL_REASONING_EFFORTS.includes(value as CodexModelReasoningEffort)) {
    return value as CodexModelReasoningEffort
  }
  throw new Error(`Codex account resolve returned an invalid model reasoning effort: ${value}`)
}

function optionalModelReasoningEffort(value: unknown): CodexModelReasoningEffort | undefined {
  return typeof value === 'string' && CODEX_MODEL_REASONING_EFFORTS.includes(value as CodexModelReasoningEffort)
    ? (value as CodexModelReasoningEffort)
    : undefined
}

async function resolveAIGatewayKey(
  agentUID: string,
  requesters: CodexRuntimeRequesters
): Promise<AIGatewayAPIKeyResponse> {
  return await requesters.requestAIGatewayAPIKey(agentUID)
}
