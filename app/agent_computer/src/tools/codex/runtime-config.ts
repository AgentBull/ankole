import {
  assertRPCResponse,
  type AIGatewayAPIKeyResponse,
  type CodexAccountResolveResponse,
  type SubagentDelegationResponse
} from '../../lanes/rpc_lane'
import type { AIGatewayAPIKeyRequester, CodexAccountResolveRequester } from '../../core/turns/turn_options'
import type { ActorTurnRef } from '../../lanes/actor_lane'

type CodexRuntimeRequesters = {
  requestAIGatewayAPIKey: AIGatewayAPIKeyRequester
  resolveCodexAccount?: CodexAccountResolveRequester
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
  delegation: SubagentDelegationResponse
  requesters: CodexRuntimeRequesters
}): Promise<CodexRuntimeConfig> {
  if (input.delegation.codex_account_id === 'aigateway') {
    return {
      mode: 'aigateway',
      accountID: 'aigateway',
      aiGatewayKey: await resolveAIGatewayKey(input.delegation.agent_uid, input.requesters),
      modelOverride: 'coding'
    }
  }

  const requester = input.requesters.resolveCodexAccount
  if (!requester) throw new Error('Codex account resolve RPC is not configured')
  const response = await requester({
    request_id: `codex-account-resolve-${crypto.randomUUID()}`,
    turn: input.turn,
    delegation_id: input.delegation.delegation_id
  })
  assertRPCResponse<CodexAccountResolveResponse>(response, 'Codex account resolve rejected')
  if (response.account_id !== input.delegation.codex_account_id) {
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
  const response = await requesters.requestAIGatewayAPIKey({
    request_id: `codex-ai-gateway-key-${crypto.randomUUID()}`,
    agent_uid: agentUID
  })
  assertRPCResponse<AIGatewayAPIKeyResponse>(response, 'AIGateway API key rejected for Codex')
  return response
}
