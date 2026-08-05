import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { jsonToolResult } from '../../core/tool-result'

const RawChoice = z.union([
  z
    .string()
    .trim()
    .min(1)
    .max(200)
    .describe('A short label that identifies the choice without rereading the question.'),
  z.object({
    label: z
      .string()
      .trim()
      .min(1)
      .max(200)
      .describe('A short label that identifies the choice without rereading the question.'),
    description: z
      .string()
      .trim()
      .min(1)
      .max(500)
      .optional()
      .describe('The result or tradeoff of selecting this choice.')
  })
])
const ClarifyParams = z.object({
  question: z
    .string()
    .trim()
    .min(1)
    .max(2_000)
    .describe('One self-contained question with only the context needed to answer it.'),
  choices: z
    .array(RawChoice)
    .min(2)
    .max(4)
    .describe(
      'Two to four materially different choices. Omit this field for an open-ended question. Include a no-action choice when the user may decline the action.'
    )
    .optional()
})

type ClarifyParams = z.output<typeof ClarifyParams>
type ClarifyChoiceInput = z.output<typeof RawChoice>
type NormalizedChoice = { label: string; description?: string }
type ClarifyDetails = {
  tool: 'clarify'
  ok: true
  question: string
  choices: NormalizedChoice[]
}

const DESCRIPTION = [
  'Ask the user one question only when the answer is necessary to choose the intended result or next action.',
  'Use the request and prior conversation before asking. Do not ask about a preference the user already gave or when a safe low-risk default is available.',
  'For post-task feedback, ask only when the answer will decide whether to accept, revise, or continue the work.',
  'On success it returns the normalized question and choices, records them durably, and ends the current turn. Do not emit another answer or call more tools; the user reply arrives as the next user message.'
].join('\n')

export function createClarifyTool(): AgentTool<typeof ClarifyParams, ClarifyDetails> {
  return {
    name: 'clarify',
    description: DESCRIPTION,
    schema: ClarifyParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.clarify' }),
    async execute(_toolCallId, params): Promise<AgentToolResult<ClarifyDetails>> {
      const details: ClarifyDetails = {
        tool: 'clarify',
        ok: true,
        question: params.question,
        choices: (params.choices ?? []).map(normalizeChoice).filter(choice => choice.label !== '')
      }

      return jsonToolResult(details, { terminate: true })
    }
  }
}

function normalizeChoice(value: ClarifyChoiceInput): NormalizedChoice {
  if (typeof value === 'string') return { label: value }
  const label = value.label
  const description = value.description
  return {
    label,
    ...(description && description !== label ? { description } : {})
  }
}
