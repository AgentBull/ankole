import { z } from 'zod'
import { ms } from '@pleisto/active-support'
import { toJsonObject } from '@/common/json'
import type { DrizzleExternalGatewayOutbox } from '@/external-gateway/outbox'
import { interactiveOutputCardPayload } from '@/external-gateway/interactive-output'
import { type AiAgentClarifyRegistry, aiAgentClarifyRegistry, type ClarifyResolution } from '../clarify-registry'
import type { AgentTool, AgentToolResult } from '../core'
import { buildTool } from './build-tool'
import { renderClarifyChoicePrompt } from './choice-prompt'
import { renderClarifyPrompt } from './clarify-format'

const DEFAULT_TIMEOUT_MS = ms('10m') // hermes parity
const DEFAULT_HEARTBEAT_MS = 1_000 // hermes parity: touch activity every second
const CEILING_MARGIN_MS = ms('1m')

const ClarifyParams = z.object({
  question: z.string().min(1).describe('The question to ask the user.'),
  choices: z
    .array(z.string())
    .max(4)
    .describe('Up to 4 predefined options. The user may also reply with free text.')
    .optional(),
  multiSelect: z.boolean().describe('Reserved; treated as single-select for now.').optional()
})

export interface ClarifyDetails {
  question: string
  choices: string[]
  userResponse: string
  selectedIndex: number | null
  timedOut: boolean
  cancelled: boolean
}

/** Lease keepalive surface the clarify tool needs while a run is parked. */
export interface ClarifyHeartbeatService {
  touchGenerationHeartbeat(conversationId: string, leaseId: string): Promise<boolean>
  extendGenerationCeiling(conversationId: string, leaseId: string, extraMs: number): Promise<boolean>
}

/** Per-run context captured into the clarify tool (gateway bridge + lease). */
export interface ClarifyRunBinding {
  conversationId: string
  leaseId: string
  agentUid: string
  bindingName: string
  providerRealmId?: string | null
  providerRoomId: string
  providerThreadId: string
  requesterExternalId?: string | null
  requesterPrincipalUid?: string | null
  triggerMessageId: string
  /** Whether the channel can render the interactive clarify card (else plain text). */
  cardCapable: boolean
  outbox: DrizzleExternalGatewayOutbox
  scheduleOutboxDrain: (availableAt?: Date) => void
}

export interface ClarifyToolDeps {
  conversations: ClarifyHeartbeatService
  registry?: AiAgentClarifyRegistry
  timeoutMs?: number
  heartbeatMs?: number
}

function details(
  question: string,
  choices: string[],
  userResponse: string,
  selectedIndex: number | null,
  flags: { timedOut?: boolean; cancelled?: boolean } = {}
): ClarifyDetails {
  return {
    question,
    choices,
    userResponse,
    selectedIndex,
    timedOut: flags.timedOut ?? false,
    cancelled: flags.cancelled ?? false
  }
}

/**
 * clarify tool — blocks the run inside `execute` until the user replies or the
 * wait times out (hermes parity). The reply arrives out-of-band: the runtime's
 * inbound handler resolves the registry entry, which fulfils the awaited promise.
 */
