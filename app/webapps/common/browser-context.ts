import { compactRecord } from '@agentbull/active-support'

export { podLocation, podRouteID } from './pod-url'

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

function meta(name: string): string | undefined {
  return typeof document === 'undefined'
    ? undefined
    : document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content || undefined
}
