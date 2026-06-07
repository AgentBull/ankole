/**
 * Interactive Feishu clarify card (runner.ex clarify-card parity) + button-value
 * protocol. Pure functions — the adapter only forwards the card JSON; the
 * correlation_id is the conversationId so a card action resolves directly against
 * the clarify registry (keyed by conversationId).
 */

export interface ClarifyAnswerValue {
  bullx_action: 'clarify_answer'
  correlation_id: string
  choice_index: number
  choice_value: string
}

export interface ClarifyCardInput {
  question: string
  choices: string[]
  correlationId: string
  locked?: boolean
  answeredChoiceIndex?: number
  answeredText?: string
}

export function renderClarifyCard(input: ClarifyCardInput): Record<string, unknown> {
  const elements: Record<string, unknown>[] = [
    { tag: 'div', text: { tag: 'lark_md', content: input.question } },
    { tag: 'div', text: { tag: 'plain_text', content: 'Reply in this chat if none of the choices fit.' } }
  ]

  if (input.choices.length > 0) {
    elements.push({
      tag: 'action',
      actions: input.choices.map((choice, index) => {
        const value: ClarifyAnswerValue = {
          bullx_action: 'clarify_answer',
          correlation_id: input.correlationId,
          choice_index: index,
          choice_value: choice
        }
        return {
          tag: 'button',
          text: {
            tag: 'plain_text',
            content: input.locked && index === input.answeredChoiceIndex ? `${choice} ✓` : choice
          },
          type: 'primary',
          ...(input.locked ? { disabled: true } : {}),
          value
        }
      })
    })
  }

  if (input.locked) {
    elements.push({
      tag: 'div',
      text: { tag: 'plain_text', content: `Answered: ${input.answeredText ?? ''}`, text_color: 'grey' }
    })
  }

  return {
    schema: '2.0',
    config: { update_multi: true },
    header: { title: { tag: 'plain_text', content: 'Clarification needed' } },
    body: { direction: 'vertical', padding: '12px 12px 12px 12px', elements }
  }
}

/** Parse a clarify card-action value (string JSON or object) into the answer protocol. */
export function parseClarifyAnswerValue(value: unknown): ClarifyAnswerValue | undefined {
  const record = typeof value === 'string' ? safeJsonParse(value) : value
  if (!record || typeof record !== 'object') return undefined
  const candidate = record as Record<string, unknown>
  if (candidate.bullx_action !== 'clarify_answer') return undefined
  const correlationId = typeof candidate.correlation_id === 'string' ? candidate.correlation_id : undefined
  if (!correlationId) return undefined
  return {
    bullx_action: 'clarify_answer',
    correlation_id: correlationId,
    choice_index: typeof candidate.choice_index === 'number' ? candidate.choice_index : -1,
    choice_value: typeof candidate.choice_value === 'string' ? candidate.choice_value : ''
  }
}

function safeJsonParse(value: string): unknown {
  try {
    return JSON.parse(value)
  } catch {
    return undefined
  }
}
