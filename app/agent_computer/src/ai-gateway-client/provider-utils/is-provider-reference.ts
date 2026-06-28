import type { SharedProviderReference } from '@/ai-gateway-client/provider'
import { isPlainObject } from '@pleisto/active-support'

/**
 * Checks whether a value is a provider reference (a mapping of provider names
 * to provider-specific identifiers) as opposed to raw bytes, a URL, or a
 * tagged `{ type: ... }` object.
 */
export function isProviderReference(data: unknown): data is SharedProviderReference {
  return isPlainObject(data) && !('type' in data)
}
