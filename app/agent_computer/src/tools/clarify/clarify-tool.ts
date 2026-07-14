import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { jsonToolResult } from '../../core/tool-result'

const RawChoice = z.union([
  z.string().trim().min(1).max(200).describe('Choice label.'),
  z.object({
    label: z.string().trim().min(1).max(200).describe('Short choice label.'),
    description: z.string().trim().min(1).max(500).optional().describe('What selecting this choice means.')
  })
])
const ClarifyParams = z.object({
  question: z.string().trim().min(1).max(2_000).describe('One concrete question for the user.'),
  choices: z
    .array(RawChoice)
    .max(4)
    .describe('Up to four materially distinct choices. The UI adds Other/free input automatically.')
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
  'Ask the user one decision question when ambiguity materially changes the result.',
  'Use for real tradeoffs, missing requirements, and post-task feedback; do not ask when a safe low-risk default is available.',
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
