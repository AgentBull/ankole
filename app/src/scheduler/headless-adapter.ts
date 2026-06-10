import type { ExternalGatewayOutboundAdapter } from '@/external-gateway/agent'

/**
 * Outbound-only adapter for scheduler-triggered agent runs. Declares no
 * capabilities: scheduled work has no live chat surface, so streaming cards
 * and provider-visible edits are skipped and final output flows through the
 * outbox like any other delivery.
 */
export function createHeadlessAdapter(name: string): ExternalGatewayOutboundAdapter {
  return {
    name,
    capabilities: { inbound: [], outbound: [] }
  }
}
