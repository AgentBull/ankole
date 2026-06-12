import { z } from 'zod'
import { ms } from '@pleisto/active-support'
import { toJsonObject } from '@/common/json'
import type { DrizzleExternalGatewayOutbox } from '@/external-gateway/outbox'
import { interactiveOutputCardPayload } from '@/external-gateway/interactive-output'
import { type AiAgentClarifyRegistry, aiAgentClarifyRegistry } from '../clarify-registry'
import type { AgentTool, AgentToolResult } from '../core'
import { buildTool } from './build-tool'
import { renderClarifyChoicePrompt } from './choice-prompt'
import { renderClarifyPrompt } from './clarify-format'

/** How long the answer niceties (card lock, group reply gate) stay armed. */
const DEFAULT_GATE_TTL_MS = ms('10m')

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
  asked: boolean
}

/** Per-run context captured into run-bound tools (gateway bridge + lease). */
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
  registry?: AiAgentClarifyRegistry
  /** Gate TTL: how long an unanswered question keeps its card/group-gate niceties. */
  timeoutMs?: number
}

/**
 * clarify tool — posts the question and ends the IM turn. A turn is one
 * question/answer exchange: the ask is this turn's outbound, the user's reply
 * is the next turn's inbound (a normal message, or a card click the runtime
 * materializes as one). Nothing parks in-process; the registry entry only arms
 * the answer niceties (card lock, group non-@mention reply gate).
 */
export function createClarifyTool(
  binding: ClarifyRunBinding,
  deps: ClarifyToolDeps = {}
): AgentTool<typeof ClarifyParams, ClarifyDetails> {
  const registry = deps.registry ?? aiAgentClarifyRegistry
  const gateTtlMs = deps.timeoutMs ?? DEFAULT_GATE_TTL_MS

  return buildTool({
    name: 'clarify',
    label: 'Ask for clarification',
    description:
      'Ask the user a question when you need clarification, feedback, or a ' +
      'decision before proceeding. Supports two modes:\n\n' +
      '1. **Multiple choice** — provide up to 4 choices. The user picks one ' +
      "or types their own answer via a 5th 'Other' option.\n" +
      '2. **Open-ended** — omit choices entirely. The user types a free-form ' +
      'response.\n\n' +
      'Calling this tool ends your current turn: the question is delivered and ' +
      "the user's reply arrives as the next user message, starting your next " +
      'turn. Do not call other tools or keep working after asking.\n\n' +
      'Use this tool when:\n' +
      '- The task is ambiguous and you need the user to choose an approach\n' +
      "- You want post-task feedback ('How did that work out?')\n" +
      '- A decision has meaningful trade-offs the user should weigh in on\n\n' +
      'Do NOT use this tool for simple yes/no confirmation of dangerous ' +
      'commands. Prefer making a reasonable default choice yourself when the decision is low-stakes.',
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
          details: { question: params.question, choices, asked: false }
        }
      }

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
      registry.set(
        {
          conversationId: binding.conversationId,
          toolCallId,
          question: params.question,
          choices,
          askedOutboundKey: outboundKey,
          providerRoomId: binding.providerRoomId,
          providerThreadId: binding.providerThreadId,
          cardCapable: binding.cardCapable
        },
        gateTtlMs
      )

      const text = JSON.stringify({
        question: params.question,
        choices_offered: choices,
        status: 'asked',
        note:
          'Question delivered to the user. This turn ends here — the reply ' +
          'will arrive as the next user message and starts your next turn.'
      })
      return {
        content: [{ type: 'text', text }],
        details: { question: params.question, choices, asked: true }
      }
    }
  })
}
