import { usePageMetadata } from './use-page-metadata'
import { PodPanelPresence, usePanelMotion, type PanelInputEvent } from './panel-motion'
import { PageContent } from './page-content'
import { DocumentInsights } from './document-insights'
import { DocumentPage, downloadDraft } from './document-editor'
import { pageCreated, updatePageMetadata } from './state/navigation-cache'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode, requestErrorDetails } from '../common/request-errors'

import { useTranslation } from 'react-i18next'

import { type EditorHandle } from '@ankole/block-editor'
import {
  commentSelection,
  trackCommentSelection,
  revealComment,
  EditorSelection,
  type Editor
} from '@ankole/block-editor/editor'

import {
  Alert,
  AlertAction,
  AlertDescription,
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  SidebarTrigger,
  Toggle,
  useSidebar,
  toast
} from '@ankole/uikit'
import {
  RiLink,
  RiArrowGoBackLine,
  RiChat3Line,
  RiChatQuoteLine,
  RiDeleteBinLine,
  RiErrorWarningLine,
  RiFileCopyLine,
  RiFolderTransferLine,
  RiMoreFill,
  RiStarFill,
  RiStarLine
} from '@remixicon/react'
import { effect, useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useEffectEvent, useRef, useState } from 'react'

import { Link, useBlocker, useNavigate, useParams } from '@tanstack/react-router'
import { podID, principalUID, podLocation, podRouteID } from '../common/browser-context'
import { ErrorBoundary } from '../common/error-boundary'
import { useSearchParams } from '../common/router'

import {
  contentKeys,
  pageAPI,
  pageQuery,
  pageCommentSummaryQuery,
  pagesQuery,
  pageTitleMaxLength,
  type PageDetail
} from './content-api'

import { ContentError } from './content-primitives'
import { PageChildrenMenu } from './page-navigation'
import { PageBreadcrumbs } from './page-breadcrumbs'
import { DocumentSubpages } from './page-subpages'
import { isDocumentBodyEmpty } from './state/page-subpages'
import { PermanentDeletePageDialog, usePagePurge, usePageTrash } from './page-actions'

import { useCopyPageLink, PageSharingButton } from './page-sharing'
import { PageDraftModel } from './state/page-draft'
import { DocumentToolsModel } from './state/document-tools-model'
import { DocumentMenuItems, DocumentStats } from './document-tools'
import { DocumentHistory } from './document-history'
import { PageComments } from './page-comments'
import { PageCommentsModel } from './state/page-comments'
import { MovePageDialog } from './page-move-dialog'

import { isRealtimeAccessDenied } from './realtime'
import { LocalPageChatDrafts, useChatDrafts } from './chat-drafts'
import { PageChat } from './page-chat'
import { PageIconPicker } from './page-icon'
import { canMovePage } from './state/page-move'
import './page-workspace.css'

export function PageRoute() {
  const { t } = useTranslation()
  const pageID = podRouteID(useParams({ strict: false }).pageID) ?? ''
  const { state: sidebarState } = useSidebar()
  const navigation = (
    <header className="pod-page-header sheet-header border-b border-border">
      <SidebarTrigger
        className={sidebarState === 'expanded' ? 'md:hidden' : undefined}
        label={t('pod.sidebar.expand')}
      />
    </header>
  )
  const page = useQuery(pageQuery(pageID))
  const client = useQueryClient()
  const visited = useRef<string | null>(null)
  useEffect(() => {
    if (page.data && !page.data.page.deleted_at && visited.current !== pageID) {
      visited.current = pageID
      void pageAPI
        .state(pageID, { visited: true })
        .then(() => client.invalidateQueries({ queryKey: contentKeys.list('recent') }))
        .catch(() => {})
    }
  }, [pageID, !!page.data, client])
  if (page.isPending) {
    return (
      <>
        {navigation}
        <p role="status" className="p-8">
          {t('pod.content.loading_page')}
        </p>
      </>
    )
  }
  if (page.error && !page.data) {
    return (
      <section className="flex h-full min-h-0 flex-col">
        {navigation}
        <div className="overflow-auto p-8">
          <ContentError
            error={page.error}
            retry={isRealtimeAccessDenied(page.error) ? undefined : () => void page.refetch()}
          />
          <LocalPageChatDrafts pageID={pageID} />
        </div>
      </section>
    )
  }
  return page.data ? (
    <PageWorkspace key={pageID} detail={page.data} loadError={page.error} reload={() => void page.refetch()} />
  ) : null
}

