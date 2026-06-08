import {
  bullxInteractiveOutputActionValueVersion,
  bullxInteractiveOutputVersion,
  type BullXExternalGatewayCardPayload,
  type BullXInteractiveOutput,
  type BullXInteractiveOutputActionValue,
  type BullXInteractiveOutputCardPayload,
  type BullXInteractiveOutputChoiceOption,
  type BullXInteractiveOutputChoiceResponse,
  type BullXLarkNativeCardPayload
} from '@agentbull/bullx-sdk/plugins'
import type { JsonObject } from '@/common/db-schema'

export const INTERACTIVE_OUTPUT_KIND = 'interactive_output'
export const LARK_NATIVE_CARD_KIND = 'lark_native_card'

export function interactiveOutputCardPayload(output: BullXInteractiveOutput): BullXInteractiveOutputCardPayload {
  return { kind: INTERACTIVE_OUTPUT_KIND, output }
}

export function larkNativeCardPayload(card: JsonObject, fallbackText: string): BullXLarkNativeCardPayload {
  return { kind: LARK_NATIVE_CARD_KIND, card, fallbackText }
}

export function interactiveChoiceActionValue(
  response: Pick<BullXInteractiveOutputChoiceResponse, 'interactionId' | 'controlId'>,
  option: Pick<BullXInteractiveOutputChoiceOption, 'id' | 'value'>
): BullXInteractiveOutputActionValue {
  return {
    version: bullxInteractiveOutputActionValueVersion,
    interactionId: response.interactionId,
    controlId: response.controlId,
    optionId: option.id,
    value: option.value
  }
}

export function parseInteractiveOutputActionValue(value: unknown): BullXInteractiveOutputActionValue | undefined {
  const record = typeof value === 'string' ? safeJsonParse(value) : value
  if (!isRecord(record)) return undefined
  if (record.version !== bullxInteractiveOutputActionValueVersion) return undefined
  if (typeof record.interactionId !== 'string' || !record.interactionId) return undefined
  if (typeof record.controlId !== 'string' || !record.controlId) return undefined
  return {
    version: bullxInteractiveOutputActionValueVersion,
    interactionId: record.interactionId,
    controlId: record.controlId,
    optionId: typeof record.optionId === 'string' ? record.optionId : undefined,
    value: typeof record.value === 'string' ? record.value : undefined
  }
}

export function isExternalGatewayCardPayload(value: unknown): value is BullXExternalGatewayCardPayload {
  return isInteractiveOutputCardPayload(value) || isLarkNativeCardPayload(value)
}

export function isInteractiveOutputCardPayload(value: unknown): value is BullXInteractiveOutputCardPayload {
  const record = isRecord(value) ? value : undefined
  return record?.kind === INTERACTIVE_OUTPUT_KIND && isInteractiveOutput(record.output)
}

export function isLarkNativeCardPayload(value: unknown): value is BullXLarkNativeCardPayload {
  const record = isRecord(value) ? value : undefined
  return record?.kind === LARK_NATIVE_CARD_KIND && isRecord(record.card) && typeof record.fallbackText === 'string'
}

export function cardPayloadFallbackText(payload: BullXExternalGatewayCardPayload): string {
  return payload.kind === INTERACTIVE_OUTPUT_KIND ? payload.output.fallbackText : payload.fallbackText
}

export function isInteractiveOutput(value: unknown): value is BullXInteractiveOutput {
  if (!isRecord(value)) return false
  if (value.version !== bullxInteractiveOutputVersion) return false
  if (typeof value.fallbackText !== 'string' || value.fallbackText.length === 0) return false
  const content = value.content
  if (!isRecord(content) || typeof content.body !== 'string') return false
  if (value.response !== undefined && !isInteractiveOutputResponse(value.response)) return false
  if (value.state !== undefined && !isInteractiveOutputState(value.state)) return false
  return true
}

function isInteractiveOutputResponse(value: unknown): value is BullXInteractiveOutput['response'] {
  if (!isRecord(value)) return false
  if (value.type !== 'choice') return false
  if (typeof value.interactionId !== 'string' || !value.interactionId) return false
  if (typeof value.controlId !== 'string' || !value.controlId) return false
  if (value.selection !== 'single' && value.selection !== 'multi') return false
  if (!Array.isArray(value.options)) return false
  return value.options.every(isChoiceOption)
}

function isChoiceOption(value: unknown): value is BullXInteractiveOutputChoiceOption {
  return (
    isRecord(value) &&
    typeof value.id === 'string' &&
    value.id.length > 0 &&
    typeof value.label === 'string' &&
    typeof value.value === 'string'
  )
}

function isInteractiveOutputState(value: unknown): value is BullXInteractiveOutput['state'] {
  if (!isRecord(value)) return false
  return (
    value.status === 'open' ||
    value.status === 'answered' ||
    value.status === 'expired' ||
    value.status === 'cancelled' ||
    value.status === 'superseded'
  )
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function safeJsonParse(value: string): unknown {
  try {
    return JSON.parse(value)
  } catch {
    return undefined
  }
}