export function createClarifyTool(
  binding: ClarifyRunBinding,
  deps: ClarifyToolDeps
): AgentTool<typeof ClarifyParams, ClarifyDetails> {
  const registry = deps.registry ?? aiAgentClarifyRegistry
  const conversations = deps.conversations
  const timeoutMs = deps.timeoutMs ?? DEFAULT_TIMEOUT_MS
  const heartbeatMs = deps.heartbeatMs ?? DEFAULT_HEARTBEAT_MS

  return buildTool({
    name: 'clarify',
    label: 'Ask for clarification',
    description:
      'Ask the human a question and wait for their reply before continuing. Provide up to 4 choices, or ask open-ended.',
    schema: ClarifyParams,
    executionMode: 'sequential',
    isDestructive: false,
    async execute(toolCallId, params, signal): Promise<AgentToolResult<ClarifyDetails>> {
      const choices = (params.choices ?? [])
        .map(choice => choice.trim())
        .filter(choice => choice.length > 0)
        .slice(0, 4)

      if (signal?.aborted) {
        return {
          content: [{ type: 'text', text: 'Clarification cancelled.' }],
          details: details(params.question, choices, '', null, { cancelled: true })
        }
      }
      if (!registry.tryReserve(binding.conversationId)) {
        throw new Error('a clarification is already pending for this conversation')
      }

      let registered = false
      try {
        const outboundKey = `ai-agent-clarify:${binding.conversationId}:${toolCallId}`
        const promptText = renderClarifyPrompt(params.question, choices)
        await binding.outbox.enqueuePending({
          agentUid: binding.agentUid,
          bindingName: binding.bindingName,
          intent: {
            operation: binding.cardCapable ? 'card' : 'post',
            outboundKey,
            providerRoomId: binding.providerRoomId,
            providerThreadId: binding.providerThreadId,
            finalPayload: binding.cardCapable
              ? toJsonObject(
                  interactiveOutputCardPayload(
                    renderClarifyChoicePrompt({
                      question: params.question,
                      choices,
                      correlationId: binding.conversationId,
                      fallbackText: promptText
                    })
                  )
                )
              : { text: promptText }
          }
        })
        binding.scheduleOutboxDrain()
        // Guarantee the full wait window survives the 30-min run ceiling (best-effort).
        await conversations
          .extendGenerationCeiling(binding.conversationId, binding.leaseId, timeoutMs + CEILING_MARGIN_MS)
          .catch(() => {})

        const resolution = await new Promise<ClarifyResolution>(resolve => {
          const timeoutTimer = setTimeout(
            () => registry.resolveByConversation(binding.conversationId, { kind: 'timeout' }),
            timeoutMs
          )
          const heartbeatTimer = setInterval(() => {
            void conversations
              .touchGenerationHeartbeat(binding.conversationId, binding.leaseId)
              .then(alive => {
                if (!alive) registry.resolveByConversation(binding.conversationId, { kind: 'superseded' })
              })
              .catch(() => {})
          }, heartbeatMs)
          const onAbort = () => registry.resolveByConversation(binding.conversationId, { kind: 'aborted' })
          if (signal) signal.addEventListener('abort', onAbort, { once: true })
          registry.register({
            conversationId: binding.conversationId,
            toolCallId,
            leaseId: binding.leaseId,
            question: params.question,
            choices,
            awaitingText: true,
            askedOutboundKey: outboundKey,
            providerRoomId: binding.providerRoomId,
            providerThreadId: binding.providerThreadId,
            cardCapable: binding.cardCapable,
            resolve,
            timeoutTimer,
            heartbeatTimer,
            signal: signal ?? undefined,
            onAbort
          })
          registered = true
        })

        if (resolution.kind === 'answer') {
          const text = JSON.stringify({
            question: params.question,
            choices_offered: choices,
            user_response: resolution.text,
            selected_index: resolution.choiceIndex ?? null
          })
          return {
            content: [{ type: 'text', text }],
            details: details(params.question, choices, resolution.text, resolution.choiceIndex ?? null)
          }
        }
        if (resolution.kind === 'timeout') {
          const minutes = Math.max(1, Math.round(timeoutMs / 60_000))
          return {
            content: [{ type: 'text', text: `User did not respond within ${minutes}m.` }],
            details: details(params.question, choices, '', null, { timedOut: true })
          }
        }
        return {
          content: [{ type: 'text', text: 'Clarification cancelled.' }],
          details: details(params.question, choices, '', null, { cancelled: true })
        }
      } catch (error) {
        if (!registered) registry.releaseReservation(binding.conversationId)
        throw error
      }
    }
  })
}