function PageWorkspace({
  detail: snapshot,
  loadError,
  reload
}: {
  detail: PageDetail
  loadError: unknown
  reload(): void
}) {
  useSignals()
  const { t } = useTranslation()
  const page = usePageMetadata(snapshot.page)
  const detail = { ...snapshot, page }
  const { actions } = detail
  const { state: sidebarState, isMobile } = useSidebar()
  const [moving, setMoving] = useState(false)
  const [comments, setComments] = useState(false)
  const commentsMotion = usePanelMotion(comments)
  const [focusedComment, focusComment] = useState<string | null>(null)
  const [selectedCommentThreads, selectCommentThreads] = useState<readonly string[]>([])
  const [history, setHistory] = useState(false)
  const commentsTrigger = useRef<HTMLButtonElement>(null)
  const actionsTrigger = useRef<HTMLButtonElement>(null)
  const copyLink = useCopyPageLink(page.id)
  const client = useQueryClient()
  const [search, setSearch] = useSearchParams()
  const linkedComment = podRouteID(search.get('commentId') ?? undefined)
  useEffect(() => {
    if (!linkedComment) return
    focusComment(linkedComment)
    selectCommentThreads([])
    commentsMotion.prepare(true)
    setComments(true)
  }, [linkedComment])
  const selection = search.get('chat')
  const chat = selection === 'new' || selection === 'latest' ? selection : podRouteID(selection ?? undefined)
  const chatMotion = usePanelMotion(!!chat)
  const chatTrigger = useRef<HTMLButtonElement>(null)
  const hadChat = useRef(!!chat)
  useEffect(() => {
    if (hadChat.current && !chat && !isMobile) chatTrigger.current?.focus()
    hadChat.current = !!chat
  }, [chat, isMobile])
  const selectChat = (id: string | null, flushSync = false, event?: PanelInputEvent) => {
    chatMotion.prepare(!!id, comments ? undefined : event)
    if (id) {
      commentsMotion.prepare(false)
      setComments(false)
    }
    const next = podLocation(`/pages/${page.id}`, { ...Object.fromEntries(search), chat: id })
    setSearch(next.search, { replace: true, preventScrollReset: true, flushSync })
  }
  // Asking an Agent about a selection quotes it in Page chat: the open chat receives it, otherwise the
  // Page's latest chat opens with it, and focus moves to the composer.
  const chatDrafts = useChatDrafts()
  const askAgent = (selection: { quote: string }) => {
    chatDrafts.pageQuote.value = { pageID: page.id, quote: selection.quote }
    if (!chat) selectChat('latest', true)
  }
  const model = useModel(() => new PageDraftModel(`ankole.pod.document-draft:${podID()}:${principalUID()}:${page.id}`))
  model.load(page.id, detail.content?.content ?? '<page/>', page.revision, page.title)
  const documentTools = useModel(
    () => new DocumentToolsModel(model, `ankole.pod.document-stats:${podID()}:${principalUID()}`)
  )
  const commentDrafts = useModel(
    () => new PageCommentsModel(`ankole.pod.comments:${podID()}:${principalUID()}:${page.id}`)
  )
  const documentContent = useRef<HTMLDivElement>(null)
  const [presenceContainer, setPresenceContainer] = useState<HTMLDivElement | null>(null)
  const [insights, setInsights] = useState(false)
  const titleInput = useRef<HTMLTextAreaElement>(null)
  const [editorHandle, setEditorHandle] = useState<EditorHandle | null>(null)
  const documentEditor = useRef<Editor | null>(null)
  const attachEditor = (handle: EditorHandle | null) => {
    documentEditor.current = handle?.editor ?? null
    setEditorHandle(handle)
  }
  const selectionReturnThread = useRef<string | null>(null)
  const openComments = (id: string | null = null, ids: readonly string[] = [], event?: PanelInputEvent) => {
    focusComment(id)
    selectCommentThreads(ids)
    commentsMotion.prepare(true, chat ? undefined : event)
    setComments(true)
    if (chat) selectChat(null)
  }
  const closeComments = (event?: PanelInputEvent) => {
    commentsMotion.prepare(false, event)
    setComments(false)
    if (!isMobile) commentsTrigger.current?.focus()
  }
  const captureCommentSelection = (selection: { from: number; to: number; quote: string }) => {
    const instance = documentEditor.current
    const read = instance ? trackCommentSelection(instance, selection) : undefined
    commentDrafts.capture({
      quote: selection.quote,
      read
    })
    openComments(selectionReturnThread.current)
    selectionReturnThread.current = null
  }
  const selectCommentAnchor = (threadID?: string) => {
    selectionReturnThread.current = threadID ?? focusedComment
    if (isMobile) {
      setComments(false)
      toast.info(t('pod.document.select_text'))
      return
    }
    documentEditor.current?.flush()
    const selection = documentEditor.current && commentSelection(documentEditor.current)
    if (!selection) {
      toast.error(t('pod.document.select_text'))
      return
    }
    captureCommentSelection(selection)
  }
  const [titleComposing, setTitleComposing] = useState(false)
  const dirty = model.hasUnsavedChanges.value
  const blocker = useBlocker({
    shouldBlockFn: ({ current, next }) => dirty && current.pathname !== next.pathname,
    enableBeforeUnload: false,
    withResolver: true
  })
  useEffect(() => {
    if (!dirty && blocker.status === 'blocked') blocker.proceed?.()
  }, [dirty, blocker])
  useEffect(() => {
    const stop = effect(() => {
      // Persist local recovery data after edits, acknowledgements, and explicit discards.
      void [
        model.xml.value,
        model.savedXML.value,
        model.title.value,
        model.savedTitle.value,
        model.titleBase.value,
        model.recoveryDrafts.value,
        model.bodyPending.value
      ]
      const timer = window.setTimeout(() => model.persist(), 250)
      return () => window.clearTimeout(timer)
    })
    const leave = (event: BeforeUnloadEvent) => {
      model.persist()
      if (model.hasUnsavedChanges.value) event.preventDefault()
    }
    const persist = () => model.persist()
    const visibility = () => {
      if (document.visibilityState === 'hidden') model.persist()
    }
    window.addEventListener('beforeunload', leave)
    window.addEventListener('pagehide', persist)
    document.addEventListener('visibilitychange', visibility)
    return () => {
      stop()
      model.persist()
      window.removeEventListener('beforeunload', leave)
      window.removeEventListener('pagehide', persist)
      document.removeEventListener('visibilitychange', visibility)
    }
  }, [model])
  const accessDenied = isRealtimeAccessDenied(loadError)
  const trashed = Boolean(page.deleted_at)
  const toolsAvailable = page.type === 'doc' && !accessDenied && !trashed
  const commentSummary = useQuery({ ...pageCommentSummaryQuery(page.id), enabled: toolsAvailable })
  useEffect(() => {
    if (!toolsAvailable) return
    const shortcut = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || !event.shiftKey || event.altKey || event.isComposing) return
      if (event.key.toLowerCase() === 'i') {
        event.preventDefault()
        setInsights(true)
      } else if (event.key.toLowerCase() === 'g' && !isMobile) {
        event.preventDefault()
        documentTools.setShowStats(!documentTools.showStats.value)
      }
    }
    window.addEventListener('keydown', shortcut)
    return () => window.removeEventListener('keydown', shortcut)
  }, [toolsAvailable, documentTools, isMobile])
  const navigate = useNavigate()
  const [purging, setPurging] = useState(false)
  const edit = !trashed && actions.includes('page_edit') && !accessDenied
  const canManage = !trashed && actions.includes('page_manage') && !accessDenied
  const canRestore = trashed && actions.includes('page_manage') && !accessDenied
  const canMove = canMovePage(detail) && !accessDenied
  const contentDetail = trashed ? { ...detail, actions: ['page_view' as const] } : detail
  const restore = useMutation({
    mutationFn: () => pageAPI.restore(page.id),
    onSuccess: async ({ page }) => {
      pageCreated(client, page)
      await client.invalidateQueries({ queryKey: contentKeys.page(page.id) })
      toast.success(t('pod.content.page_restored'))
    }
  })
  const purge = usePagePurge(() => void navigate({ to: podLocation('/content/trash').pathname }))
  const favorites = useQuery(pagesQuery('favorites'))
  const favorited = favorites.data?.pages.some(favorite => favorite.id === page.id) ?? false
  const rename = useMutation({
    scope: { id: `page-title:${page.id}` },
    mutationFn: (title: string) => pageAPI.update(page.id, { title, expected_title: model.titleBase.value }),
    onSuccess: ({ page }) => {
      model.titleSaved(page.title)
      updatePageMetadata(client, { id: page.id, title: page.title })
    },
    onError: error => {
      if (error instanceof InternalAPIError && requestErrorCode(error.payload) === 'title_conflict') {
        const current = requestErrorDetails(error.payload).title
        if (typeof current === 'string') model.titleRejected(current)
      }
    }
  })
  const saveTitle = (retry = false) => {
    if (!edit || model.titleConflict.value || rename.isPending) return
    const title = model.title.value.trim()
    if (!retry && rename.isError && rename.variables === title) return
    if (model.titleDirty.value) rename.mutate(title)
  }
  const title = model.title.value
  const autosaveTitle = useEffectEvent(() => saveTitle())
  useEffect(() => {
    if (!edit || titleComposing) return
    const timer = window.setTimeout(autosaveTitle, 500)
    return () => window.clearTimeout(timer)
  }, [title, edit, titleComposing, rename.isPending])
  const finishTitle = async () => {
    if (model.titleConflict.value) throw new Error(t('pod.document_title.conflict'))
    if (accessDenied || (!edit && model.titleDirty.value)) {
      throw new Error(t('pod.content.could_not_confirm_your_editing_permission_reload_the_page_and'))
    }
    if (model.titleDirty.value) await rename.mutateAsync(model.title.value.trim())
  }
  const remove = usePageTrash(model.discard)
  const favorite = useMutation({
    mutationFn: () => pageAPI.state(page.id, { favorite: !favorited }),
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.list('favorites') })
  })
  const commentsPanel =
    comments && toolsAvailable ? (
      <PageComments
        key="comments"
        detail={detail}
        draft={model}
        editor={editorHandle}
        model={commentDrafts}
        mobile={isMobile}
        focused={focusedComment}
        selectedThreads={selectedCommentThreads}
        clearSelection={() => selectCommentThreads([])}
        focus={focusComment}
        close={closeComments}
        returnFocus={commentsTrigger}
        selectAnchor={selectCommentAnchor}
        reveal={id => {
          focusComment(id)
          const instance = documentEditor.current
          return instance && revealComment(instance, id) ? instance.contentDOM : null
        }}
      />
    ) : null
  return (
    <section
      className="pod-page flex h-full min-h-0 overflow-hidden md:gap-3 md:overflow-visible"
      data-page-type={page.type}>
      <div
        data-sheet
        className="pod-page-main flex min-w-0 flex-1 flex-col bg-background md:paper-sheet md:overflow-hidden">
        <header className="pod-page-header sheet-header @container gap-2 border-b border-border max-md:gap-1 max-md:px-2">
          <SidebarTrigger
            className={sidebarState === 'expanded' ? 'md:hidden' : undefined}
            label={t('pod.sidebar.expand')}
          />
          <div className="flex min-w-0 flex-1 items-center gap-0.5">
            <ErrorBoundary variant="inline" resetKeys={[page.id]}>
              <PageBreadcrumbs ancestors={detail.ancestors} title={model.title.value} compact={isMobile} />
            </ErrorBoundary>
            {!trashed && (
              <Button
                size="icon-xs"
                variant="ghost"
                className="aria-pressed:text-foreground"
                aria-label={favorited ? t('pod.content.favorited') : t('pod.content.add_to_favorites')}
                title={favorited ? t('pod.content.favorited') : t('pod.content.add_to_favorites')}
                aria-pressed={favorited}
                disabled={favorite.isPending || favorites.isPending || !!favorites.error}
                onClick={() => favorite.mutate()}>
                {favorited ? <RiStarFill aria-hidden /> : <RiStarLine aria-hidden />}
              </Button>
            )}
          </div>
          <div className="flex shrink-0 items-center gap-1">
            {page.type === 'doc' && <div ref={setPresenceContainer} />}
            {!accessDenied && !trashed && page.type !== 'doc' && (
              <PageChildrenMenu
                pageID={page.id}
                canCreate={edit}
                scope={page.private_owner_uid ? 'private' : 'space'}
                privateOwner={page.private_owner_uid ?? undefined}
              />
            )}
            {!accessDenied && !trashed && (
              <Toggle
                size="sm"
                aria-label={t('pod.page_chat.title')}
                title={t('pod.page_chat.title')}
                pressed={!!chat}
                aria-expanded={!!chat}
                ref={chatTrigger}
                onPressedChange={(_, details) => selectChat(chat ? null : 'latest', true, details.event)}>
                <RiChat3Line aria-hidden />
                <span className="@max-[640px]:sr-only">{t('pod.page_chat.title')}</span>
              </Toggle>
            )}
            {!accessDenied && !trashed && toolsAvailable && (
              <Toggle
                size="sm"
                aria-label={t('pod.document.comments')}
                title={t('pod.document.comments')}
                pressed={comments}
                aria-expanded={comments}
                ref={commentsTrigger}
                onPressedChange={(_, details) =>
                  comments ? closeComments(details.event) : openComments(focusedComment, [], details.event)
                }>
                <RiChatQuoteLine aria-hidden />
                {!!commentSummary.data?.unread_count && (
                  <span role="status" className="tabular-nums" aria-label={t('pod.document.unread_comments')}>
                    {commentSummary.data.unread_count}
                  </span>
                )}
              </Toggle>
            )}
            {toolsAvailable && isMobile && !comments && focusedComment && (
              <Button variant="ghost" size="xs" onClick={() => openComments(focusedComment)}>
                {t('pod.document.return_to_comment')}
              </Button>
            )}
            {!accessDenied && !trashed ? (
              <ErrorBoundary variant="inline" resetKeys={[page.id]}>
                <PageSharingButton pageID={page.id} page={page} />
              </ErrorBoundary>
            ) : (
              <Button
                size="icon-sm"
                variant="ghost"
                aria-label={t('pod.content.copy_link')}
                title={t('pod.content.copy_link')}
                onClick={() => void copyLink()}>
                <RiLink aria-hidden className="size-4" />
              </Button>
            )}
            <DropdownMenu>
              <DropdownMenuTrigger
                render={
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    aria-label={t('common.more_actions')}
                    title={t('common.more_actions')}
                    ref={actionsTrigger}
                  />
                }>
                <RiMoreFill aria-hidden className="size-4" />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="min-w-60">
                <DropdownMenuItem onClick={() => void copyLink()}>
                  <RiFileCopyLine aria-hidden />
                  {t('pod.content.copy_link')}
                </DropdownMenuItem>
                {canMove && (
                  <DropdownMenuItem disabled={remove.isPending} onClick={() => setMoving(true)}>
                    <RiFolderTransferLine aria-hidden />
                    {t('pod.content.move')}
                  </DropdownMenuItem>
                )}
                {toolsAvailable && (
                  <DocumentMenuItems
                    detail={detail}
                    draft={model}
                    model={documentTools}
                    mobile={isMobile}
                    openInsights={() => setInsights(true)}
                    openComments={() => openComments()}
                    openHistory={edit ? () => setHistory(true) : undefined}
                  />
                )}
                {canManage && (
                  <>
                    <DropdownMenuSeparator />
                    <DropdownMenuItem
                      variant="destructive"
                      disabled={remove.isPending}
                      onClick={() => remove.mutate(page)}>
                      <RiDeleteBinLine aria-hidden />
                      {t('pod.content.move_to_trash')}
                    </DropdownMenuItem>
                  </>
                )}
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </header>
        {insights && toolsAvailable && (
          <DocumentInsights detail={detail} close={() => setInsights(false)} returnFocus={actionsTrigger} />
        )}
        {history && toolsAvailable && edit && (
          <DocumentHistory detail={detail} draft={model} close={() => setHistory(false)} returnFocus={actionsTrigger} />
        )}
        {purging && (
          <PermanentDeletePageDialog
            page={page}
            pending={purge.isPending}
            onCancel={() => setPurging(false)}
            onConfirm={() => purge.mutate(page)}
          />
        )}
        {moving && (
          <MovePageDialog
            page={page}
            beforeMove={finishTitle}
            close={() => setMoving(false)}
            returnFocus={actionsTrigger}
          />
        )}
        <div className="pod-page-scroll min-h-0 flex-1 overflow-auto">
          <div
            className="pod-page-content"
            onKeyDownCapture={event => {
              const editor = documentEditor.current
              if (
                event.key !== 'ArrowUp' ||
                event.shiftKey ||
                event.altKey ||
                event.metaKey ||
                event.ctrlKey ||
                event.nativeEvent.isComposing ||
                event.nativeEvent.keyCode === 229 ||
                !edit ||
                !editor ||
                event.target !== editor.contentDOM ||
                !editor.state.selection.empty ||
                editor.state.selection.head !== EditorSelection.atStart(editor.state).head
              ) {
                return
              }
              event.preventDefault()
              event.stopPropagation()
              titleInput.current?.focus()
              titleInput.current?.setSelectionRange(title.length, title.length)
            }}>
            {model.storageError.value && dirty && (
              <Alert variant="warning" className="mb-6" role="alert">
                <AlertDescription>{t('pod.document_title.storage_unavailable')}</AlertDescription>
                <AlertAction>
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => downloadDraft(model.xml.value, model.title.value, model.recoveryDrafts.value)}>
                    {t('pod.content.export_draft')}
                  </Button>
                </AlertAction>
              </Alert>
            )}
            {trashed && (
              <Alert variant="warning" className="mb-6 shrink-0" role="note">
                <RiErrorWarningLine aria-hidden />
                <AlertDescription>
                  {page.purge_started_at
                    ? t('pod.content.purge_in_progress_notice')
                    : t('pod.content.trash_read_only_notice')}
                </AlertDescription>
                {canRestore && (
                  <AlertAction>
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={!!page.purge_started_at || restore.isPending || purge.isPending}
                      onClick={() => restore.mutate()}>
                      <RiArrowGoBackLine aria-hidden />
                      {restore.isPending ? t('pod.content.restoring') : t('pod.content.restore_page')}
                    </Button>
                    <Button
                      size="sm"
                      variant="ghost"
                      className="text-destructive-foreground"
                      disabled={!!page.purge_started_at || restore.isPending || purge.isPending}
                      onClick={() => setPurging(true)}>
                      <RiDeleteBinLine aria-hidden />
                      {t('pod.content.permanently_delete')}
                    </Button>
                  </AlertAction>
                )}
              </Alert>
            )}
            <div className="pod-page-heading">
              {page.type === 'doc' && <PageIconPicker page={page} editable={edit} />}
              {edit ? (
                <div className="min-w-0 flex-1">
                  <textarea
                    ref={titleInput}
                    aria-label={t('pod.content.page_title')}
                    rows={1}
                    maxLength={pageTitleMaxLength}
                    value={model.title.value}
                    autoFocus={(page.type === 'doc' || page.type === 'base') && !page.title && !chat}
                    disabled={remove.isPending || accessDenied}
                    placeholder={t('pod.content.untitled')}
                    onChange={event => (model.title.value = event.target.value.replace(/\n/g, ' '))}
                    onCompositionStart={() => setTitleComposing(true)}
                    onCompositionEnd={() => setTitleComposing(false)}
                    onKeyDown={event => {
                      if (titleComposing || event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return
                      if (event.key === 'Enter') {
                        event.preventDefault()
                        if (!focusEditorStart(documentEditor.current)) event.currentTarget.blur()
                        return
                      }
                      if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return
                      if (event.key === 'Tab') {
                        if (focusEditorStart(documentEditor.current)) event.preventDefault()
                        return
                      }
                      if (
                        event.key === 'ArrowDown' &&
                        documentEditor.current &&
                        !documentEditor.current.state.readOnly &&
                        isCaretOnLastTitleLine(event.currentTarget)
                      ) {
                        event.preventDefault()
                        focusEditorStart(documentEditor.current)
                      }
                    }}
                    className="pod-page-title"
                    onBlur={() => saveTitle()}
                  />
                </div>
              ) : (
                <h1 className="pod-page-title">{page.title || t('pod.content.untitled')}</h1>
              )}
            </div>
            {!!loadError && model.hasUnsavedChanges.value && (
              <p className="mb-3 text-sm">{t('pod.content.could_not_load_the_latest_page_state_your_unsaved_draft')}</p>
            )}
            <ContentError error={loadError} retry={accessDenied ? undefined : reload} />
            {accessDenied && <LocalPageChatDrafts pageID={page.id} />}
            {accessDenied && model.dirty.value && (
              <Button variant="outline" size="sm" onClick={() => downloadDraft(model.xml.value, model.title.value)}>
                {t('pod.content.export_draft')}
              </Button>
            )}
            {edit && (
              <p role="status" className="sr-only">
                {rename.isPending
                  ? t('pod.content.saving_title')
                  : model.titleDirty.value
                    ? t('pod.content.title_not_saved')
                    : ''}
              </p>
            )}
            {model.titleConflict.value ? (
              <div role="alert" className="mb-3 rounded border border-warning p-3 text-sm">
                <p>{t('pod.document_title.conflict')}</p>
                <p className="mt-1 break-words">{t('pod.document_title.current', { title: model.savedTitle.value })}</p>
                <div className="mt-2 flex gap-2">
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => {
                      model.reviewTitle(true)
                      rename.reset()
                    }}>
                    {t('pod.document_title.use_current')}
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => {
                      model.reviewTitle(false)
                      saveTitle(true)
                    }}>
                    {t('pod.document_title.save_draft')}
                  </Button>
                </div>
              </div>
            ) : (
              <ContentError error={rename.error} retry={model.titleDirty.value ? () => saveTitle(true) : undefined} />
            )}
            <ContentError error={remove.error || favorite.error || favorites.error || restore.error} />
            {detail.source_conversation && (
              <p className="pod-page-origin">
                {detail.source_conversation.deleted ? (
                  t('pod.content.source_conversation_deleted')
                ) : (
                  <Link className="link" to={podLocation(`/conversations/${detail.source_conversation.id}`).pathname}>
                    {t('pod.content.source_conversation')}
                    {detail.source_conversation.title || t('pod.content.view_conversation')}
                  </Link>
                )}
              </p>
            )}
            {!accessDenied &&
              (page.type === 'doc' ? (
                (() => {
                  const hideEmptyViewerBody =
                    !trashed && contentDetail.child_count > 0 && !edit && isDocumentBodyEmpty(model.xml.value)
                  return (
                    <>
                      <ErrorBoundary
                        variant="panel"
                        resetKeys={[page.id, page.revision]}
                        actions={
                          model.dirty.value || model.recoveryDrafts.value.length > 0 ? (
                            <Button
                              type="button"
                              size="sm"
                              onClick={() =>
                                downloadDraft(model.xml.value, model.title.value, model.recoveryDrafts.value)
                              }>
                              {t('pod.content.export_draft')}
                            </Button>
                          ) : undefined
                        }>
                        <div ref={documentContent} className={hideEmptyViewerBody ? 'hidden' : undefined}>
                          <DocumentPage
                            detail={contentDetail}
                            model={model}
                            presenceContainer={presenceContainer}
                            onEditor={attachEditor}
                            resolvedCommentIDs={commentSummary.data?.resolved_ids ?? []}
                            onComment={ids => openComments(ids[0] ?? null, ids.length > 1 ? ids : [])}
                            onRequestComment={captureCommentSelection}
                            onAskAgent={!accessDenied && !trashed ? askAgent : undefined}
                          />
                        </div>
                      </ErrorBoundary>
                      {!trashed && (
                        <ErrorBoundary
                          variant="inline"
                          label={t('pod.subpages.title')}
                          resetKeys={[page.id]}
                          className="mt-8">
                          <DocumentSubpages
                            key={page.id}
                            detail={contentDetail}
                            canEdit={edit}
                            hideTopDivider={hideEmptyViewerBody}
                          />
                        </ErrorBoundary>
                      )}
                    </>
                  )
                })()
              ) : (
                <ErrorBoundary variant="panel" resetKeys={[page.id, page.revision]}>
                  <PageContent detail={contentDetail} />
                </ErrorBoundary>
              ))}
          </div>
          {toolsAvailable && !isMobile && (
            <ErrorBoundary variant="inline" resetKeys={[page.id]}>
              <DocumentStats model={documentTools} content={documentContent} />
            </ErrorBoundary>
          )}
        </div>
      </div>
      {isMobile
        ? commentsPanel
        : toolsAvailable &&
          (comments || !chat) && <PodPanelPresence animate={commentsMotion.animate}>{commentsPanel}</PodPanelPresence>}
      {!accessDenied && !trashed && !comments && (
        <PageChat
          mobile={isMobile}
          pageID={page.id}
          pageTitle={model.title.value}
          selection={chat ?? null}
          animate={chatMotion.animate}
          select={selectChat}
          returnFocus={chatTrigger}
        />
      )}
      <Dialog open={blocker.status === 'blocked'} onOpenChange={open => !open && blocker.reset?.()}>
        <DialogContent className="pod-dialog" closeLabel={t('common.close')}>
          <DialogTitle>{t('pod.content.unsaved_changes')}</DialogTitle>
          <p className="text-sm">{t('pod.content.unsaved_changes_leave_warning')}</p>
          <DialogFooter>
            <Button variant="outline" onClick={() => blocker.reset?.()}>
              {t('pod.content.continue_editing')}
            </Button>
            <Button
              variant="outline"
              onClick={() => {
                downloadDraft(model.xml.value, model.title.value, model.recoveryDrafts.value)
                blocker.proceed?.()
              }}>
              {t('pod.content.download_draft_and_leave')}
            </Button>
            <Button
              variant="destructive"
              onClick={() => {
                model.discard()
                blocker.proceed?.()
              }}>
              {t('pod.content.discard_changes_and_leave')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  )
}

