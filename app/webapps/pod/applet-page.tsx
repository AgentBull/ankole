import * as api from './api/generated/sdk.gen'
import { AppletReleases, type AppletDraft } from './applet-releases'
import { pickAppletElement, type AppletElementSelection } from './applet-elements'
import { openAppletSettings } from './applet-settings-state'
import { Alert, AlertAction, AlertDescription, AlertTitle, Button, toast } from '@ankole/uikit'
import { DismissRegular, ErrorCircleRegular, TargetRegular } from '@ankole/uikit/icons'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useEffectEvent, useId, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { AppletRuntime, AppletRevision, AppletBindings } from '@ankole/applet-sdk/types'
import { mountApplet, readDocumentTheme } from './applet-host'
import { createAppletRuns } from './applet-runs'
import { AppletMissingEnvBanner } from './applet-missing-env-banner'
import { podLocation, principalUID } from '../common/browser-context'
import { requestErrorMessage } from '../common/request-errors'
import { contentKeys, pageAPI, pageQuery, podFileURL, podRequest, type PageDetail } from './content-api'
import { useContent, usePageHost } from './content-context'
import { contentError } from './content-errors'
import { ContentError, ContentLoading } from './content-primitives'
import { isRealtimeAccessDenied } from './realtime'
import { usePageRealtime } from './use-page-realtime'

export function AppletPage({
  detail,
  embedProps,
  embedded = false
}: {
  detail: PageDetail
  embedProps?: Record<string, unknown>
  embedded?: boolean
}) {
  const { t } = useTranslation()
  if (detail.page.deleted_at) {
    return (
      <section className="min-h-32 text-base leading-normal font-normal">
        <div className="content-object px-4 py-6 text-sm text-fg-secondary" role="status">
          {t('pod.content.applet_inactive_in_trash')}
        </div>
      </section>
    )
  }
  return <ActiveAppletPage detail={detail} embedProps={embedProps} embedded={embedded} />
}

