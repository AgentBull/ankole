import { t } from 'i18next'
import { useEffect, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { contentKeys } from './content-api'
import { useContent } from './content-context'
import { isRealtimeAccessDenied } from './realtime'

/** File and Applet publications share invalidation; document OT owns its own connection. */
export function usePageRealtime(pageID: string, revision: number) {
  const { realtime } = useContent()
  const client = useQueryClient()
  const [revoked, setRevoked] = useState(false)
  const [error, setError] = useState<unknown>()
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let disposed = false
    let close: (() => void) | undefined
    setError(undefined)
    const revoke = () => {
      if (disposed) return
      setRevoked(true)
      close?.()
      void client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
    }
    const failed = (failure: unknown) => {
      if (disposed) return
      if (isRealtimeAccessDenied(failure)) revoke()
      else setError(new Error(t('pod.content.the_realtime_connection_is_temporarily_unavailable_you_can_still_view')))
      close?.()
    }
    void realtime
      .join(`page:${pageID}`)
      .then(handle => {
        if (disposed) return handle.close()
        close = handle.close
        handle.on('changes', () => void client.invalidateQueries({ queryKey: contentKeys.page(pageID) }))
        handle.on('access_revoked', revoke)
        void handle.ready.catch(failed)
      })
      .catch(failed)
    const unwatch = realtime.watchVersion('pages', pageID, next => {
      if (disposed) return
      if (next === undefined) revoke()
      else if (next !== revision) void client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
    })
    return () => {
      disposed = true
      close?.()
      unwatch()
    }
  }, [pageID, revision, realtime, client, attempt])
  return { revoked, error, retry: () => setAttempt(value => value + 1) }
}
