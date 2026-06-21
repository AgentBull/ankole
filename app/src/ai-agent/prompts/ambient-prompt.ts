/**
 * Prompt and structured-output plumbing for the ambient recognizer: the cheap
 * pre-step that decides whether the agent should *proactively* speak in an IM
 * room where it was not directly addressed.
 *
 * This is a yes/no classifier, not the visible reply — that is written later by
 * the normal generation loop. Because it only needs a decision, it runs on a
 * small/fast model and forces a strict JSON result (`{ intervene, reason_summary }`)
 * so the caller never has to parse free-form prose. The trickier part is that the
 * two OpenAI-style transports want the schema in different envelopes (Responses
 * API vs Chat Completions), and not every provider supports server-side strict
 * JSON, so the helpers below detect the payload shape and the model's capability
 * before attaching the schema.
 */
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

/**
 * Strict JSON schema the recognizer model must satisfy. `additionalProperties:
 * false` plus both fields required keeps the output to exactly the decision and a
 * short reason, which the downstream parser relies on. The `description` strings
 * double as model-facing instructions for what each field means.
 */
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

// The same schema in the two shapes the OpenAI families expect. The Responses API
// takes the json_schema fields flat (name/strict/schema at the top level); Chat
// Completions nests them under a `json_schema` key. Keeping both literals avoids
// reshaping at the call site.
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

/**
 * Builds the system prompt for the recognizer model.
 *
 * It reuses the agent's real identity, soul, and mission so the decision is made
 * "as that teammate" — the product framing is literally "would a capable human
 * with this identity step in now?". The intervention policy biases toward silence:
 * the cost of a wrong proactive message in a shared room (surprising, duplicative,
 * or stepping on other agents) is higher than the cost of staying quiet.
 */
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

/**
 * Builds the user-turn prompt carrying the room state to judge, passed in as YAML.
 *
 * The closing instruction is the load-bearing part: only the *current* observed
 * messages may trigger a reply; the recent transcript and earlier observations are
 * context only. This stops the model from re-firing on stale chatter it already saw
 * on a previous tick.
 */
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

/**
 * Wraps stream options so the strict-JSON schema is injected into the outgoing
 * request just before it is sent.
 *
 * Done via the `onPayload` hook rather than at construction time because only the
 * hook sees the final, fully resolved request and the concrete `model` it is being
 * sent to — which is what decides whether server-side structured output is even
 * supported. Any caller-supplied `onPayload` is honored first, then the schema is
 * applied on top of its result, so this composes instead of clobbering.
 */
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

/**
 * Attaches the decision schema to an outgoing request payload, choosing the
 * envelope by the payload's own shape.
 *
 * The shape is detected by a marker key rather than by an explicit API flag: an
 * `input` array means the Responses API (schema goes under `text.format`), while a
 * `messages` array means Chat Completions (schema goes in `response_format`). A
 * shallow copy is made so the caller's payload object is not mutated in place.
 * Anything that matches neither marker is returned untouched.
 */
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

/** Returns the schema in a plain object form suitable for request logging/telemetry. */
export function ambientRecognizerResponseSchemaForLog(): Record<string, unknown> {
  return AMBIENT_RECOGNIZER_RESPONSE_FORMAT
}

function agentIdentitySection(input: AmbientRecognizerSystemPromptInput): string {
  return ['<agent_identity>', `display_name: ${input.displayName}`, `uid: ${input.agentUid}`, '</agent_identity>'].join(
    '\n'
  )
}

/** Emits the soul block, or nothing when the agent has no soul text. */
function agentSoulSection(soul: string): string {
  const content = soul.trim()
  if (!content) return ''
  return ['<agent_soul>', content, '</agent_soul>'].join('\n')
}

/** Emits the mission block, or nothing when no mission is set. */
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

/**
 * Reports whether the target model supports server-side strict JSON output, so the
 * caller can fall back to text parsing when it does not.
 *
 * The Responses APIs (OpenAI and Azure) always do. For the Chat Completions API,
 * strict `json_schema` is only known-good on a few providers, so it allow-lists
 * them by provider id and then by base-URL host as a backstop for cases where the
 * provider id is unset but the endpoint is clearly OpenAI or OpenRouter. Anything
 * else is treated as unsupported rather than risking a rejected request.
 */
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
