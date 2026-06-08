import {
  bullxInteractiveOutputActionValueVersion,
  bullxInteractiveOutputVersion,
  type BullXInteractiveOutput,
  type BullXInteractiveOutputActionValue,
  type BullXInteractiveOutputChoiceOption,
  type BullXInteractiveOutputChoiceResponse
} from '@agentbull/bullx-sdk/plugins'

export function isBullXInteractiveOutputPayload(
  value: unknown
): value is { kind: 'interactive_output'; output: BullXInteractiveOutput } {
  const record = asRecord(value)
  return record?.kind === 'interactive_output' && isBullXInteractiveOutput(record.output)
}

export function isLarkNativeCardPayload(
  value: unknown
): value is { kind: 'lark_native_card'; card: Record<string, unknown>; fallbackText: string } {
  const record = asRecord(value)
  return (
    record?.kind === 'lark_native_card' &&
    asRecord(record.card) !== undefined &&
    typeof record.fallbackText === 'string'
  )
}

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

    if (output.response.options.length > 0) {
      elements.push({
        tag: 'action',
        actions: output.response.options.map(option =>
          choiceButton(output.response as BullXInteractiveOutputChoiceResponse, option, output)
        )
      })
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
    value: actionValue(response, option)
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

function isBullXInteractiveOutput(value: unknown): value is BullXInteractiveOutput {
  const record = asRecord(value)
  if (!record || record.version !== bullxInteractiveOutputVersion) return false
  if (typeof record.fallbackText !== 'string' || record.fallbackText.length === 0) return false
  const content = asRecord(record.content)
  if (!content || typeof content.body !== 'string') return false
  return record.response === undefined || isChoiceResponse(record.response)
}

function isChoiceResponse(value: unknown): value is BullXInteractiveOutputChoiceResponse {
  const record = asRecord(value)
  if (!record || record.type !== 'choice') return false
  if (typeof record.interactionId !== 'string' || !record.interactionId) return false
  if (typeof record.controlId !== 'string' || !record.controlId) return false
  if (record.selection !== 'single' && record.selection !== 'multi') return false
  return Array.isArray(record.options)
}

function asRecord(value: unknown): Record<string, any> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, any>)
    : undefined
}

function escapeMarkdown(value: string): string {
  return value.replace(/([*_`[\]])/g, '\\$1')
}
