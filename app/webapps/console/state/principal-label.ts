import type { PrincipalItem } from '../api/generated/types.gen'

/** Names a Principal by display name, email, handle, then UID. */
export function principalLabel(principal: Pick<PrincipalItem, 'display_name' | 'email' | 'handle' | 'uid'>): string {
  return principal.display_name ?? principal.email ?? principal.handle ?? principal.uid
}
