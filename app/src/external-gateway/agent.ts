import { get, isString } from '@pleisto/active-support'
import type { ExternalGatewayAgentDelivery } from './agent-events'
import type {
  ExternalGatewayAdapterCapabilities,
  ExternalGatewayBeginStreamingCardInput,
  ExternalGatewayStreamingCardHandle
} from './core/events'
import type { ExternalGatewayProjectionSink } from './core/projection'
import type { DrizzleExternalGatewayOutbox, ExternalGatewayOutboundIntent } from './outbox'
import type { AgentResult } from '@/principals/agents/service'

/**
 * The adapter surface the agent execution path actually needs: capability
 * checks, the optional live streaming card, and room-shape hints for
 * projection. Full chat adapters satisfy this structurally; outbound-only
 * contexts (the scheduler) implement just this instead of stubbing the whole
 * chat adapter contract.
 */
export interface ExternalGatewayOutboundAdapter {
  readonly name: string
  readonly userName?: string
  readonly capabilities?: ExternalGatewayAdapterCapabilities
  beginStreamingCard?(input: ExternalGatewayBeginStreamingCardInput): Promise<ExternalGatewayStreamingCardHandle>
  isDM?(threadId: string): boolean
  getChannelVisibility?(threadId: string): string
}

export interface ExternalGatewayAgentExecutionContext {
  adapter: ExternalGatewayOutboundAdapter
  agent: AgentResult
  agentUid: string
  bindingName: string
  outbox: DrizzleExternalGatewayOutbox
  projection: ExternalGatewayProjectionSink
  providerRealmId?: string | null
  scheduleOutboxDrain(availableAt?: Date): void
  /**
   * Called with the settle promise of each generation this delivery starts.
   * The gateway holds the delivery lane (per-agent parallelism quota) and the
   * pending input row until these resolve, so a crash mid-generation re-delivers.
   */
  trackSettled?(settled: Promise<void>): void
}

export interface ExternalGatewayAgentAcceptance {
  status: 'accepted'
  /**
   * Resolves when the work this delivery started (typically one generation)
   * has settled. The delivery lane — and so the per-agent parallelism quota —
   * stays occupied until then; the input row stays `pending` for crash
   * recovery. Absent when the delivery queued work for a later trigger.
   */
  settled?: Promise<void>
}

export interface ExternalGatewayAgentExecutor {
  acceptExternalGatewayDelivery(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentExecutionContext
  ): Promise<ExternalGatewayAgentAcceptance>
  recoverExternalGatewayBinding?(context: ExternalGatewayAgentExecutionContext): Promise<void>
  /**
   * True when this provider room has a pending clarify. The inbound handler uses
   * it to route a group reply (even non-@mention) to the parked clarify instead of
   * dropping it as observed/ambient. The executor (clarify registry) is the single
   * source of truth; the handler only reads.
   */
  roomHasPendingClarify?(providerRoomId: string): boolean
  stop?(): Promise<void> | void
}

/**
 * Test executor for External Gateway adapter/runtime coverage.
 *
 * Production startup defaults to `AiAgentRuntime`; this mock keeps gateway tests
 * focused on ingress batching, command parsing, lifecycle delivery, and outbox
 * dispatch without loading an LLM profile.
 */
export class MockExternalGatewayAgentExecutor implements ExternalGatewayAgentExecutor {
  async acceptExternalGatewayDelivery(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentExecutionContext
  ): Promise<ExternalGatewayAgentAcceptance> {
    const first = delivery.events[0]
    if (!first || first.deliveryMode !== 'addressed' || first.type !== 'message.received') return { status: 'accepted' }

    const text = delivery.events
      .map(event => messageTextFromPayload(event.payload))
      .filter((value): value is string => value !== undefined && value.length > 0)
      .join('\n')

    const intent: ExternalGatewayOutboundIntent = {
      operation: 'post',
      outboundKey: `mock-agent-final:${delivery.events.map(event => event.providerEventId).join('|')}`,
      providerRoomId: first.providerRoomId,
      providerThreadId: first.providerThreadId,
      finalPayload: {
        text: `[BullX Agent External Gateway mock:${context.agentUid}]\n\n${text}`
      }
    }
    await context.outbox.enqueuePending({
      agentUid: context.agentUid,
      bindingName: context.bindingName,
      intent
    })
    return { status: 'accepted' }
  }
}

export const mockExternalGatewayAgentExecutor = new MockExternalGatewayAgentExecutor()

function messageTextFromPayload(payload: unknown): string | undefined {
  const text = get(payload, 'data.message.text')
  return isString(text) ? text : undefined
}
