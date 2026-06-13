import {
  bullxInteractiveOutputActionValueVersion,
  type BullXInteractiveOutput,
  type BullXInteractiveOutputActionValue,
  type BullXInteractiveOutputChoiceOption,
  type BullXInteractiveOutputChoiceResponse
} from '@agentbull/bullx-sdk/plugins'

export function renderInteractiveOutputToLarkCard(output: BullXInteractiveOutput): Record<string, unknown> {
  const elements: Record<string, unknown>[] = []

  elements.push({
    tag: 'div',
    text: textPayload(output.content.body, output.content.format === 'markdown' ? 'lark_md' : 'plain_text')
  })

  for (const fact of output.content.facts ?? []) {
    elements.push({
      tag: 'div',
      text: {
        tag: 'lark_md',
        content: `**${escapeMarkdown(fact.label)}:** ${escapeMarkdown(fact.value)}`
      }
    })
  }

  if (output.response?.type === 'choice') {
    const hint = output.response.customText?.enabled ? output.response.customText.hint : undefined
    if (hint) {
      elements.push({
        tag: 'div',
        text: { tag: 'plain_text', content: hint, text_color: 'grey' }
      })
    }

    // Card JSON 2.0 rejects the `action` wrapper module; buttons sit directly in elements.
    for (const option of output.response.options) {
      elements.push(choiceButton(output.response as BullXInteractiveOutputChoiceResponse, option, output))
    }
  }

  if (output.state?.status && output.state.status !== 'open') {
    const statusText = stateText(output)
    if (statusText) {
      elements.push({
        tag: 'div',
        text: { tag: 'plain_text', content: statusText, text_color: 'grey' }
      })
    }
  }

  return {
    schema: '2.0',
    config: { update_multi: true },
    ...(output.content.title ? { header: { title: { tag: 'plain_text', content: output.content.title } } } : {}),
    body: {
      direction: 'vertical',
      horizontal_spacing: '8px',
      vertical_spacing: '8px',
      padding: '12px 12px 12px 12px',
      elements
    }
  }
}

function choiceButton(
  response: BullXInteractiveOutputChoiceResponse,
  option: BullXInteractiveOutputChoiceOption,
  output: BullXInteractiveOutput
): Record<string, unknown> {
  const locked = output.state?.status !== undefined && output.state.status !== 'open'
  const selected = output.state?.selectedOptionId === option.id
  return {
    tag: 'button',
    name: response.controlId,
    text: {
      tag: 'plain_text',
      content: selected ? `${option.label} (selected)` : option.label
    },
    ...(option.style && option.style !== 'default' ? { type: option.style } : {}),
    ...(locked ? { disabled: true } : {}),
    behaviors: [{ type: 'callback', value: actionValue(response, option) }]
  }
}

function actionValue(
  response: BullXInteractiveOutputChoiceResponse,
  option: BullXInteractiveOutputChoiceOption
): BullXInteractiveOutputActionValue {
  return {
    version: bullxInteractiveOutputActionValueVersion,
    interactionId: response.interactionId,
    controlId: response.controlId,
    optionId: option.id,
    value: option.value
  }
}

function textPayload(content: string, tag: 'plain_text' | 'lark_md'): Record<string, unknown> {
  return { tag, content }
}

function stateText(output: BullXInteractiveOutput): string | undefined {
  if (output.state?.status === 'answered') return `Answered: ${output.state.responseText ?? ''}`.trim()
  if (output.state?.status === 'expired') return 'Expired'
  if (output.state?.status === 'cancelled') return 'Cancelled'
  if (output.state?.status === 'superseded') return 'Superseded'
  return undefined
}

function escapeMarkdown(value: string): string {
  return value.replace(/([*_`[\]])/g, '\\$1')
}
