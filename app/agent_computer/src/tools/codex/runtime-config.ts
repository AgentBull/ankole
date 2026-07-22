import {
  rpcMethods,
  type AIGatewayAPIKeyResponse,
  type BackgroundAgentJobResponse,
  type RPCRequester
} from '../../lanes/rpc_lane'
import type { AIGatewayAPIKeyRequester } from '../../core/turns/turn_options'
import type { ActorTurnRef } from '../../lanes/actor_lane'

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

export type CodexRuntimeConfig =
  | {
      mode: 'aigateway'
      accountID: 'aigateway'
      aiGatewayKey: AIGatewayAPIKeyResponse
      modelOverride: 'coding'
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
      modelOverride: 'coding'
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

function modelReasoningEffort(value: string): CodexModelReasoningEffort {
  if (CODEX_MODEL_REASONING_EFFORTS.includes(value as CodexModelReasoningEffort)) {
    return value as CodexModelReasoningEffort
  }
  throw new Error(`Codex account resolve returned an invalid model reasoning effort: ${value}`)
}

async function resolveAIGatewayKey(
  agentUID: string,
  requesters: CodexRuntimeRequesters
): Promise<AIGatewayAPIKeyResponse> {
  return await requesters.requestAIGatewayAPIKey(agentUID)
}
