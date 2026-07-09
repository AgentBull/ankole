import { assertRpcResponse, type AIGatewayApiKeyResponse, type AppConfigureResolveResponse } from '../../lanes/rpc_lane'
import { CodexConfigOverrideKey, parseCodexConfigOverride, type CodexConfigOverride } from './config'
import type { AIGatewayApiKeyRequester, AppConfigureRequester } from '../../core/turns/turn_options'

type CodexRuntimeRequesters = {
  requestAIGatewayApiKey: AIGatewayApiKeyRequester
  requestAppConfigure?: AppConfigureRequester
}

export type CodexRuntimeConfig = {
  override: CodexConfigOverride | null
  aiGatewayKey?: AIGatewayApiKeyResponse
  modelOverride?: 'coding'
}

export async function resolveCodexRuntimeConfig(input: {
  agentUid: string
  requesters: CodexRuntimeRequesters
}): Promise<CodexRuntimeConfig> {
  const override = await resolveConfigOverride(input)
  const aiGatewayKey = override?.mode === 'official_subscription' ? undefined : await resolveAIGatewayKey(input)
  const modelOverride = override?.mode === 'official_subscription' ? undefined : 'coding'
  return { override, aiGatewayKey, modelOverride }
}

async function resolveConfigOverride(input: {
  agentUid: string
  requesters: CodexRuntimeRequesters
}): Promise<CodexConfigOverride | null> {
  const requester = input.requesters.requestAppConfigure
  if (!requester) return null

  const response = await requester({
    request_id: `app-configure-codex-${crypto.randomUUID()}`,
    agent_uid: input.agentUid,
    keys: [CodexConfigOverrideKey]
  })
  assertRpcResponse<AppConfigureResolveResponse>(response, 'Codex config override rejected')

  return parseCodexConfigOverride(response.values[CodexConfigOverrideKey]?.value)
}

async function resolveAIGatewayKey(input: {
  agentUid: string
  requesters: CodexRuntimeRequesters
}): Promise<AIGatewayApiKeyResponse> {
  const response = await input.requesters.requestAIGatewayApiKey({
    request_id: `codex-ai-gateway-key-${crypto.randomUUID()}`,
    agent_uid: input.agentUid
  })
  assertRpcResponse<AIGatewayApiKeyResponse>(response, 'AIGateway API key rejected for Codex')
  return response
}
