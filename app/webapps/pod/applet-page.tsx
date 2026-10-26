import { t } from 'i18next'
import { Button } from '@ankole/uikit'
import { useQueryClient } from '@tanstack/react-query'
import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { AppletRuntime } from '@ankole/applet-sdk/types'
import { mountApplet } from './applet-host'
import { contentKeys, pageQuery, podRequest, type PageDetail } from './content-api'
import { useContent } from './content-context'
import { ContentError } from './content-primitives'
import { isRealtimeAccessDenied } from './realtime'
import { usePageRealtime } from './use-page-realtime'

export function AppletPage({ detail }: { detail: PageDetail }) {
  const container = useRef<HTMLDivElement>(null)
  const instanceID = useId().replace(/[^a-zA-Z0-9_-]/g, '')
  const { base, realtime, readDenial } = useContent()
  const client = useQueryClient()
  const [error, setError] = useState<unknown>()
  const [retry, setRetry] = useState(0)
  const connection = usePageRealtime(detail.page.id, detail.page.revision)
  const [loadRevoked, setLoadRevoked] = useState(false)
  const revoked = connection.revoked || loadRevoked
  const [loading, setLoading] = useState(true)
  const runtime = useMemo<Omit<AppletRuntime, 'revision' | 'routes'>>(
    () => ({
      pageID: detail.page.id,
      instanceID,
      actions: detail.actions,
      queryClient: client,
      readDenial,
      base,
      get principal() {
        return realtime.principal
      },
      get theme() {
        return document.documentElement.dataset.theme
      },
      pod: { request: podRequest },
      channel(name) {
        return realtime.channel(detail.page.id, name)
      }
    }),
    [detail.page.id, detail.actions, instanceID, client, readDenial, base, realtime]
  )
  // Permissions update the current React tree. Publication revisions own frame lifetimes.
  const latestRuntime = useRef(runtime)
  const mounted = useRef<ReturnType<typeof mountApplet> | null>(null)
  useLayoutEffect(() => {
    latestRuntime.current = runtime
    mounted.current?.update(runtime)
  }, [runtime])
  useEffect(() => {
    if (revoked) return
    let disposed = false
    setError(undefined)
    setLoading(true)
    const applet = mountApplet(
      detail.page.id,
      detail.page.revision,
      container.current!,
      latestRuntime.current,
      error => {
        setLoading(false)
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
    mounted.current = applet
    return () => {
      disposed = true
      mounted.current = null
      applet.dispose()
    }
  }, [detail.page.id, detail.page.revision, instanceID, base, realtime, retry, revoked, client])
  return (
    <section className="min-h-32 text-base leading-normal font-normal">
      <ContentError error={error} />
      {!!error && !revoked && (
        <Button size="sm" variant="outline" onClick={() => setRetry(value => value + 1)}>
          {t('pod.content.reload_applet')}
        </Button>
      )}
      {connection.revoked && (
        <ContentError error={new Error(t('pod.content.you_no_longer_have_access_to_this_applet'))} />
      )}
      {loading && !revoked && <p role="status">{t('pod.content.loading_applet')}</p>}
      {!revoked && <ContentError error={connection.error} retry={connection.retry} />}
      <div ref={container} />
    </section>
  )
}
