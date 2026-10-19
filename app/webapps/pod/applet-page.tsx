import { t } from 'i18next'
import { Button } from '@ankole/uikit'
import { useQueryClient } from '@tanstack/react-query'
import { useEffect, useId, useMemo, useRef, useState } from 'react'
import type { AppletRuntime, EphemeralChannel } from '@ankole/applet-sdk/types'
import { mountApplet } from './applet-host'
import { contentKeys, pageQuery, podRequest, type PageDetail } from './content-api'
import { useContent } from './content-context'
import { ContentError } from './content-primitives'
import { isRealtimeAccessDenied } from './realtime'
import { usePageRealtime } from './use-page-realtime'

export function AppletPage({ detail }: { detail: PageDetail }) {
  const container = useRef<HTMLDivElement>(null)
  const instanceID = useId().replace(/[^a-zA-Z0-9_-]/g, '')
  const { database, realtime } = useContent()
  const client = useQueryClient()
  const [error, setError] = useState<unknown>()
  const [retry, setRetry] = useState(0)
  const connection = usePageRealtime(detail.page.id, detail.page.revision)
  const [loadRevoked, setLoadRevoked] = useState(false)
  const revoked = connection.revoked || loadRevoked
  const [loading, setLoading] = useState(true)
  const channels = useRef(new Set<EphemeralChannel>())
  const runtime = useMemo<Omit<AppletRuntime, 'revision' | 'routes'>>(
    () => ({
      pageID: detail.page.id,
      instanceID,
      queryClient: client,
      database,
      get principal() {
        return realtime.principal
      },
      get theme() {
        return document.documentElement.dataset.theme
      },
      pod: { request: podRequest },
      channel(name) {
        const channel = realtime.channel(detail.page.id, name)
        let closed = false
        const tracked: EphemeralChannel = {
          ...channel,
          close() {
            if (closed) return
            closed = true
            channels.current.delete(tracked)
            channel.close()
          }
        }
        channels.current.add(tracked)
        return tracked
      }
    }),
    [detail.page.id, instanceID, client, database, realtime]
  )
  useEffect(() => {
    if (revoked) return
    let disposed = false
    setError(undefined)
    setLoading(true)
    const unmount = mountApplet(
      detail.page.id,
      instanceID,
      container.current!,
      runtime,
      error => {
        setLoading(false)
        if (isRealtimeAccessDenied(error)) setLoadRevoked(true)
        setError(error)
      },
      () => setLoading(false),
      async () => {
        if (disposed) return
        setLoading(true)
        try {
          await client.cancelQueries({ queryKey: contentKeys.page(detail.page.id), exact: true })
          if (disposed) return
          await client.fetchQuery({ ...pageQuery(detail.page.id), staleTime: 0 })
        } catch (error) {
          if (disposed) return
          setLoading(false)
          if (isRealtimeAccessDenied(error)) setLoadRevoked(true)
          setError(error)
        }
      }
    )
    return () => {
      disposed = true
      unmount()
      for (const channel of channels.current) channel.close()
      channels.current.clear()
    }
  }, [detail.page.id, detail.page.revision, instanceID, runtime, retry, revoked, client])
  return (
    <section className="min-h-32 text-base leading-normal font-normal">
      <div ref={container} />
      {connection.revoked && (
        <ContentError error={new Error(t('pod.content.you_no_longer_have_access_to_this_applet'))} />
      )}
      {loading && !revoked && <p role="status">{t('pod.content.loading_applet')}</p>}
      <ContentError error={error} />
      {!revoked && <ContentError error={connection.error} retry={connection.retry} />}
      {!!error && !revoked && (
        <Button size="sm" variant="outline" onClick={() => setRetry(value => value + 1)}>
          {t('pod.content.reload_applet')}
        </Button>
      )}
    </section>
  )
}
