import {
  assertRpcResponse,
  type AIGatewayApiKeyResponse,
  type CodexAccountResolveResponse,
  type SubagentDelegationResponse
} from '../../lanes/rpc_lane'
import type { AIGatewayApiKeyRequester, CodexAccountResolveRequester } from '../../core/turns/turn_options'
import type { ActorTurnRef } from '../../lanes/actor_lane'

type CodexRuntimeRequesters = {
  requestAIGatewayApiKey: AIGatewayApiKeyRequester
  resolveCodexAccount?: CodexAccountResolveRequester
}

export type CodexRuntimeConfig =
  | {
      mode: 'aigateway'
      accountId: 'aigateway'
      aiGatewayKey: AIGatewayApiKeyResponse
      modelOverride: 'coding'
    }
  | {
      mode: 'official_subscription'
      accountId: string
      authJson: string
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
      accountId: 'aigateway',
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
  assertRpcResponse<CodexAccountResolveResponse>(response, 'Codex account resolve rejected')
  if (response.account_id !== input.delegation.codex_account_id) {
    throw new Error('Codex account resolve returned a different account')
  }
  return {
    mode: 'official_subscription',
    accountId: response.account_id,
    authJson: response.auth_json,
    authHash: response.auth_hash
  }
}

async function resolveAIGatewayKey(
  agentUid: string,
  requesters: CodexRuntimeRequesters
): Promise<AIGatewayApiKeyResponse> {
  const response = await requesters.requestAIGatewayApiKey({
    request_id: `codex-ai-gateway-key-${crypto.randomUUID()}`,
    agent_uid: agentUid
  })
  assertRpcResponse<AIGatewayApiKeyResponse>(response, 'AIGateway API key rejected for Codex')
  return response
}