function focusEditorStart(editor: Editor | null): boolean {
  if (!editor || editor.state.readOnly) return false
  editor.dispatch({ selection: EditorSelection.atStart(editor.state), scrollIntoView: true })
  editor.focus()
  return true
}

function isCaretOnLastTitleLine(input: HTMLTextAreaElement): boolean {
  if (input.selectionStart !== input.selectionEnd) return false
  const offset = input.selectionEnd
  const value = input.value
  if (offset >= value.length) return true
  const style = getComputedStyle(input)
  const lineHeight = parseFloat(style.lineHeight)
  if (Number.isFinite(lineHeight) && input.clientHeight < lineHeight * 1.5) return true
  if (input.clientWidth <= 0) return true

  const mirror = document.createElement('div')
  mirror.setAttribute('aria-hidden', 'true')
  mirror.style.position = 'fixed'
  mirror.style.top = '0'
  mirror.style.left = '0'
  mirror.style.visibility = 'hidden'
  mirror.style.pointerEvents = 'none'
  mirror.style.boxSizing = style.boxSizing
  mirror.style.width = `${input.clientWidth}px`
  mirror.style.padding = style.padding
  mirror.style.font = style.font
  mirror.style.fontKerning = style.fontKerning
  mirror.style.letterSpacing = style.letterSpacing
  mirror.style.wordSpacing = style.wordSpacing
  mirror.style.lineHeight = style.lineHeight
  mirror.style.whiteSpace = 'pre-wrap'
  mirror.style.overflowWrap = style.overflowWrap
  mirror.style.wordBreak = style.wordBreak
  const text = document.createTextNode(value)
  mirror.appendChild(text)
  document.body.appendChild(mirror)
  try {
    const caretEnd = Math.min(value.length, offset + ((value.codePointAt(offset) ?? 0) > 0xffff ? 2 : 1))
    const lastStart =
      value.length >= 2 && (value.codePointAt(value.length - 2) ?? 0) > 0xffff ? value.length - 2 : value.length - 1
    const caret = document.createRange()
    caret.setStart(text, offset)
    caret.setEnd(text, caretEnd)
    const end = document.createRange()
    end.setStart(text, lastStart)
    end.setEnd(text, value.length)
    const caretRect = caret.getClientRects()[0] ?? caret.getBoundingClientRect()
    const endRect = end.getClientRects()[0] ?? end.getBoundingClientRect()
    const threshold = Number.isFinite(lineHeight) ? lineHeight / 2 : 8
    return Math.abs(endRect.top - caretRect.top) < threshold
  } finally {
    mirror.remove()
  }
}
