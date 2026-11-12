import type { MutationCacheNotifyEvent, QueryCacheNotifyEvent, QueryClient } from '@tanstack/react-query'
import { InternalAPIError } from '../common/internal-api-client'
import { getPodRuntimeBootstrap } from '../common/pod-bootstrap'
import { requestErrorCode } from '../common/request-errors'
import { isAppletRouteError } from './applet-routes'

// `RequirePodSession` answers `unauthorized`; the browser session endpoint answers `unauthenticated`.
const missingSessionCodes = ['unauthorized', 'unauthenticated']

/**
 * Only a missing session leaves the Pod; other 401 codes, such as a wrong verification code, stay with their form.
 * Applet route failures never count, and the Pod's own requests still notice a session that really ended.
 */
function isMissingPodSession(error: unknown): boolean {
  return (
    error instanceof InternalAPIError &&
    error.status === 401 &&
    missingSessionCodes.includes(requestErrorCode(error.payload) ?? '') &&
    !isAppletRouteError(error)
  )
}

/**
 * The open Pod shell follows the same sign-in redirect as a Pod page load
 * without a session, instead of showing a session error in every section.
 */
export function watchPodSession(
  client: QueryClient,
  location: Pick<Location, 'pathname' | 'search' | 'assign'> = window.location
): () => void {
  let redirecting = false
  const onEvent = (event: QueryCacheNotifyEvent | MutationCacheNotifyEvent) => {
    if (redirecting || event.type !== 'updated' || event.action.type !== 'error') return
    if (!isMissingPodSession(event.action.error)) return
    // One navigation is enough; each repeat would show the unsaved-draft prompt again.
    redirecting = true
    const runtime = getPodRuntimeBootstrap()
    if (runtime?.mode === 'desktop') {
      runtime.onSessionExpired?.()
      return
    }
    const path = location.pathname + location.search
    location.assign(path === '/' ? '/sessions/new' : `/sessions/new?${new URLSearchParams({ return_to: path })}`)
  }
  const stopQueries = client.getQueryCache().subscribe(onEvent)
  const stopMutations = client.getMutationCache().subscribe(onEvent)
  return () => {
    stopQueries()
    stopMutations()
  }
}
