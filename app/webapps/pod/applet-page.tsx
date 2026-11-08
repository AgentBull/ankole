import { Button } from '@ankole/uikit'
import { RiFlashlightLine } from '@remixicon/react'
import { useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { AppletRuntime } from '@ankole/applet-sdk/types'
import { mountApplet, readDocumentTheme } from './applet-host'
import { createAppletRuns } from './applet-runs'
import { contentKeys, pageQuery, podRequest, type PageDetail } from './content-api'
import { useContent } from './content-context'
import { ContentError, ContentLoading } from './content-primitives'
import { isRealtimeAccessDenied } from './realtime'
import { automationJobID } from './state/connectors'
import { usePageRealtime } from './use-page-realtime'

const AppletAutomationDialog = lazy(() =>
  import('./applet-automation').then(module => ({ default: module.AppletAutomationDialog }))
)

/** The Applet's automation entry in the Page header; it opens the automation dialog, also when a link names a job. */
export function AppletAutomationControl({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(
    () => typeof window !== 'undefined' && automationJobID(new URLSearchParams(window.location.search)) !== undefined
  )
  const [everOpened, setEverOpened] = useState(open)
  return (
    <>
      <Button
        variant="ghost"
        size="sm"
        onClick={() => {
          setEverOpened(true)
          setOpen(true)
        }}>
        <RiFlashlightLine aria-hidden className="size-4" />
        <span className="@max-[640px]:sr-only">{t('pod.automation.title')}</span>
      </Button>
      {everOpened && (
        <Suspense fallback={null}>
          <AppletAutomationDialog detail={detail} open={open} onOpenChange={setOpen} />
        </Suspense>
      )}
    </>
  )
}

export function AppletPage({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
  if (detail.page.deleted_at) {
    return (
      <section className="min-h-32 text-base leading-normal font-normal">
        <div className="content-object px-4 py-6 text-sm text-muted-foreground" role="status">
          {t('pod.content.applet_inactive_in_trash')}
        </div>
      </section>
    )
  }
  return <ActiveAppletPage detail={detail} />
}

function ActiveAppletPage({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
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
  const [ready, setReady] = useState(false)
  const runtime = useMemo<Omit<AppletRuntime, 'revision' | 'routes'>>(
    () => ({
      pageID: detail.page.id,
      instanceID,
      actions: detail.actions,
      queryClient: client,
      readDenial,
      base,
      runs: createAppletRuns(client, realtime, detail.page.id),
      get principal() {
        return realtime.principal
      },
      get theme() {
        return readDocumentTheme()
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
    setReady(false)
    const applet = mountApplet(
      detail.page.id,
      detail.page.revision,
      container.current!,
      latestRuntime.current,
      error => {
        setLoading(false)
        setError(error)
      },
      () => {
        setLoading(false)
        setReady(true)
      },
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
    <section
      data-applet-stage
      className="min-h-32 text-base leading-normal font-normal [&:fullscreen]:overflow-auto [&:fullscreen]:bg-background">
      {/* The stage starts at the Page body's edges, so its notices keep their own spacing. */}
      <div data-applet-notices className="space-y-3 py-4 empty:hidden">
        <ContentError error={error} />
        {!!error && !revoked && (
          <Button size="sm" variant="outline" onClick={() => setRetry(value => value + 1)}>
            {t('pod.content.reload_applet')}
          </Button>
        )}
        {connection.revoked && (
          <ContentError error={new Error(t('pod.content.you_no_longer_have_access_to_this_applet'))} />
        )}
        {!revoked && <ContentError error={connection.error} retry={connection.retry} />}
      </div>
      <div className="relative">
        {loading && !revoked && (
          <ContentLoading
            label={t('pod.content.loading_applet')}
            className="pointer-events-none absolute inset-0 z-10"
            immediate
          />
        )}
        <div ref={container} hidden={(!ready && !!error) || revoked} />
      </div>
    </section>
  )
}
