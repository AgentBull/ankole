import { compactRecord } from '@agentbull/active-support'
import { uuidExpand, uuidShorten } from './uuid-url'

/** Identity belongs to this document. Changing the browser default cannot change it. */
export function authenticationRef(): string | undefined {
  return meta('ankole-authentication')
}

export function principalUID(): string | undefined {
  return meta('ankole-principal')
}

/** Apply the server-confirmed rename to this document's Principal identity. */
export function replacePrincipalUID(uid: string): void {
  document.querySelector<HTMLMetaElement>('meta[name="ankole-principal"]')!.content = uid
}

/** A verified credential change replaces only this document's proof. */
export function replaceAuthentication(reference: string, csrfToken: string): void {
  document.querySelector<HTMLMetaElement>('meta[name="ankole-authentication"]')!.content = reference
  document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')!.content = csrfToken
}

export function podID(): string | undefined {
  return meta('ankole-pod')
}

export function devMailboxPath(): string | undefined {
  const path = meta('ankole-dev-mailbox')
  return path?.startsWith('/') && !path.startsWith('//') ? path : undefined
}

export function identityHeaders(): Record<string, string> {
  return compactRecord({
    'x-ankole-authentication': authenticationRef(),
    'x-ankole-pod': podID()
  }) as Record<string, string>
}

export function podRouteID(value: string | undefined): string | undefined {
  return value ? (uuidExpand(value) ?? (uuidShorten(value) ? value : undefined)) : undefined
}

export function podLocation(
  path: string,
  query: Record<string, string | null | undefined> = {}
): { pathname: string; search: string } {
  const pathname = path.replace(/^\/(pages|conversations)\/([^/]+)$/, (_match, kind, value) => {
    const id = podRouteID(value)
    if (!id) throw new Error('Invalid Pod route ID')
    return `/${kind}/${uuidShorten(id)}`
  })
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(query)) {
    if (value == null || key === 'tenant_id') continue
    const id = key === 'chat' ? podRouteID(value) : undefined
    params.set(key, id ? uuidShorten(id)! : value)
  }
  return { pathname, search: params.size ? `?${params}` : '' }
}

function meta(name: string): string | undefined {
  return typeof document === 'undefined'
    ? undefined
    : document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content || undefined
}
