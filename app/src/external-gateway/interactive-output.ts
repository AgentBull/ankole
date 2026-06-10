import type {
  BullXInteractiveOutput,
  BullXInteractiveOutputCardPayload,
  BullXLarkNativeCardPayload
} from '@agentbull/bullx-sdk/plugins'
import type { JsonObject } from '@/common/db-schema'

/**
 * Host-side constructors for External Gateway card payloads. Validation lives
 * in the SDK next to the types (`isBullXExternalGatewayCardPayload` and
 * friends) so the host and adapters cannot drift.
 */

export const INTERACTIVE_OUTPUT_KIND = 'interactive_output'
export const LARK_NATIVE_CARD_KIND = 'lark_native_card'

export function interactiveOutputCardPayload(output: BullXInteractiveOutput): BullXInteractiveOutputCardPayload {
  return { kind: INTERACTIVE_OUTPUT_KIND, output }
}

export function larkNativeCardPayload(card: JsonObject, fallbackText: string): BullXLarkNativeCardPayload {
  return { kind: LARK_NATIVE_CARD_KIND, card, fallbackText }
}
