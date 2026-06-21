import { get, isString } from '@pleisto/active-support'
import type { ExternalGatewayAgentDelivery } from './agent-events'
import type {
  ExternalGatewayAdapterCapabilities,
  ExternalGatewayBeginStreamingCardInput,
  ExternalGatewayReasoningTraceViewAuthInput,
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
  authorizeReasoningTraceView?(input: ExternalGatewayReasoningTraceViewAuthInput): boolean | Promise<boolean>
  beginStreamingCard?(input: ExternalGatewayBeginStreamingCardInput): Promise<ExternalGatewayStreamingCardHandle>
  isDM?(threadId: string): boolean
  getChannelVisibility?(threadId: string): string
}

/**
 * Everything an executor needs to handle one claimed delivery: the outbound
 * adapter, the agent and its identity, the outbox for provider-visible effects,
 * the projection sink, and the hooks the gateway uses to keep the delivery lane
 * occupied until the work settles.
 */
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

/**
 * The executor's reply to a delivery. Acceptance is unconditional in V1 — the
 * input row was already durably accepted at enqueue — so the only variable part
 * is the optional `settled` promise that tells the lane how long to stay busy.
 */
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

/**
 * The contract the gateway runtime drives to turn delivered input into agent
 * work. The default production implementation is `AiAgentRuntime`; gateway tests
 * use the mock below. The runtime owns claiming, lane scheduling, and outbox
 * draining around this interface, so an executor only has to accept a delivery.
 */
export interface ExternalGatewayAgentExecutor {
  /**
   * Handles one claimed delivery — typically by feeding it into a generation
   * and enqueuing the agent's output as outbox intents. The returned
   * `settled` promise (when present) keeps the delivery lane and the pending
   * input row occupied until the generation finishes, which is what makes a
   * crash mid-generation re-deliver instead of being lost.
   */
  acceptExternalGatewayDelivery(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentExecutionContext
  ): Promise<ExternalGatewayAgentAcceptance>
  /**
   * Optional per-binding recovery run once at startup, before ingress resumes,
   * so an interrupted generation or undrained output can be picked back up.
   */
  recoverExternalGatewayBinding?(context: ExternalGatewayAgentExecutionContext): Promise<void>
  /**
   * True when this provider room has a pending clarify question. The inbound
   * handler uses it to route a group reply (even non-@mention) in as the answer
   * instead of dropping it as observed/ambient. The executor (clarify registry)
   * is the single source of truth; the handler only reads.
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
  /**
   * Echoes the batch's joined text back through the outbox so tests can assert
   * end-to-end ingress→outbox flow. Only addressed receives produce output;
   * other delivery kinds are accepted and ignored. The `outboundKey` is derived
   * from the event ids, so re-delivering the same batch upserts the same outbox
   * row instead of double-posting.
   */
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

/** Safely reads `data.message.text` out of an envelope payload of unknown shape. */
function messageTextFromPayload(payload: unknown): string | undefined {
  const text = get(payload, 'data.message.text')
  return isString(text) ? text : undefined
}
