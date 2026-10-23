import type { Principal } from '../api/v2/generated/types.gen'
import type { Flat } from '../api/json-api'

/** Names a Principal by display name, email, handle, then UID. */
export function principalLabel(principal: Pick<Flat<Principal>, 'display_name' | 'email' | 'handle' | 'id'>): string {
  return principal.display_name ?? principal.email ?? principal.handle ?? principal.id
}
