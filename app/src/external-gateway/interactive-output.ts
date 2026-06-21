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

// These `kind` strings are the discriminants the outbox dispatcher and the SDK
// validators switch on to tell the two card payload shapes apart.
export const INTERACTIVE_OUTPUT_KIND = 'interactive_output'
export const LARK_NATIVE_CARD_KIND = 'lark_native_card'

/** Wraps portable interactive output as a card payload the dispatcher can route. */
export function interactiveOutputCardPayload(output: BullXInteractiveOutput): BullXInteractiveOutputCardPayload {
  return { kind: INTERACTIVE_OUTPUT_KIND, output }
}

/**
 * Wraps a Lark-native card. `fallbackText` is the plain text shown wherever the
 * card cannot render (notifications, unsupported clients), so it must stand on
 * its own as the message's meaning.
 */
export function larkNativeCardPayload(card: JsonObject, fallbackText: string): BullXLarkNativeCardPayload {
  return { kind: LARK_NATIVE_CARD_KIND, card, fallbackText }
}
