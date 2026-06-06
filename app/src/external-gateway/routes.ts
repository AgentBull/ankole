import { Elysia } from 'elysia'
import { rootContainer } from '@/common/di'
import type { ExternalGatewayRuntime } from './runtime'
import { ExternalGatewayRuntime as ExternalGatewayRuntimeToken } from './runtime'

/**
 * Public External Gateway webhook surface.
 *
 * Elysia uses `agentUid` as the param name because hyphenated param identifiers
 * are awkward in TypeScript. The route still represents the product-level
 * `/api/agents/:agent-uid/webhooks/:channel` shape: external webhooks identify
 * both the agent instance and the channel bound in that agent's metadata.
 */
export function externalGatewayRoutes(
  runtime: ExternalGatewayRuntime = rootContainer.resolve(ExternalGatewayRuntimeToken)
) {
  return new Elysia({ name: 'external-gateway-routes' }).post(
    '/api/agents/:agentUid/webhooks/:channel',
    ({ params, request }) => runtime.handleWebhook(params.agentUid, params.channel, request)
  )
}
