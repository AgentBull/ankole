import { compactRecord } from '@agentbull/active-support'
import {
  getPodRuntimeBootstrap,
  isDesktopRuntime,
  podPublicOrigin,
  podSiteOrigin,
  updatePodRuntimeBootstrap
} from './pod-bootstrap'

export { podLocation, podRouteID } from './pod-url'
export { isDesktopRuntime, podPublicOrigin, podSiteOrigin }

/** Identity belongs to this document. Changing the browser default cannot change it. */
export function authenticationRef(): string | undefined {
  if (isDesktopRuntime()) return undefined
  return meta('ankole-authentication')
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
