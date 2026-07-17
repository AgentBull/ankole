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
    }

export async function resolveCodexRuntimeConfig(input: {
  turn: ActorTurnRef
  job: BackgroundAgentJobResponse
  requesters: CodexRuntimeRequesters
}): Promise<CodexRuntimeConfig> {
  if (input.job.codex_account_id === 'aigateway') {
    return {
      mode: 'aigateway',
      accountID: 'aigateway',
      aiGatewayKey: await resolveAIGatewayKey(input.job.agent_uid, input.requesters),
      modelOverride: 'coding'
    }
  }

  const response = await input.requesters.rpc(rpcMethods.codexAccountResolve, {
    turn: input.turn,
    job_id: input.job.job_id
  })
  if (response.account_id !== input.job.codex_account_id) {
    throw new Error('Codex account resolve returned a different account')
  }
  return {
    mode: 'official_subscription',
    accountID: response.account_id,
    authJSON: response.auth_json,
    authHash: response.auth_hash
  }
}

async function resolveAIGatewayKey(
  agentUID: string,
  requesters: CodexRuntimeRequesters
): Promise<AIGatewayAPIKeyResponse> {
  return await requesters.requestAIGatewayAPIKey({ agent_uid: agentUID })
}