function ActiveAppletPage({
  detail,
  embedProps,
  embedded = false
}: {
  detail: PageDetail
  embedProps?: Record<string, unknown>
  embedded?: boolean
}) {
  const { t } = useTranslation()
  const container = useRef<HTMLDivElement>(null)
  const instanceID = useId().replace(/[^a-zA-Z0-9_-]/g, '')
  const { base, realtime, readDenial, principals, pageHref } = useContent()
  const pageHost = usePageHost()
  const client = useQueryClient()
  const [error, setError] = useState<unknown>()
  const [retry, setRetry] = useState(0)
  const [preview, setPreview] = useState<AppletDraft | null>(null)
  const [draftStale, setDraftStale] = useState(false)
  const [historyOpen, setHistoryOpen] = useState(false)
  const [picking, setPicking] = useState(false)
  const [picked, setPicked] = useState<AppletElementSelection | null>(null)
  const draft = useQuery({
    queryKey: [...contentKeys.page(detail.page.id), 'draft', preview?.id, detail.bindings_digest],
    queryFn: () => api.podAppletDraft({ path: { page_id: detail.page.id, draft_id: preview!.id } }),
    placeholderData: prev => (prev?.draft.id === preview?.id ? prev : undefined),
    enabled: !!preview
  })
  const revision: AppletRevision = preview ? `draft:${preview.id}` : detail.page.revision
  const bindings = (preview ? draft.data?.bindings : detail.bindings) as AppletBindings | undefined
  const bindingsDigest = preview ? draft.data?.bindings_digest : detail.bindings_digest
  const canEdit = detail.actions.includes('node_edit')
  const canComment = detail.actions.includes('node_comment')
  useLayoutEffect(() => {
    if (!canEdit) {
      setPreview(null)
      setHistoryOpen(false)
    }
    if (!canEdit && !canComment) {
      setPicked(null)
      setPicking(false)
    }
  }, [canEdit, canComment])
  const missing = Object.entries(bindings ?? {}).filter(
    ([, binding]) => binding.status === 'missing_fields' || (binding.required && binding.status !== 'ready')
  )
  const selectPreview = (value: AppletDraft | null) => {
    setPreview(value)
    setDraftStale(false)
    setPicked(null)
    setPicking(false)
    setLoading(true)
    setRetry(current => current + 1)
  }
  const connection = usePageRealtime(detail.page.id, detail.page.revision)
  const [loadRevoked, setLoadRevoked] = useState(false)
  const revoked = connection.revoked || loadRevoked
  const [loading, setLoading] = useState(true)
  const [ready, setReady] = useState(false)
  const claimOwner = useMutation({
    mutationFn: (uid: string) => pageAPI.claimAppletOwner(detail.page.id, uid),
    onSuccess: async () => {
      toast.success(t('pod.content.applet_ownership_claimed'))
      await client.invalidateQueries({ queryKey: contentKeys.page(detail.page.id) })
    },
    onError: err => toast.error(requestErrorMessage(contentError(err)))
  })
  const callerUID = realtime.principal?.uid ?? principalUID()
  const canClaimOwnership =
    Boolean(detail.applet_owner?.continuity_active) && Boolean(detail.applet_owner?.can_claim) && Boolean(callerUID)
  const runtime = useMemo<Omit<AppletRuntime, 'revision' | 'routes' | 'embedded'>>(
    () => ({
      pageID: detail.page.id,
      title: detail.page.title,
      instanceID,
      actions: detail.actions,
      bindings,
      bindingsDigest,
      embedProps,
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
      pod: {
        request: podRequest,
        fileURL: target => podFileURL(detail.page.id, target),
        navigateToPage(targetPageID) {
          const trimmed = targetPageID.trim()
          if (!trimmed) return
          if (pageHost) pageHost.navigateToPage(trimmed)
          else if (typeof window !== 'undefined') window.location.assign(podLocation(pageHref(trimmed)).pathname)
        },
        openChat(options) {
          pageHost?.openChat(options)
        },
        principalsKey: [...contentKeys.all, 'principals'],
        principals
      },
      channel(name) {
        return realtime.channel(detail.page.id, name)
      }
    }),
    [
      detail.page.id,
      detail.page.title,
      detail.actions,
      bindings,
      bindingsDigest,
      embedProps,
      instanceID,
      client,
      readDenial,
      base,
      realtime,
      pageHost,
      principals,
      pageHref
    ]
  )
  // Permissions update the current React tree. Publication revisions own frame lifetimes.
  const latestRuntime = useRef(runtime)
  const mounted = useRef<ReturnType<typeof mountApplet> | null>(null)
  useLayoutEffect(() => {
    latestRuntime.current = runtime
    mounted.current?.update(runtime)
  }, [runtime])
  useEffect(() => {
    if (revoked || (preview && !draft.data)) return
    let disposed = false
    setError(undefined)
    setLoading(true)
    setReady(false)
    const applet = mountApplet(
      detail.page.id,
      revision,
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
        if (preview) {
          setDraftStale(true)
          setLoading(false)
          setReady(false)
        } else setLoading(true)
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
  }, [detail.page.id, revision, instanceID, base, realtime, retry, revoked, client, !!draft.data])
  const anchorRevision = typeof revision === 'number' ? revision : detail.page.revision
  useEffect(() => {
    if (!picking || !ready || !mounted.current) return
    return pickAppletElement(
      mounted.current.frame,
      anchorRevision,
      selection => {
        setPicked(selection)
        setPicking(false)
      },
      () => setPicking(false)
    )
  }, [picking, ready, anchorRevision])
  const startPick = useEffectEvent(() => {
    setPicked(null)
    setPicking(true)
  })
  const togglePick = useEffectEvent(() => {
    setPicked(null)
    setPicking(value => !value)
  })
  const openHistory = useEffectEvent(() => setHistoryOpen(true))
  useEffect(() => {
    if (embedded || revoked || !pageHost?.registerAppletSession) return
    return pageHost.registerAppletSession({
      picking,
      startPick: () => startPick(),
      togglePick: () => togglePick(),
      openHistory: () => openHistory()
    })
  }, [embedded, revoked, pageHost, picking])
  const isFrameLoading = (loading || (Boolean(preview) && draft.isPending)) && !revoked && !draft.error
  const pickedSummary =
    picked &&
    ([picked.anchor.component.split(' > ').at(-1), picked.anchor.source].filter(Boolean).join(' · ') || picked.quote)
  return (
    <section
      data-applet-stage
      className="min-h-32 text-base leading-normal font-normal [&:fullscreen]:overflow-auto [&:fullscreen]:bg-page">
      {/* The stage starts at the Page body's edges, so its notices keep their own spacing. */}
      <div data-applet-notices className={`space-y-3 py-4 empty:hidden${embedded ? ' px-4' : ''}`}>
        {!embedded && !revoked && canEdit && (
          <AppletReleases
            detail={detail}
            preview={preview}
            selectPreview={selectPreview}
            stale={draftStale}
            historyOpen={historyOpen}
            onHistoryOpenChange={setHistoryOpen}
          />
        )}
        {!embedded && !revoked && (picking || picked) && (canEdit || canComment) && (
          <div
            role="status"
            className="flex flex-wrap items-center justify-between gap-2 rounded-control border border-border-subtle bg-layer-03/40 px-3 py-2 text-sm">
            {picking ? (
              <>
                <span className="inline-flex items-center gap-2 text-fg-secondary">
                  <TargetRegular aria-hidden className="size-4 text-primary" />
                  {t('pod.applet_settings.pick_hint')}
                </span>
                <Button size="xs" variant="outline" onClick={() => setPicking(false)}>
                  {t('pod.applet_settings.cancel_pick')}
                </Button>
              </>
            ) : (
              picked && (
                <>
                  <span className="max-w-72 truncate font-mono text-xs text-fg-secondary">{pickedSummary}</span>
                  <div className="flex flex-wrap items-center gap-1.5">
                    {canEdit && (
                      <Button
                        size="xs"
                        variant="outline"
                        onClick={() => {
                          const lines = [
                            t('pod.applet_settings.modify_element'),
                            `Page: ${detail.page.id}`,
                            preview
                              ? `Draft: ${preview.id} (base v${preview.base_revision})`
                              : `Revision: ${picked.anchor.revision}`,
                            picked.anchor.component ? `Component: ${picked.anchor.component}` : '',
                            picked.anchor.source ? `Source: ${picked.anchor.source}` : '',
                            picked.quote ? `Text: ${picked.quote}` : ''
                          ].filter(Boolean)
                          pageHost?.openChat({
                            quote: picked.quote,
                            prompt: lines.join('\n')
                          })
                          setPicked(null)
                        }}>
                        {t('pod.applet_settings.send_to_chat')}
                      </Button>
                    )}
                    {!preview && canComment && (
                      <Button
                        size="xs"
                        variant="outline"
                        onClick={() => {
                          pageHost?.commentOnElement?.(picked)
                          setPicked(null)
                        }}>
                        {t('pod.applet_settings.comment_here')}
                      </Button>
                    )}
                    <Button
                      size="xs"
                      variant="ghost"
                      onClick={() => {
                        setPicked(null)
                        setPicking(true)
                      }}>
                      {t('pod.applet_settings.pick_element')}
                    </Button>
                    <Button
                      size="icon-xs"
                      variant="ghost"
                      aria-label={t('common.close')}
                      title={t('common.close')}
                      onClick={() => setPicked(null)}>
                      <DismissRegular aria-hidden />
                    </Button>
                  </div>
                </>
              )
            )}
          </div>
        )}
        {!revoked && missing.length > 0 && (
          <Alert variant="warning" className="rounded-lg">
            <ErrorCircleRegular aria-hidden />
            <AlertTitle>{t('pod.applet_settings.missing_bindings_title')}</AlertTitle>
            <AlertDescription>
              {canEdit
                ? t('pod.applet_settings.missing_bindings', { slots: missing.map(([slot]) => slot).join(', ') })
                : t('pod.applet_settings.missing_bindings_viewer')}
            </AlertDescription>
            {canEdit && (
              <AlertAction>
                <Button
                  type="button"
                  size="xs"
                  variant="outline"
                  onClick={() => {
                    if (!openAppletSettings(detail.page.id, { tab: 'bindings' })) {
                      pageHost?.navigateToPage(detail.page.id)
                    }
                  }}>
                  {t('pod.applet_settings.tab_bindings')}
                </Button>
              </AlertAction>
            )}
          </Alert>
        )}
        <ContentError error={draft.error} />
        {!revoked && detail.applet_owner?.continuity_active && (
          <div
            role="status"
            className="flex flex-wrap items-center justify-between gap-3 rounded-control border border-border-subtle bg-layer-03/50 px-3.5 py-2.5 text-sm text-fg-primary">
            <span>{t('pod.content.applet_continuity_banner')}</span>
            {canClaimOwnership && callerUID ? (
              <Button
                type="button"
                size="xs"
                variant="outline"
                disabled={claimOwner.isPending}
                onClick={() => claimOwner.mutate(callerUID)}>
                {t('pod.content.applet_claim_ownership')}
              </Button>
            ) : null}
          </div>
        )}
        {!revoked && <AppletMissingEnvBanner detail={detail} />}
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
        {isFrameLoading && (
          <ContentLoading
            label={t('pod.content.loading_applet')}
            className="pointer-events-none absolute inset-0 z-10"
            immediate
          />
        )}
        <div ref={container} hidden={(!ready && !!(error || draft.error)) || revoked} />
      </div>
    </section>
  )
}
