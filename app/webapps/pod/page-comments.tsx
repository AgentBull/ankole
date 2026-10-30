import type { EditorHandle } from '@ankole/block-editor'
import {
  Button,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Sheet,
  SheetContent,
  SheetTitle
} from '@ankole/uikit'
import { RiCloseLine } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useQueries, useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useSyncExternalStore, useRef, useState, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { ErrorBoundary } from '../common/error-boundary'
import {
  contentKeys,
  pageAPI,
  pageCommentsQuery,
  pageCommentQuery,
  pageCommentSummaryQuery,
  type PageDetail
} from './content-api'
import { ContentError } from './content-primitives'
import { CommentThread, CommentComposer } from './comment-thread'
import { isRealtimeAccessDenied } from './realtime'
import type { PageCommentsModel } from './state/page-comments'
import type { PageDraftModel } from './state/page-draft'
import { PodPanelSurface, type PanelInputEvent } from './panel-motion'

type Comments = InstanceType<typeof PageCommentsModel>
const noSubscription = () => () => {}
const noEditor = () => null

export function PageComments({
  detail,
  draft,
  editor,
  model,
  mobile,
  focused,
  selectedThreads,
  clearSelection,
  focus,
  close,
  returnFocus,
  selectAnchor,
  reveal
}: {
  detail: PageDetail
  draft: InstanceType<typeof PageDraftModel>
  editor: EditorHandle | null
  model: Comments
  mobile: boolean
  focused: string | null
  selectedThreads: readonly string[]
  clearSelection(): void
  focus(id: string | null): void
  close(event?: PanelInputEvent): void
  returnFocus: RefObject<HTMLButtonElement | null>
  selectAnchor(threadID?: string): void
  reveal(id: string): HTMLElement | null
}) {
  useSignals()
  const { t } = useTranslation()
  const client = useQueryClient()
  const [status, setStatus] = useState<'open' | 'resolved' | 'all' | 'unread'>('open')
  const effectiveStatus = focused || selectedThreads.length ? 'all' : status
  const requestedIDs = selectedThreads.length ? selectedThreads : focused ? [focused] : []
  const summary = useQuery(pageCommentSummaryQuery(detail.page.id))
  const query = useInfiniteQuery({
    ...pageCommentsQuery(detail.page.id, effectiveStatus),
    enabled: !selectedThreads.length
  })
  const requested = useQueries({ queries: requestedIDs.map(id => pageCommentQuery(detail.page.id, id)) })
  const listedThreads = query.data?.pages.flatMap(page => page.threads) ?? []
  const directThreads = requested.flatMap(result => (result.data ? [result.data.thread] : []))
  const visibleThreads = selectedThreads.length
    ? directThreads
    : [...directThreads.filter(thread => !listedThreads.some(item => item.id === thread.id)), ...listedThreads]
  const revisions = [
    ...(!selectedThreads.length && query.data ? [query.data.pages[0]!.revision] : []),
    ...requested.flatMap(result => (result.data ? [result.data.revision] : []))
  ]
  const listedRevision = revisions.length ? Math.min(...revisions) : undefined
  const documentRevision = draft.revision.value
  useEffect(() => {
    if (listedRevision !== undefined && listedRevision < documentRevision) {
      void client.invalidateQueries({ queryKey: contentKeys.comments(detail.page.id) })
    }
  }, [listedRevision, documentRevision, client, detail.page.id])
  const loading = (!selectedThreads.length && query.isPending) || requested.some(result => result.isPending)
  const error = requested.find(result => result.error)?.error ?? (!selectedThreads.length ? query.error : null)
  const retry = () => {
    if (!selectedThreads.length) void query.refetch()
    requested.forEach(result => void result.refetch())
  }
  const denied = isRealtimeAccessDenied(error)
  const canComment = detail.actions.includes('page_comment') && !denied
  const anchor = model.anchor.value
  const editorState = useSyncExternalStore(editor?.subscribe ?? noSubscription, editor?.drawn ?? noEditor)
  const selection = useMemo(() => (editorState ? (anchor?.read?.(editorState) ?? null) : null), [anchor, editorState])
  const content = useRef<HTMLDivElement>(null)
  const revealOnClose = useRef<string | null>(null)
  const locate = (id: string) => {
    if (mobile) {
      revealOnClose.current = id
      close()
    } else reveal(id)
  }
  const refresh = () => client.invalidateQueries({ queryKey: contentKeys.page(detail.page.id) })
  const acknowledge = useMutation({
    mutationFn: (through: string) => pageAPI.readComments(detail.page.id, through),
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.comments(detail.page.id) })
  })
  useEffect(() => {
    if (focused) {
      content.current?.querySelector<HTMLElement>(`[data-thread-id="${focused}"]`)?.scrollIntoView({ block: 'nearest' })
    }
  }, [focused, visibleThreads.length])
  const confirmedSelection = () => {
    const range = editor ? model.anchor.value?.read?.(editor.editor.state) : null
    if (!range) throw new Error(t('pod.document.reselect_quote'))
    if (!draft.bodyReady.value) throw new Error(t('pod.document.wait_for_save'))
    return { base_revision: draft.revision.value, from: range.from, to: range.to }
  }
  const add = async (body: string) => {
    const anchor = model.anchor.value
    const selection = anchor ? confirmedSelection() : undefined
    const result = await pageAPI.comment(detail.page.id, { body, ...selection })
    model.sent('new', body, anchor)
    clearSelection()
    focus(result.comment.id)
    await refresh()
  }
  const body = (
    <>
      <header className="pod-comments-header sheet-header gap-1">
        <h2 className="sheet-title">{t('pod.document.comments')}</h2>
        <Select
          value={effectiveStatus}
          onValueChange={value => {
            if (value === 'open' || value === 'resolved' || value === 'all' || value === 'unread') {
              focus(null)
              clearSelection()
              setStatus(value)
            }
          }}>
          <SelectTrigger size="sm" variant="ghost" aria-label={t('pod.document.comment_status')}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="unread">{t('pod.document.unread_comments')}</SelectItem>
            <SelectItem value="open">{t('pod.document.open_comments')}</SelectItem>
            <SelectItem value="resolved">{t('pod.document.resolved_comments')}</SelectItem>
            <SelectItem value="all">{t('pod.document.all_comments')}</SelectItem>
          </SelectContent>
        </Select>
        <Button size="icon-xs" variant="ghost" aria-label={t('common.close')} onClick={close}>
          <RiCloseLine aria-hidden />
        </Button>
      </header>
      <ErrorBoundary variant="panel" className="m-4" resetKeys={[detail.page.id, focused, effectiveStatus]}>
        {!!summary.data?.unread_count && (
          <div className="flex shrink-0 items-center justify-between gap-2 border-b border-border px-4 py-2 text-xs">
            <Button
              variant="ghost"
              size="xs"
              onClick={() => {
                focus(null)
                clearSelection()
                setStatus('unread')
              }}>
              {t('pod.document.unread_comments')} · {summary.data.unread_count}
            </Button>
            <Button
              variant="ghost"
              size="xs"
              disabled={acknowledge.isPending || !summary.data.activity_at}
              onClick={() => summary.data?.activity_at && acknowledge.mutate(summary.data.activity_at)}>
              {t('pod.document.mark_comments_read')}
            </Button>
          </div>
        )}
        {!!selectedThreads.length && (
          <div className="flex shrink-0 items-center justify-between gap-2 border-b border-border px-4 py-2 text-xs">
            <span>
              {t('pod.document.comments_here')} · {selectedThreads.length}
            </span>
            <Button variant="ghost" size="xs" onClick={clearSelection}>
              {t('pod.document.all_comments')}
            </Button>
          </div>
        )}
        <div ref={content} className="pod-comments-threads min-h-0 flex-1 overflow-auto p-4">
          {loading && <p role="status">{t('pod.content.loading')}</p>}
          <ContentError error={error} retry={retry} />
          <ContentError error={acknowledge.error} />
          {!loading && !error && !visibleThreads.length && (
            <p className="text-sm text-fg-tertiary">{t('pod.document.no_comments')}</p>
          )}
          {!denied &&
            visibleThreads.map(thread => (
              <ErrorBoundary key={thread.id} variant="inline" className="mb-3" resetKeys={[thread.id, thread.version]}>
                <CommentThread
                  pageID={detail.page.id}
                  thread={thread}
                  model={model}
                  canComment={canComment}
                  focused={focused === thread.id}
                  unread={thread.unread}
                  hasSelection={!!selection}
                  anchorPending={!!selection && !draft.bodyReady.value}
                  refresh={refresh}
                  reveal={() => locate(thread.id)}
                  selectAnchor={() => selectAnchor(thread.id)}
                  reanchor={async () => {
                    const anchor = model.anchor.value
                    await pageAPI.anchorComment(detail.page.id, thread.id, {
                      ...confirmedSelection(),
                      version: thread.version
                    })
                    if (model.anchor.value === anchor) model.capture(null)
                    await refresh()
                  }}
                />
              </ErrorBoundary>
            ))}
          {!selectedThreads.length && query.hasNextPage && (
            <Button variant="ghost" disabled={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()}>
              {t('pod.document.load_more')}
            </Button>
          )}
        </div>
        <div className="pod-comments-compose max-h-[45%] shrink-0 overflow-auto border-t border-border px-4 py-3">
          {model.anchor.value && (
            <div className="pod-comment-draft-quote">
              <blockquote className="mb-3 block max-h-[100px] overflow-auto border-l-2 border-border pl-2 text-start text-xs leading-normal whitespace-pre-wrap text-fg-secondary [overflow-wrap:anywhere]">
                {selection?.quote ?? model.anchor.value.quote}
              </blockquote>
              <Button variant="ghost" size="xs" onClick={() => model.capture(null)}>
                {t('pod.document.comment_whole_page')}
              </Button>
            </div>
          )}
          {canComment && (
            <Button variant="ghost" size="xs" onClick={() => selectAnchor()}>
              {t('pod.document.use_selection')}
            </Button>
          )}
          {canComment && anchor && !selection && (
            <p className="text-xs" role="status">
              {t('pod.document.reselect_quote')}
            </p>
          )}
          {selection && !draft.bodyReady.value && (
            <p className="text-xs" role="status">
              {t('pod.document.wait_for_save')}
            </p>
          )}
          <CommentComposer
            model={model}
            draftKey="new"
            label={t('pod.document.new_comment')}
            disabled={!canComment}
            submitDisabled={!!anchor && (!selection || !draft.bodyReady.value)}
            send={add}
            refresh={refresh}
          />
          {!canComment && <p className="text-xs text-fg-tertiary">{t('pod.document.comments_read_only')}</p>}
        </div>
      </ErrorBoundary>
    </>
  )
  if (mobile) {
    return (
      <Sheet open onOpenChange={open => !open && close()}>
        <SheetContent
          className="pod-comments-sheet min-h-0 shrink-0 max-w-none data-[side=right]:w-[min(400px,calc(100vw-16px))] data-[side=right]:sm:max-w-none"
          showCloseButton={false}
          finalFocus={() => {
            const id = revealOnClose.current
            return (id && reveal(id)) || returnFocus.current
          }}>
          <SheetTitle className="sr-only">{t('pod.document.comments')}</SheetTitle>
          {body}
        </SheetContent>
      </Sheet>
    )
  }
  return (
    <PodPanelSurface
      data-sheet
      className="pod-comments flex min-h-0 w-[360px] shrink-0 flex-col paper-sheet"
      aria-label={t('pod.document.comments')}
      onKeyDown={event => {
        if (event.key === 'Escape') {
          event.stopPropagation()
          close()
          returnFocus.current?.focus()
        }
      }}>
      {body}
    </PodPanelSurface>
  )
}
