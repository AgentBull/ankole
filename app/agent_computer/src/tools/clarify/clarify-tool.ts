import { isRecord } from '@pleisto/active-support'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { jsonToolResult } from '../../core/tool-result'

const RawChoice = z.union([z.string(), z.record(z.string(), z.unknown())])
const ClarifyParams = z.object({
  question: z.string().min(1).max(2_000).describe('One concrete question for the user.'),
  choices: z
    .array(RawChoice)
    .max(4)
    .describe('Up to four materially distinct choices. The UI adds Other/free input automatically.')
    .optional()
})

type ClarifyParams = z.output<typeof ClarifyParams>
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
  'Provide at most four choices. The delivery UI always adds Other/free input.',
  'This is turn-ending: after calling clarify, add at most one short lead-in sentence or end the answer. Do not repeat the question or choices. The user reply arrives as the next user message.'
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
        question: params.question.trim(),
        choices: (params.choices ?? []).map(normalizeChoice).filter(choice => choice.label !== '')
      }

      return jsonToolResult(details)
    }
  }
}

function normalizeChoice(value: string | Record<string, unknown>): NormalizedChoice {
  if (typeof value === 'string') return { label: value.trim() }
  if (!isRecord(value)) return { label: '' }

  const label = firstText(value, ['label', 'text', 'title', 'description'])
  const description = firstText(value, ['description', 'detail', 'help'])
  return {
    label: label ?? '',
    ...(description && description !== label ? { description } : {})
  }
}

function firstText(value: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const candidate = value[key]
    if (typeof candidate === 'string' && candidate.trim()) return candidate.trim()
  }
  return undefined
}
