import type { RouteCall, RoutesAPI } from '@ankole/applet-sdk/types'
import { contentKeys } from './content-api'
import { createClientConfig, InternalAPIError } from '../common/internal-api-client'

/** Each runtime uses the downloaded publication, even if the page changed during loading. */
export function createAppletRoutes(pageID: string, revision: number, onRevisionChanged: () => void): RoutesAPI {
  const transport = createClientConfig({}).fetch!
  const key = [...contentKeys.all, 'applet-routes', pageID, revision] as const
  let stale = false
  return {
    key: () => key,
    async call<T>({ method, path, ...request }: RouteCall) {
      if (stale) {
        throw new InternalAPIError(409, 'Conflict', { error: { code: 'applet_revision_changed' } })
      }
      const query = new URLSearchParams()
      for (const [name, value] of Object.entries(request.query ?? {})) {
        for (const item of Array.isArray(value) ? value : [value]) query.append(name, item)
      }
      const suffix = query.size ? `?${query}` : ''
      try {
        const response = await transport(
          `/.internal-apis/pod/pages/${encodeURIComponent(pageID)}/routes${path}${suffix}`,
          {
            method,
            signal: request.signal,
            headers: {
              accept: 'application/json',
              'x-ankole-applet-revision': String(revision),
              ...(request.body !== undefined ? { 'content-type': 'application/json' } : {})
            },
            body: request.body === undefined ? undefined : JSON.stringify(request.body)
          }
        )
        return (response.status === 204 ? undefined : await response.json()) as T
      } catch (error) {
        if (
          error instanceof InternalAPIError &&
          error.status === 409 &&
          (error.payload as { error?: { code?: string } })?.error?.code === 'applet_revision_changed'
        ) {
          if (!stale) {
            stale = true
            onRevisionChanged()
          }
        }
        throw error
      }
    }
  }
}
