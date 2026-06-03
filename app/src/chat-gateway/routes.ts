import { Elysia } from 'elysia'
import { rootContainer } from '@/common/di'
import type { ChatGatewayRuntime } from './runtime'
import { ChatGatewayRuntime as ChatGatewayRuntimeToken } from './runtime'

/**
 * Public Chat Gateway webhook surface.
 *
 * Elysia uses `agentUid` as the param name because hyphenated param identifiers
 * are awkward in TypeScript. The route still represents the product-level
 * `/api/agents/:agent-uid/webhooks/:channel` shape: external webhooks identify
 * both the agent instance and the channel bound in that agent's metadata.
 */
export function chatGatewayRoutes(runtime: ChatGatewayRuntime = rootContainer.resolve(ChatGatewayRuntimeToken)) {
  return new Elysia({ name: 'chat-gateway-routes' }).post(
    '/api/agents/:agentUid/webhooks/:channel',
    ({ params, request }) => runtime.handleWebhook(params.agentUid, params.channel, request)
  )
}
