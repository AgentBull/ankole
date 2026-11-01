import { t } from 'i18next'
import { useEffect, useState } from 'react'
import { useQueryClient, type QueryClient } from '@tanstack/react-query'
import { contentKeys } from './content-api'
import { useContent } from './content-context'
import { isRealtimeAccessDenied, type PodRealtime } from './realtime'

const pageJoinTimeoutMs = 10_000

/** File and Applet publications share invalidation; document OT owns its own connection. */
export function usePageRealtime(pageID: string, revision: number, objectID?: string | null) {
  const { realtime } = useContent()
  const client = useQueryClient()
  const [revoked, setRevoked] = useState(false)
  const [error, setError] = useState<unknown>()
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    setError(undefined)
    return watchPageRealtime(
      realtime,
      client,
      pageID,
      revision,
      { revoked: () => setRevoked(true), failed: setError },
      objectID
    )
  }, [pageID, revision, objectID, realtime, client, attempt])
  return { revoked, error, retry: () => setAttempt(value => value + 1) }
}

export function watchPageRealtime(
  realtime: Pick<PodRealtime, 'join' | 'watchVersion'>,
  client: QueryClient,
  pageID: string,
  revision: number,
  page: { revoked(): void; failed(error: Error): void },
  objectID?: string | null
) {
  let disposed = false
  let timedOut = false
  let close: (() => void) | undefined
  const revoke = () => {
    if (disposed) return
    page.revoked()
    close?.()
    void client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
  }
  const failed = (failure?: unknown) => {
    if (disposed) return
    clearTimeout(joining)
    if (isRealtimeAccessDenied(failure)) revoke()
    else page.failed(new Error(t('pod.content.the_realtime_connection_is_temporarily_unavailable_you_can_still_view')))
    close?.()
  }
  // The token request, the socket, and the Phoenix join can each stay pending, so the deadline covers all of them.
  const joining = setTimeout(() => {
    timedOut = true
    failed()
  }, pageJoinTimeoutMs)
  void realtime
    .join(`page:${pageID}`)
    .then(handle => {
      if (disposed || timedOut) return handle.close()
      close = handle.close
      handle.on('changes', () => void client.invalidateQueries({ queryKey: contentKeys.page(pageID) }))
      handle.on('comments_changed', () => void client.invalidateQueries({ queryKey: contentKeys.comments(pageID) }))
      handle.on('access_revoked', revoke)
      void handle.ready.then(() => clearTimeout(joining), failed)
    })
    .catch(failed)
  const unwatch = realtime.watchVersion('pages', pageID, (next, nextObjectID) => {
    if (disposed) return
    if (next === undefined) revoke()
    else if (objectID === undefined ? next !== revision : nextObjectID !== objectID) {
      void client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
    }
  })
  return () => {
    disposed = true
    clearTimeout(joining)
    close?.()
    unwatch()
  }
}
