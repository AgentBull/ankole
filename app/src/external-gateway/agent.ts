import type { ExternalGatewayAgentDelivery } from './agent-events'
import type { ExternalGatewayOutboundIntent } from './outbox'

export interface ExternalGatewayAgentContext {
  agentUid: string
  bindingName: string
}

export interface ExternalGatewayAgentHandler {
  handleExternalGatewayEvents(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentContext
  ): Promise<readonly ExternalGatewayOutboundIntent[]>
}

/**
 * Temporary agent boundary used until the real LLM loop exists.
 *
 * It proves that External Gateway can deliver addressed batches to an agent and
 * consume an optional final outbound intent. Ambient and lifecycle events are
 * delivered but do not produce a visible reply in this mock.
 */
export class MockExternalGatewayAgentHandler implements ExternalGatewayAgentHandler {
  async handleExternalGatewayEvents(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentContext
  ): Promise<readonly ExternalGatewayOutboundIntent[]> {
    const first = delivery.events[0]
    if (!first || first.deliveryMode !== 'addressed' || first.type !== 'message.received') return []

    const text = delivery.events
      .map(event => messageTextFromPayload(event.payload))
      .filter((value): value is string => value !== undefined && value.length > 0)
      .join('\n')

    return [
      {
        operation: 'post',
        outboundKey: `mock-agent-final:${delivery.events.map(event => event.providerEventId).join('|')}`,
        providerRoomId: first.providerRoomId,
        providerThreadId: first.providerThreadId,
        finalPayload: {
          text: `[BullX Agent External Gateway mock:${context.agentUid}]\n\n${text}`
        }
      }
    ]
  }
}

export const mockExternalGatewayAgentHandler = new MockExternalGatewayAgentHandler()

function messageTextFromPayload(payload: unknown): string | undefined {
  if (typeof payload !== 'object' || payload === null) return undefined
  const data = (payload as { data?: unknown }).data
  if (typeof data !== 'object' || data === null) return undefined
  const message = (data as { message?: unknown }).message
  if (typeof message !== 'object' || message === null) return undefined
  const text = (message as { text?: unknown }).text
  return typeof text === 'string' ? text : undefined
}
