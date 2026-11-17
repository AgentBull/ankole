import { Badge, Button, Sheet, SheetContent, SheetHeader, SheetTitle, Skeleton, toast } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { formatDateTime } from '../common/date-time'
import * as api from './api/generated/sdk.gen'
import { contentKeys, type PageDetail } from './content-api'
import { useContent } from './content-context'
import { ContentError, ContentLoading } from './content-primitives'

export type AppletDraft = { id: string; base_revision: number; summary?: string | null; published_by?: string | null }

export function AppletReleases({
  detail,
  preview,
  selectPreview,
  stale,
  historyOpen,
  onHistoryOpenChange
}: {
  detail: PageDetail
  preview: AppletDraft | null
  selectPreview(draft: AppletDraft | null): void
  stale: boolean
  historyOpen: boolean
  onHistoryOpenChange(open: boolean): void
}) {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const { principals } = useContent()
  const pageID = detail.page.id
  const latest = detail.applet_draft
  const draftReplaced = Boolean(preview && (stale || latest?.id !== preview.id))
  const baseSuperseded = Boolean(preview && !draftReplaced && preview.base_revision !== detail.page.revision)
  const draftOutdated = draftReplaced || baseSuperseded
  const showRefreshDraft = draftReplaced && Boolean(latest)
  let outdatedNotice = ''
  if (baseSuperseded) {
    outdatedNotice = t('pod.applet_settings.draft_base_superseded', {
      defaultValue: 'A newer version was published after this draft was created.'
    })
  } else if (latest) {
    outdatedNotice = t('pod.applet_settings.draft_updated')
  } else {
    outdatedNotice = t('pod.applet_settings.draft_closed')
  }

  const revisions = useQuery({
    queryKey: [...contentKeys.page(pageID), 'revisions'],
    queryFn: () => api.podAppletRevisions({ path: { page_id: pageID } }),
    enabled: historyOpen
  })

  const principalsQuery = useQuery({
    queryKey: [...contentKeys.all, 'principals'],
    queryFn: principals,
    enabled: historyOpen
  })
  const principalNames = useMemo(
    () => new Map((principalsQuery.data ?? []).map(item => [item.uid, item.name])),
    [principalsQuery.data]
  )

  const action = useMutation({
    mutationFn: (
      request:
        | { kind: 'promote' | 'discard'; draft: AppletDraft }
        | { kind: 'rollback'; revision: number; base: number }
    ) => {
      if (request.kind === 'rollback') {
        return api.podAppletRollback({
          path: { page_id: pageID },
          body: { data: { target_revision: request.revision, base_revision: request.base } }
        })
      }
      const body = { data: { expected_draft_id: request.draft.id, base_revision: request.draft.base_revision } }
      return request.kind === 'promote'
        ? api.podAppletPromoteDraft({ path: { page_id: pageID }, body })
        : api.podAppletDiscardDraft({ path: { page_id: pageID }, query: body.data })
    },
    onSuccess: async (_result, request) => {
      selectPreview(null)
      if (request.kind === 'rollback') {
        onHistoryOpenChange(false)
        toast.success(t('pod.applet_settings.version_restored', { revision: request.revision }))
      } else if (request.kind === 'promote') {
        toast.success(t('pod.applet_settings.draft_published'))
      } else {
        toast.success(t('pod.applet_settings.draft_discarded'))
      }
      await Promise.all([
        client.invalidateQueries({ queryKey: contentKeys.page(pageID) }),
        client.invalidateQueries({ queryKey: [...contentKeys.page(pageID), 'revisions'] })
      ])
    },
    onError: () => {
      void client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
    }
  })

  if (!preview && !latest && !historyOpen) return null

  return (
    <div className="space-y-2">
      {preview ? (
        <div
          role="status"
          className="space-y-2 rounded-control border border-border-subtle bg-layer-03/40 px-3.5 py-2.5 text-sm">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex min-w-0 flex-wrap items-center gap-2">
              <Badge variant="secondary">{t('pod.applet_settings.previewing_draft')}</Badge>
              {preview.summary && <span className="truncate text-fg-primary">{preview.summary}</span>}
            </div>
            <div className="flex flex-wrap items-center gap-1.5">
              <Button size="xs" variant="outline" onClick={() => selectPreview(null)}>
                {t('pod.applet_settings.return_live')}
              </Button>
              <Button
                size="xs"
                disabled={action.isPending || draftOutdated}
                onClick={() => action.mutate({ kind: 'promote', draft: preview })}>
                {t('pod.applet_settings.publish_draft')}
              </Button>
              <Button
                size="xs"
                variant="ghost"
                disabled={action.isPending || draftReplaced}
                onClick={() => action.mutate({ kind: 'discard', draft: preview })}>
                {t('pod.applet_settings.discard_draft')}
              </Button>
            </div>
          </div>
          {draftOutdated && (
            <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border-subtle pt-2 text-xs text-warning-fg">
              <span>{outdatedNotice}</span>
              {showRefreshDraft && latest ? (
                <Button size="xs" variant="outline" onClick={() => selectPreview(latest)}>
                  {t('pod.applet_settings.refresh_draft')}
                </Button>
              ) : (
                <Button size="xs" variant="outline" onClick={() => selectPreview(null)}>
                  {t('pod.applet_settings.return_live')}
                </Button>
              )}
            </div>
          )}
        </div>
      ) : (
        latest && (
          <div
            role="status"
            className="flex flex-wrap items-center justify-between gap-2 rounded-control border border-border-subtle bg-layer-03/40 px-3.5 py-2.5 text-sm">
            <div className="flex min-w-0 flex-wrap items-center gap-2">
              <Badge variant="outline">{t('pod.applet_settings.draft_ready')}</Badge>
              {latest.summary && <span className="truncate text-fg-secondary">{latest.summary}</span>}
            </div>
            <div className="flex flex-wrap items-center gap-1.5">
              <Button size="xs" variant="outline" onClick={() => selectPreview(latest)}>
                {t('pod.applet_settings.preview_draft')}
              </Button>
              <Button
                size="xs"
                variant="ghost"
                disabled={action.isPending}
                onClick={() => action.mutate({ kind: 'discard', draft: latest })}>
                {t('pod.applet_settings.discard_draft')}
              </Button>
            </div>
          </div>
        )
      )}
      <ContentError error={action.error} />
      <Sheet open={historyOpen} onOpenChange={onHistoryOpenChange}>
        <SheetContent closeLabel={t('common.close')}>
          <SheetHeader className="border-b border-border-subtle px-5 py-4 pr-12">
            <SheetTitle>{t('pod.applet_settings.history')}</SheetTitle>
          </SheetHeader>
          <div className="min-h-0 flex-1 overflow-y-auto px-5 py-2">
            {revisions.isPending && <ContentLoading />}
            <ContentError error={revisions.error} retry={() => void revisions.refetch()} />
            {revisions.data && revisions.data.revisions.length === 0 && (
              <p className="py-6 text-sm text-fg-secondary">{t('pod.applet_settings.no_revisions')}</p>
            )}
            <div className="divide-y divide-border-subtle">
              {revisions.data?.revisions.map(item => {
                const isCurrent = item.revision === detail.page.revision
                return (
                  <div key={item.id} className="space-y-2 py-4">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <div className="flex flex-wrap items-center gap-1.5">
                        <strong className="font-semibold text-fg-primary">v{item.revision}</strong>
                        {isCurrent && <Badge variant="secondary">{t('pod.applet_settings.current_version')}</Badge>}
                        {item.restored_from_revision != null && (
                          <Badge variant="outline">
                            {t('pod.applet_settings.restored_from', { revision: item.restored_from_revision })}
                          </Badge>
                        )}
                      </div>
                      <time dateTime={item.created_at} className="text-xs text-fg-secondary">
                        {formatDateTime(item.created_at, i18n.language)}
                      </time>
                    </div>
                    {item.summary && <p className="text-sm text-fg-primary">{item.summary}</p>}
                    <div className="flex items-center justify-between gap-2 pt-0.5">
                      {item.published_by ? (
                        principalsQuery.isPending ? (
                          <Skeleton className="h-3.5 w-20" />
                        ) : (
                          <span className="truncate text-xs text-fg-secondary">
                            {principalNames.get(item.published_by) ?? item.published_by}
                          </span>
                        )
                      ) : (
                        <span />
                      )}
                      {!isCurrent && (
                        <Button
                          size="xs"
                          variant="outline"
                          disabled={action.isPending}
                          onClick={() =>
                            item.revision &&
                            action.mutate({ kind: 'rollback', revision: item.revision, base: detail.page.revision })
                          }>
                          {t('pod.applet_settings.restore_version')}
                        </Button>
                      )}
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        </SheetContent>
      </Sheet>
    </div>
  )
}
