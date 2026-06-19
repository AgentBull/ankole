import type { SimpleStreamOptions } from '@/llm'

export interface AmbientRecognizerSystemPromptInput {
  agentUid: string
  channelLabel?: string
  conversationId: string
  displayName: string
  mission?: string
  soul: string
  timezone: string
}

export const AMBIENT_RECOGNIZER_RESPONSE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['intervene', 'reason_summary'],
  properties: {
    intervene: {
      type: 'boolean',
      description: 'True when the agent should send a visible reply to the room now.'
    },
    reason_summary: {
      type: 'string',
      description: 'Brief operational reason for the decision. Use an empty string only when there is no useful reason.'
    }
  }
} as const

const AMBIENT_RECOGNIZER_RESPONSE_FORMAT = {
  type: 'json_schema',
  name: 'ambient_intervention_decision',
  strict: true,
  schema: AMBIENT_RECOGNIZER_RESPONSE_SCHEMA
} as const

const AMBIENT_RECOGNIZER_CHAT_RESPONSE_FORMAT = {
  type: 'json_schema',
  json_schema: {
    name: AMBIENT_RECOGNIZER_RESPONSE_FORMAT.name,
    strict: AMBIENT_RECOGNIZER_RESPONSE_FORMAT.strict,
    schema: AMBIENT_RECOGNIZER_RESPONSE_SCHEMA
  }
} as const

export function buildAmbientRecognizerSystemPrompt(input: AmbientRecognizerSystemPromptInput): string {
  return [
    `You are deciding whether ${input.displayName} should proactively speak in an IM room.`,
    '',
    'This is an internal BullX decision step, not the visible reply. The visible reply, if any, will be written by the normal agent generation loop.',
    '',
    agentIdentitySection(input),
    agentSoulSection(input.soul),
    missionSection(input.mission),
    runtimeContextSection(input),
    [
      '<intervention_policy>',
      '"Ambient" means room messages observed by BullX where the agent was not directly addressed.',
      'The product question is whether a capable human teammate with this agent identity would now enter the conversation with a useful, low-friction reply.',
      'Return intervene=true when the current observed messages contain a concrete request, question, correction, handoff, blocker, or recoverable reference that this agent can likely answer or unblock.',
      'Return intervene=true when people clearly summon or assign work to the agent but omit a material detail; the later visible reply should ask a brief clarification.',
      'Return intervene=false for background chatter, stale context, social noise, or situations where a visible agent reply would be surprising, duplicative, risky, or unsupported by the available IM context.',
      'Prefer not speaking unless the current room would reasonably benefit from the agent entering now.',
      '</intervention_policy>',
      '',
      'Use the structured output schema. Do not write markdown or prose outside the structured result.'
    ].join('\n')
  ]
    .filter(Boolean)
    .join('\n\n')
}

export function buildAmbientRecognizerUserPrompt(decisionInputYaml: string): string {
  return [
    'Decide whether the agent should send a visible reply to the IM room now.',
    '',
    '<im_intervention_decision_input format="yaml">',
    decisionInputYaml.trim(),
    '</im_intervention_decision_input>',
    '',
    'Use only the current observed messages as the trigger. Recent transcript and earlier observed messages are supporting context, not standalone reasons to speak.'
  ].join('\n')
}

export function withAmbientRecognizerStructuredOutputOptions(options: SimpleStreamOptions): SimpleStreamOptions {
  return {
    ...options,
    onPayload: async (payload, model) => {
      const replacement = await options.onPayload?.(payload, model)
      const nextPayload = replacement ?? payload
      return supportsAmbientRecognizerStructuredOutput(model)
        ? applyAmbientRecognizerStructuredOutput(nextPayload)
        : nextPayload
    }
  }
}

export function applyAmbientRecognizerStructuredOutput(payload: unknown): unknown {
  if (!isRecord(payload)) return payload
  const next = { ...payload }

  if ('input' in next) {
    const text = isRecord(next.text) ? { ...next.text } : {}
    text.format = AMBIENT_RECOGNIZER_RESPONSE_FORMAT
    next.text = text
    return next
  }

  if ('messages' in next) {
    next.response_format = AMBIENT_RECOGNIZER_CHAT_RESPONSE_FORMAT
    return next
  }

  return next
}

export function ambientRecognizerResponseSchemaForLog(): Record<string, unknown> {
  return AMBIENT_RECOGNIZER_RESPONSE_FORMAT
}

function agentIdentitySection(input: AmbientRecognizerSystemPromptInput): string {
  return ['<agent_identity>', `display_name: ${input.displayName}`, `uid: ${input.agentUid}`, '</agent_identity>'].join(
    '\n'
  )
}

function agentSoulSection(soul: string): string {
  const content = soul.trim()
  if (!content) return ''
  return ['<agent_soul>', content, '</agent_soul>'].join('\n')
}

function missionSection(mission: string | undefined): string {
  const content = mission?.trim()
  if (!content) return ''
  return ['<mission>', content, '</mission>'].join('\n')
}

function runtimeContextSection(input: AmbientRecognizerSystemPromptInput): string {
  const lines = [
    '<runtime_context>',
    `timezone: ${input.timezone}`,
    `conversation_id: ${input.conversationId}`,
    `current_channel: ${input.channelLabel ?? 'unknown room'}`
  ]
  lines.push('</runtime_context>')
  return lines.join('\n')
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function supportsAmbientRecognizerStructuredOutput(model: {
  api?: string
  baseUrl?: string
  provider?: string
}): boolean {
  if (model.api === 'openai-responses' || model.api === 'azure-openai-responses') return true
  if (model.api !== 'openai-completions') return false
  if (model.provider === 'openai' || model.provider === 'openrouter' || model.provider === 'vercel-ai-gateway') {
    return true
  }
  return Boolean(model.baseUrl?.includes('api.openai.com') || model.baseUrl?.includes('openrouter.ai'))
}
