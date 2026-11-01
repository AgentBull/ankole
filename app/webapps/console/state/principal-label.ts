import type { Principal } from '../api/v2/generated/types.gen'
import type { Flat } from '../api/json-api'

/** Names a Principal by display name, email, then UID. */
export function principalLabel(principal: Pick<Flat<Principal>, 'display_name' | 'email' | 'id'>): string {
  return principal.display_name ?? principal.email ?? principal.id
}
