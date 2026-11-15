import { compactRecord } from '@agentbull/active-support'
import { getPodRuntimeBootstrap, isDesktopRuntime, podPublicOrigin, updatePodRuntimeBootstrap } from './pod-bootstrap'

export { podLocation, podRouteID } from './pod-url'
export { isDesktopRuntime, podPublicOrigin }

/** Identity belongs to this document. Changing the browser default cannot change it. */
export function authenticationRef(): string | undefined {
  if (isDesktopRuntime()) return undefined
  return meta('ankole-authentication')
}

/** Discriminator for session-scoped client caches across browser proofs and Desktop workspaces. */
export function sessionIdentityKey(): string | undefined {
  return authenticationRef() ?? getPodRuntimeBootstrap()?.principalUid
}

export function principalUID(): string | undefined {
  return getPodRuntimeBootstrap()?.principalUid ?? meta('ankole-principal')
}

/** Apply the server-confirmed rename to this document's Principal identity. */
export function replacePrincipalUID(uid: string): void {
  if (isDesktopRuntime()) {
    updatePodRuntimeBootstrap({ principalUid: uid })
    return
  }
  const element = document.querySelector<HTMLMetaElement>('meta[name="ankole-principal"]')
  if (element) element.content = uid
}

/** A verified credential change replaces only this document's proof. */
export function replaceAuthentication(reference: string, csrfToken: string): void {
  if (isDesktopRuntime()) return
  document.querySelector<HTMLMetaElement>('meta[name="ankole-authentication"]')!.content = reference
  document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')!.content = csrfToken
}

export function podID(): string | undefined {
  return getPodRuntimeBootstrap()?.tenantId ?? meta('ankole-pod')
}

export function devMailboxPath(): string | undefined {
  const path = meta('ankole-dev-mailbox')
  return path?.startsWith('/') && !path.startsWith('//') ? path : undefined
}

/**
 * Returns the optional CDN/static base prefix advertised by `<meta name="ankole-static-base">`
 * (for example `//ankole-static-files.cdn.agentbull.net`), or `""` when static assets resolve
 * from the current document origin or local Desktop bundle.
 */
export function staticAssetBase(): string {
  if (isDesktopRuntime()) return ''
  const raw = meta('ankole-static-base')?.trim()
  if (!raw) return ''
  if (raw.startsWith('//') && raw.length > 2 && !raw.startsWith('///')) {
    return raw.replace(/\/+$/, '')
  }
  if (/^https?:\/\/[^/\s]+/i.test(raw)) {
    return raw.replace(/\/+$/, '')
  }
  return ''
}

/** Prefixes a root-relative static asset path with `staticAssetBase()` when configured. */
export function staticAssetURL(path: string): string {
  const normalized = path.startsWith('/') ? path : `/${path}`
  const base = staticAssetBase()
  return base ? `${base}${normalized}` : normalized
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
