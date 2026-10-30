import { Badge, Button, Dialog, DialogContent, DialogFooter, DialogTitle } from '@ankole/uikit'
import { RiCloseLine, RiDownloadLine, RiHistoryLine } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { ErrorBoundary } from '../common/error-boundary'
import { contentKeys, pageAPI, pageHistoryQuery, pageSnapshotQuery, type PageDetail } from './content-api'
import { ContentError } from './content-primitives'
import { DocumentHistoryPreview } from './document-history-preview'
import { PageIcon } from './page-icon'
import { isRealtimeAccessDenied } from './realtime'
import { downloadDocument } from './state/document-export'
import { versionTime } from './state/document-history'
import { updatePageMetadata, refreshDirectories } from './state/navigation-cache'
import type { PageDraftModel } from './state/page-draft'

/** The live editor stays mounted while a historical document is inspected. */
export function DocumentHistory({
  detail,
  draft,
  close,
  returnFocus
}: {
  detail: PageDetail
  draft: InstanceType<typeof PageDraftModel>
  close(): void
  returnFocus: RefObject<HTMLButtonElement | null>
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const history = useInfiniteQuery(pageHistoryQuery(detail.page.id))
  const [selected, select] = useState('current')
  const [compare, setCompare] = useState(false)
  const entryID = selected === 'current' ? undefined : selected
  const entry = useQuery({ ...pageSnapshotQuery(detail.page.id, entryID ?? ''), enabled: !!entryID })
  const denied = isRealtimeAccessDenied(history.error) || isRealtimeAccessDenied(entry.error)
  const entries = denied ? [] : (history.data?.pages.flatMap(page => page.snapshots) ?? [])
  const snapshot = denied ? undefined : entry.data?.snapshot
  const preview = denied
    ? undefined
    : selected === 'current'
      ? { id: 'current', content: draft.xml.value, title: draft.title.value, icon: detail.page.icon }
      : snapshot
  const [confirmation, confirm] = useState<{
    snapshotID: string
    base_revision: number
    updated_at: string
  }>()
  const prepareRestore = useMutation({
    mutationFn: (_snapshotID: string) => pageAPI.history(detail.page.id),
    onSuccess: (current, snapshotID) => {
      if (!draft.hasUnsavedChanges.value) {
        confirm({ snapshotID, base_revision: current.current_revision, updated_at: current.current_updated_at })
      }
    }
  })
  const restore = useMutation({
    mutationFn: ({ snapshotID, ...body }: NonNullable<typeof confirmation>) =>
      pageAPI.restoreSnapshot(detail.page.id, snapshotID, body),
    onSuccess: async ({ page }) => {
      updatePageMetadata(client, { id: page.id, title: page.title, icon: page.icon })
      await Promise.all([
        client.invalidateQueries({ queryKey: contentKeys.page(page.id) }),
        refreshDirectories(client, [])
      ])
      close()
    },
    onError: () => {
      confirm(undefined)
      void client.invalidateQueries({ queryKey: contentKeys.page(detail.page.id) })
    }
  })
  const date = (value: string) =>
    new Intl.DateTimeFormat(i18n.language, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
  const exportSnapshot = useMutation({
    mutationFn: () =>
      downloadDocument(client, {
        pageID: detail.page.id,
        xml: preview!.content,
        title: preview!.title,
        icon: preview!.icon
      })
  })
  return (
    <Dialog open onOpenChange={open => !open && !restore.isPending && close()}>
      <DialogContent
        className="pod-document-history flex h-[min(900px,calc(100dvh-2rem))] max-h-[calc(100dvh-2rem)]! w-[min(1200px,calc(100vw-2rem))]! max-w-none sm:max-w-none flex-col gap-0! overflow-hidden! p-0!"
        showCloseButton={false}
        finalFocus={returnFocus}>
        <header className="flex shrink-0 items-center justify-between gap-3 border-b border-border px-4 py-3">
          <DialogTitle>
            <RiHistoryLine aria-hidden className="inline size-4 mr-2" />
            {t('pod.document.history')}
          </DialogTitle>
          <Button
            size="icon-sm"
            variant="ghost"
            aria-label={t('common.close')}
            disabled={restore.isPending}
            onClick={close}>
            <RiCloseLine aria-hidden />
          </Button>
        </header>
        <ErrorBoundary variant="panel" className="m-4" resetKeys={[detail.page.id, selected, compare]}>
          <div className="flex min-h-0 flex-1 flex-col min-[761px]:flex-row">
            <section
              className="pod-document-history-preview min-w-0 flex-1 overflow-auto p-5 min-[761px]:px-10 min-[761px]:py-8"
              aria-label={t('pod.document.version_preview')}>
              {entry.isPending && entryID && <p role="status">{t('pod.content.loading')}</p>}
              <ContentError error={entry.error} retry={() => void entry.refetch()} />
              {preview && !entry.error && (
                <>
                  <div className="pod-page-heading">
                    {preview.icon && (
                      <div className="pod-page-title-icon">
                        <PageIcon page={{ type: 'doc', icon: preview.icon }} />
                      </div>
                    )}
                    <h1 className="pod-page-title">{preview.title || t('pod.content.untitled')}</h1>
                  </div>
                  <p className="pod-page-save-state">
                    {snapshot
                      ? `${date(versionTime(snapshot))} · ${snapshot.author.name || snapshot.author.principal_uid}`
                      : t('pod.document.current_version')}
                  </p>
                  {snapshot && (
                    <div className="mb-4 space-y-3">
                      <p className="text-xs text-fg-tertiary">
                        {t('pod.document.content_modified_at', { time: date(snapshot.document_updated_at) })}
                        {' · '}
                        {t('pod.document.checkpoint_saved_at', { time: date(snapshot.created_at) })}
                      </p>
                      <Button
                        size="sm"
                        variant="outline"
                        className="aria-pressed:bg-selection"
                        aria-pressed={compare}
                        onClick={() => setCompare(value => !value)}>
                        {t('pod.document.compare_current')}
                      </Button>
                    </div>
                  )}
                  <ErrorBoundary variant="panel" resetKeys={[detail.page.id, preview.id, compare]}>
                    <DocumentHistoryPreview
                      editorKey={preview.id === 'current' ? `current:${draft.revision.value}` : preview.id}
                      pageID={detail.page.id}
                      version={preview}
                      current={{ content: draft.xml.value, title: draft.title.value, icon: detail.page.icon }}
                      compare={!!snapshot && compare}
                    />
                  </ErrorBoundary>
                </>
              )}
            </section>
            <aside
              className="pod-document-history-list flex max-h-[35%] w-full shrink-0 flex-col gap-2 overflow-auto border-t border-border p-4 min-[761px]:max-h-none min-[761px]:w-[250px] min-[761px]:border-t-0 min-[761px]:border-l"
              aria-label={t('pod.document.versions')}>
              <p className="text-xs text-fg-tertiary">{t('pod.document.history_cadence')}</p>
              <Button
                variant="ghost"
                className="h-auto flex-col items-start whitespace-normal text-start aria-pressed:bg-selection"
                aria-pressed={selected === 'current'}
                disabled={denied || prepareRestore.isPending || restore.isPending}
                onClick={() => {
                  select('current')
                  confirm(undefined)
                  restore.reset()
                }}>
                {t('pod.document.current_version')}
              </Button>
              {history.isPending && <p role="status">{t('pod.content.loading')}</p>}
              <ContentError error={history.error} retry={() => void history.refetch()} />
              {!history.isPending && !history.error && !entries.length && <p>{t('pod.document.no_history')}</p>}
              {entries.map(item => (
                <Button
                  key={item.id}
                  variant="ghost"
                  className="h-auto flex-col items-start whitespace-normal text-start aria-pressed:bg-selection"
                  aria-pressed={entryID === item.id}
                  disabled={prepareRestore.isPending || restore.isPending}
                  onClick={() => {
                    select(item.id)
                    confirm(undefined)
                    restore.reset()
                  }}>
                  <time dateTime={versionTime(item)}>{date(versionTime(item))}</time>
                  <span className="flex min-w-0 flex-wrap items-center gap-2 [overflow-wrap:anywhere]">
                    {item.author.name || item.author.principal_uid}
                    {item.author.kind === 'agent' && (
                      <Badge variant="secondary">{t('pod.document.agent_author')}</Badge>
                    )}
                  </span>
                  <span className="text-xs text-fg-tertiary">{t(`pod.document.version_${item.reason}`)}</span>
                </Button>
              ))}
              {!denied && history.hasNextPage && (
                <Button
                  variant="ghost"
                  disabled={history.isFetchingNextPage}
                  onClick={() => void history.fetchNextPage()}>
                  {t('pod.document.load_more')}
                </Button>
              )}
            </aside>
          </div>
        </ErrorBoundary>
        <div className="flex flex-wrap items-center justify-end gap-3 border-t border-border px-4 py-3">
          <ContentError error={restore.error} />
          <ContentError error={prepareRestore.error} />
          <ContentError error={exportSnapshot.error} />
          {draft.hasUnsavedChanges.value && (
            <p role="status" className="text-xs">
              {t('pod.document.wait_for_save')}
            </p>
          )}
          <Button
            variant="outline"
            disabled={!preview || exportSnapshot.isPending}
            onClick={() => exportSnapshot.mutate()}>
            <RiDownloadLine aria-hidden />
            {t('pod.document.export_version')}
          </Button>
          <Button
            disabled={!snapshot || draft.hasUnsavedChanges.value || restore.isPending || prepareRestore.isPending}
            onClick={() => snapshot && prepareRestore.mutate(snapshot.id)}>
            {t('pod.document.restore_version')}
          </Button>
        </div>
        <Dialog
          open={!!confirmation && !denied}
          onOpenChange={open => !open && !restore.isPending && confirm(undefined)}>
          <DialogContent className="pod-dialog" closeLabel={t('common.close')}>
            <DialogTitle>{t('pod.document.restore_version')}</DialogTitle>
            <p>{t('pod.document.restore_description')}</p>
            <DialogFooter>
              <Button variant="outline" disabled={restore.isPending} onClick={() => confirm(undefined)}>
                {t('common.cancel')}
              </Button>
              <Button
                disabled={restore.isPending || draft.hasUnsavedChanges.value}
                onClick={() => confirmation && restore.mutate(confirmation)}>
                {t('pod.document.restore_version')}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </DialogContent>
    </Dialog>
  )
}
