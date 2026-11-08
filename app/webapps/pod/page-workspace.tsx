import { agentsQuery } from './api'
import { pageDomain, canCreateChild, canRenamePage, canTrashPage } from './state/page-location'
import { useCanonicalPageUrl, usePageMetadata } from './use-page-metadata'
import { PodPanelPresence, usePanelMotion, type PanelInputEvent } from './panel-motion'
import { PageContent, PageLearningButton } from './page-content'
import { KnowledgePage } from './knowledge-page'
import { DocumentInsights } from './document-insights'
import { DocumentPage } from './document-editor'
import { downloadDraft } from './document-recovery'
import { pageCreated, updatePageMetadata } from './state/navigation-cache'
import { InternalAPIError } from '../common/internal-api-client'
import { BdiLabel } from '../common/bidi-file-name'
import { requestErrorCode, requestErrorDetails } from '../common/request-errors'

import { useTranslation } from 'react-i18next'

import { type EditorHandle } from '@ankole/block-editor'
import {
  commentSelection,
  trackCommentSelection,
  revealComment,
  foldedHeadings,
  toggleHeading,
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
import { createModel, effect, useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useEffect, useEffectEvent, useRef, useState } from 'react'

import { Link, useBlocker, useLocation, useNavigate, useParams } from '@tanstack/react-router'
import { podID, principalUID } from '../common/browser-context'
import { podLocation, podPagePathnameID, podPageRouteID, podRouteID } from '../common/pod-url'
import { ErrorBoundary } from '../common/error-boundary'
import { useSearchParams } from '../common/router'

import {
  contentKeys,
  pageAPI,
  pageQuery,
  pageCommentSummaryQuery,
  pagesQuery,
  limitPageTitle,
  type PageDetail
} from './content-api'

import { ContentError, ContentSkeleton } from './content-primitives'
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
import type { FileCommentSelection, FilePreviewHandle } from './file-comment-anchors'
import { PageCommentsModel } from './state/page-comments'
import { MovePageDialog } from './page-move-dialog'

import { isRealtimeAccessDenied } from './realtime'
import { LocalPageChatDrafts, useChatDrafts } from './chat-drafts'
import { PageChat } from './page-chat'
import { PageIconPicker } from './page-icon'
import { canMovePage } from './state/page-move'
import { PageFindBar, readSingleLineSelectionInContainer, shouldHandlePageFindShortcut } from './find-bar'
import { normalizeSearchQuery, parseSearchTarget } from './search-targets'
import { isSpreadsheetFileName } from './state/spreadsheet-grid'
import './page-workspace.css'

const AppletAutomationControl = lazy(() =>
  import('./applet-page').then(module => ({ default: module.AppletAutomationControl }))
)

export function PageRoute() {
  const { t } = useTranslation()
  const pageID = podPageRouteID(useParams({ strict: false }).pageID) ?? ''
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
  const pathname = useLocation({ select: location => location.pathname })
  const navigate = useNavigate()
  const brainPage =
    page.data?.page.type === 'knowledge' ||
    page.data?.ancestors.some(
      ancestor => ancestor.type === 'knowledge' || ancestor.system_key?.startsWith('ankole_brain')
    )
  useEffect(() => {
    if (brainPage && pathname.startsWith('/pages/')) {
      void navigate({ to: `/meta/brain/${pageID}`, search: true, replace: true })
    }
  }, [brainPage, pathname, pageID, navigate])
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
      <section className="flex h-full min-h-0 flex-col">
        {navigation}
        <ContentSkeleton variant="page" label={t('pod.content.loading_page')} />
      </section>
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
  const copyLink = useCopyPageLink(page.id, page.title)
  useCanonicalPageUrl(page.id, page.title)
  const client = useQueryClient()
  const [search, setSearch] = useSearchParams()
  const urlFind = search.get('find')?.trim() ?? ''
  const urlTarget = parseSearchTarget(search.get('at'), search.get('view'))
  const fileCheckName = page.name || page.title || ''
  const fileMime = typeof page.metadata?.mime_type === 'string' ? page.metadata.mime_type : ''
  const domFindSupported =
    page.type === 'doc' ||
    page.type === 'knowledge' ||
    (page.type === 'file' &&
      !isSpreadsheetFileName(fileCheckName) &&
      !/\.(pptx|pdf|xls|xlsb|ods)$/i.test(fileCheckName) &&
      fileMime !== 'application/pdf' &&
      !fileMime.includes('presentationml'))
  const [manualFind, setManualFind] = useState(false)
  const [seededFindQuery, setSeededFindQuery] = useState<string | undefined>(undefined)
  const [findFocusTrigger, setFindFocusTrigger] = useState(0)
  const findBarOpen = domFindSupported && (Boolean(urlFind) || manualFind)
  const closeFindBar = () => {
    setManualFind(false)
    setSeededFindQuery(undefined)
    if (search.has('find') || search.has('at')) {
      const next = new URLSearchParams(search)
      next.delete('find')
      next.delete('at')
      setSearch(next, { replace: true, preventScrollReset: true })
    }
  }
  const linkedComment = podRouteID(search.get('commentId') ?? undefined)
  useEffect(() => {
    if (!linkedComment) return
    focusComment(linkedComment)
    selectCommentThreads([])
    commentsMotion.prepare(true)
    setComments(true)
  }, [linkedComment])
  const assistantAvailable = useQuery(agentsQuery).data?.personalAssistantAvailable === true
  const selection = assistantAvailable ? search.get('chat') : null
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
  const drafts = useModel(
    () => new PageDraftModel(page.type, `ankole.pod.document-draft:${podID()}:${principalUID()}:${page.id}`)
  )
  drafts.load(page.id, detail.content?.content ?? '<page/>', page.revision, page.title)
  const titleDraft = drafts.title
  const model = drafts.body()
  const properties = drafts.properties()
  const documentTools = useModel(
    createModel(() => {
      const current =
        page.type === 'doc' && model
          ? new DocumentToolsModel(model, `ankole.pod.document-stats:${podID()}:${principalUID()}`)
          : undefined
      effect(() => () => current?.[Symbol.dispose]())
      return { read: () => current }
    })
  ).read()
  const exportDraft = () =>
    downloadDraft(
      model?.xml.value ?? '',
      titleDraft.value.value,
      model?.recoveryDrafts.value,
      properties?.editing.value ? properties.recovery.value : undefined
    )
  const readDraft = () => ({
    xml: model?.xml.value ?? '',
    title: titleDraft.value.value,
    revision: model?.revision.value ?? page.revision,
    hasUnsavedChanges: drafts.hasUnsavedChanges.value
  })
  const commentDrafts = useModel(
    () => new PageCommentsModel(`ankole.pod.comments:${podID()}:${principalUID()}:${page.id}`)
  )
  const documentContent = useRef<HTMLDivElement>(null)
  const pageColumn = useRef<HTMLDivElement>(null)
  const pageContent = useRef<HTMLDivElement>(null)
  const [presenceContainer, setPresenceContainer] = useState<HTMLDivElement | null>(null)
  const [insights, setInsights] = useState(false)
  const titleInput = useRef<HTMLTextAreaElement>(null)
  const [editorHandle, setEditorHandle] = useState<EditorHandle | null>(null)
  const documentEditor = useRef<Editor | null>(null)
  const filePreviewRef = useRef<FilePreviewHandle | null>(null)
  const attachEditor = (handle: EditorHandle | null) => {
    documentEditor.current = handle?.editor ?? null
    setEditorHandle(handle)
  }
  const unfoldDocumentHeadings = (): boolean => {
    const instance = documentEditor.current
    if (!instance) return false
    const folded = instance.state.field(foldedHeadings, false)
    if (folded?.size) {
      instance.dispatch({ effects: [...folded].map(pos => toggleHeading.of(pos)) })
      return true
    }
    return false
  }
  useEffect(() => {
    if (!domFindSupported || urlFind || urlTarget?.kind !== 'heading') return
    unfoldDocumentHeadings()
    const rootEl = pageContent.current
    if (!rootEl) return
    const needle = normalizeSearchQuery(urlTarget.heading.trim())
    if (!needle) return
    const timer = window.setTimeout(() => {
      unfoldDocumentHeadings()
      const headings = rootEl.querySelectorAll<HTMLElement>('h1, h2, h3, h4, h5, h6, [data-heading]')
      for (const el of headings) {
        const text = normalizeSearchQuery((el.textContent ?? '').trim())
        if (text === needle || text.includes(needle)) {
          el.scrollIntoView({ behavior: 'smooth', block: 'center' })
          break
        }
      }
    }, 60)
    return () => window.clearTimeout(timer)
  }, [domFindSupported, editorHandle, urlFind, urlTarget?.kind === 'heading' ? urlTarget.heading : ''])
  useEffect(() => {
    if (!domFindSupported) return
    const onKeyDown = (event: KeyboardEvent) => {
      if (!shouldHandlePageFindShortcut(event, pageColumn.current, document.activeElement)) return
      event.preventDefault()
      const selectedText = readSingleLineSelectionInContainer(pageContent.current)
      setSeededFindQuery(selectedText)
      setManualFind(true)
      setFindFocusTrigger(prev => prev + 1)
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [domFindSupported])
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
  const captureFileCommentSelection = (selection: FileCommentSelection) => {
    commentDrafts.capture({
      quote: selection.quote,
      fileAnchor: selection.anchor
    })
    openComments(selectionReturnThread.current)
    selectionReturnThread.current = null
  }
  const selectCommentAnchor = (threadID?: string) => {
    selectionReturnThread.current = threadID ?? focusedComment
    if (page.type === 'file') {
      const selection = filePreviewRef.current?.currentSelection()
      if (!selection) {
        if (isMobile) setComments(false)
        toast.info(
          t('pod.document.select_file_region', {
            defaultValue: 'Select lines, table rows, a Markdown section, or a media timestamp first'
          })
        )
        return
      }
      captureFileCommentSelection(selection)
      return
    }
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
  const dirty = drafts.hasUnsavedChanges.value
  const blocker = useBlocker({
    shouldBlockFn: ({ current, next }) => {
      if (!dirty || current.pathname === next.pathname) return false
      const currentPage = podPagePathnameID(current.pathname)
      return !currentPage || currentPage !== podPagePathnameID(next.pathname)
    },
    enableBeforeUnload: false,
    withResolver: true
  })
  useEffect(() => {
    if (!dirty && blocker.status === 'blocked') blocker.proceed?.()
  }, [dirty, blocker])
  useEffect(() => {
    const stop = effect(() => {
      // Persist local recovery data after edits, acknowledgements, and explicit discards.
      void drafts.recovery.value
      const timer = window.setTimeout(() => drafts.persist(), 250)
      return () => window.clearTimeout(timer)
    })
    const leave = (event: BeforeUnloadEvent) => {
      drafts.persist()
      if (drafts.hasUnsavedChanges.value) event.preventDefault()
    }
    const persist = () => drafts.persist()
    const visibility = () => {
      if (document.visibilityState === 'hidden') drafts.persist()
    }
    window.addEventListener('beforeunload', leave)
    window.addEventListener('pagehide', persist)
    document.addEventListener('visibilitychange', visibility)
    return () => {
      stop()
      drafts.persist()
      window.removeEventListener('beforeunload', leave)
      window.removeEventListener('pagehide', persist)
      document.removeEventListener('visibilitychange', visibility)
    }
  }, [drafts])
  const accessDenied = isRealtimeAccessDenied(loadError)
  const trashed = Boolean(page.deleted_at)
  const toolsAvailable = page.type === 'doc' && !accessDenied && !trashed
  const commentsAvailable = ['doc', 'knowledge', 'file'].includes(page.type) && !accessDenied && !trashed
  const commentSummary = useQuery({ ...pageCommentSummaryQuery(page.id), enabled: commentsAvailable })
  useEffect(() => {
    if (!toolsAvailable || !documentTools) return
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
  const edit = !trashed && actions.includes('node_edit') && !accessDenied
  const canRename = !accessDenied && canRenamePage({ ...page, actions })
  const canTrash = !accessDenied && canTrashPage({ ...page, actions })
  const canRestore = trashed && actions.includes('node_manage') && !accessDenied
  const canMove = !accessDenied && canMovePage({ ...page, actions })
  const contentDetail = trashed ? { ...detail, actions: ['node_view' as const] } : detail
  const restore = useMutation({
    mutationFn: () => pageAPI.restore(page.id),
    onSuccess: async ({ page }) => {
      pageCreated(client, page)
      await client.invalidateQueries({ queryKey: contentKeys.page(page.id) })
      toast.success(t('pod.content.page_restored'))
    }
  })
  const purge = usePagePurge(
    () =>
      void navigate(
        domain === 'brain'
          ? { to: '/meta/brain', search: { view: 'trash' } }
          : { to: podLocation('/content/trash').pathname }
      )
  )
  const domain = pageDomain(page, detail.ancestors)
  const favorites = useQuery(pagesQuery('favorites', '', domain))
  const favorited = favorites.data?.pages.some(favorite => favorite.id === page.id) ?? false
  const rename = useMutation({
    scope: { id: `page-title:${page.id}` },
    mutationFn: (title: string) => pageAPI.update(page.id, { title, expected_title: titleDraft.base.value }),
    onSuccess: ({ page }, submitted) => {
      titleDraft.acknowledge(page.title, submitted)
      updatePageMetadata(client, { id: page.id, title: page.title })
    },
    onError: error => {
      if (error instanceof InternalAPIError && requestErrorCode(error.payload) === 'title_conflict') {
        const current = requestErrorDetails(error.payload).title
        if (typeof current === 'string') titleDraft.reject(current)
      }
    }
  })
  const saveTitle = (retry = false) => {
    if (!canRename || titleDraft.conflict.value || rename.isPending) return
    const title = titleDraft.value.value.trim()
    if (!retry && rename.isError && rename.variables === title) return
    if (titleDraft.dirty.value) rename.mutate(title)
  }
  const title = titleDraft.value.value
  const autosaveTitle = useEffectEvent(() => saveTitle())
  useEffect(() => {
    if (!canRename || titleComposing) return
    const timer = window.setTimeout(autosaveTitle, 500)
    return () => window.clearTimeout(timer)
  }, [title, canRename, titleComposing, rename.isPending])
  const finishTitle = async () => {
    if (titleDraft.conflict.value) throw new Error(t('pod.document_title.conflict'))
    if (accessDenied || (!canRename && titleDraft.dirty.value)) {
      throw new Error(t('pod.content.could_not_confirm_your_editing_permission_reload_the_page_and'))
    }
    if (titleDraft.dirty.value) await rename.mutateAsync(titleDraft.value.value.trim())
  }
  const remove = usePageTrash(drafts.discard)
  const favorite = useMutation({
    mutationFn: () => pageAPI.state(page.id, { favorite: !favorited }),
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.list('favorites') })
  })
  const commentsPanel =
    comments && commentsAvailable ? (
      <PageComments
        key="comments"
        detail={detail}
        content={
          page.type === 'file'
            ? { kind: 'file' }
            : page.type === 'doc' && model
              ? { kind: 'document', editor: editorHandle, revision: model.revision, ready: model.bodyReady }
              : { kind: 'page' }
        }
        model={commentDrafts}
        mobile={isMobile}
        focused={focusedComment}
        selectedThreads={selectedCommentThreads}
        clearSelection={() => selectCommentThreads([])}
        focus={focusComment}
        close={closeComments}
        returnFocus={commentsTrigger}
        selectAnchor={selectCommentAnchor}
        reveal={(id, fileAnchor) => {
          focusComment(id)
          if (page.type === 'file') {
            return fileAnchor ? (filePreviewRef.current?.revealAnchor(fileAnchor) ?? null) : null
          }
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
        ref={pageColumn}
        data-sheet
        className="pod-page-main relative flex min-w-0 flex-1 flex-col bg-background md:paper-sheet md:overflow-hidden">
        <header className="pod-page-header sheet-header @container gap-2 border-b border-border max-md:gap-1 max-md:px-2">
          <SidebarTrigger
            className={sidebarState === 'expanded' ? 'md:hidden' : undefined}
            label={t('pod.sidebar.expand')}
          />
          <div className="flex min-w-0 flex-1 items-center gap-0.5">
            <ErrorBoundary variant="inline" resetKeys={[page.id]}>
              <PageBreadcrumbs ancestors={detail.ancestors} title={titleDraft.value.value} compact={isMobile} />
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
            {!accessDenied && !trashed && page.type !== 'doc' && page.type !== 'file' && (
              <PageChildrenMenu
                pageID={page.id}
                types={page.type === 'knowledge' ? ['knowledge', 'file'] : undefined}
                canCreate={canCreateChild({ ...page, actions })}
                scope={page.private_owner_uid ? 'private' : 'space'}
                privateOwner={page.private_owner_uid ?? undefined}
              />
            )}
            {!accessDenied && !trashed && assistantAvailable && (
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
            {!accessDenied && !trashed && commentsAvailable && (
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
            {!accessDenied && !trashed && <PageLearningButton detail={contentDetail} />}
            {!accessDenied && !trashed && page.type === 'applet' && (
              <Suspense fallback={null}>
                <AppletAutomationControl detail={contentDetail} />
              </Suspense>
            )}
            {commentsAvailable && isMobile && !comments && focusedComment && (
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
                    draft={model!}
                    title={titleDraft.value}
                    model={documentTools!}
                    mobile={isMobile}
                    openInsights={() => setInsights(true)}
                    openComments={() => openComments()}
                    openHistory={edit ? () => setHistory(true) : undefined}
                  />
                )}
                {canTrash && (
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
          <DocumentHistory
            detail={detail}
            readDraft={readDraft}
            close={() => setHistory(false)}
            returnFocus={actionsTrigger}
          />
        )}
        {purging && (
          <PermanentDeletePageDialog
            page={page}
            pending={purge.isPending}
            onCancel={() => setPurging(false)}
            onConfirm={() => purge.mutate(page)}
          />
        )}
        {moving && canMove && (
          <MovePageDialog
            page={{ ...page, actions }}
            beforeMove={finishTitle}
            close={() => setMoving(false)}
            returnFocus={actionsTrigger}
          />
        )}
        {findBarOpen && (
          <PageFindBar
            root={pageContent}
            initialQuery={urlFind}
            seededQuery={seededFindQuery}
            focusTrigger={findFocusTrigger}
            targetHeading={urlTarget?.kind === 'heading' ? urlTarget.heading : undefined}
            autoFocus={manualFind && !urlFind}
            onBeforeSearch={unfoldDocumentHeadings}
            onClose={closeFindBar}
          />
        )}
        <div className="pod-page-scroll min-h-0 flex-1 overflow-auto">
          <div
            ref={pageContent}
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
            {drafts.storageError.value && dirty && (
              <Alert variant="warning" className="mb-6" role="alert">
                <AlertDescription>{t('pod.document_title.storage_unavailable')}</AlertDescription>
                <AlertAction>
                  <Button size="sm" variant="outline" onClick={() => exportDraft()}>
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
              {canRename ? (
                <div className="min-w-0 flex-1">
                  <textarea
                    ref={titleInput}
                    aria-label={t('pod.content.page_title')}
                    rows={1}
                    value={titleDraft.value.value}
                    autoFocus={(page.type === 'doc' || page.type === 'base') && !page.title && !chat}
                    disabled={remove.isPending || accessDenied}
                    placeholder={t('pod.content.untitled')}
                    onChange={event =>
                      (titleDraft.value.value = limitPageTitle(
                        event.target.value.replace(/\n/g, ' '),
                        titleDraft.value.value
                      ))
                    }
                    onCompositionStart={() => setTitleComposing(true)}
                    onCompositionEnd={() => setTitleComposing(false)}
                    onKeyDown={event => {
                      if (titleComposing || event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return
                      if (event.key === 'Enter') {
                        event.preventDefault()
                        if (!focusWorkspaceStart(documentEditor.current, pageContent.current)) {
                          event.currentTarget.blur()
                        }
                        return
                      }
                      if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return
                      if (event.key === 'Tab') {
                        if (focusEditorStart(documentEditor.current)) event.preventDefault()
                        return
                      }
                      if (event.key === 'ArrowDown' && isCaretOnLastTitleLine(event.currentTarget)) {
                        if (focusWorkspaceStart(documentEditor.current, pageContent.current)) {
                          event.preventDefault()
                        }
                      }
                    }}
                    className="pod-page-title"
                    onBlur={() => saveTitle()}
                  />
                </div>
              ) : (
                <h1 className="pod-page-title">
                  <BdiLabel value={page.title} fallback={t('pod.content.untitled')} />
                </h1>
              )}
            </div>
            {!!loadError && drafts.hasUnsavedChanges.value && (
              <p className="mb-3 text-sm">{t('pod.content.could_not_load_the_latest_page_state_your_unsaved_draft')}</p>
            )}
            <ContentError error={loadError} retry={accessDenied ? undefined : reload} />
            {accessDenied && <LocalPageChatDrafts pageID={page.id} />}
            {accessDenied && dirty && (
              <Button variant="outline" size="sm" onClick={() => exportDraft()}>
                {t('pod.content.export_draft')}
              </Button>
            )}
            {canRename && (
              <p role="status" className="sr-only">
                {rename.isPending
                  ? t('pod.content.saving_title')
                  : titleDraft.dirty.value
                    ? t('pod.content.title_not_saved')
                    : ''}
              </p>
            )}
            {titleDraft.conflict.value ? (
              <div role="alert" className="mb-3 rounded border border-warning p-3 text-sm">
                <p>{t('pod.document_title.conflict')}</p>
                <p className="mt-1 break-words">{t('pod.document_title.current', { title: titleDraft.saved.value })}</p>
                <div className="mt-2 flex gap-2">
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => {
                      titleDraft.review(true)
                      rename.reset()
                    }}>
                    {t('pod.document_title.use_current')}
                  </Button>
                  {canRename && (
                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() => {
                        titleDraft.review(false)
                        saveTitle(true)
                      }}>
                      {t('pod.document_title.save_draft')}
                    </Button>
                  )}
                </div>
              </div>
            ) : (
              <ContentError
                error={rename.error}
                retry={canRename && titleDraft.dirty.value ? () => saveTitle(true) : undefined}
              />
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
                    !trashed && contentDetail.child_count > 0 && !edit && isDocumentBodyEmpty(model!.xml.value)
                  return (
                    <>
                      <ErrorBoundary
                        variant="panel"
                        resetKeys={[page.id, page.revision]}
                        actions={
                          model!.hasUnsavedChanges.value ? (
                            <Button type="button" size="sm" onClick={() => exportDraft()}>
                              {t('pod.content.export_draft')}
                            </Button>
                          ) : undefined
                        }>
                        <div ref={documentContent} className={hideEmptyViewerBody ? 'hidden' : undefined}>
                          <DocumentPage
                            detail={contentDetail}
                            model={model!}
                            title={titleDraft.value}
                            presenceContainer={presenceContainer}
                            onEditor={attachEditor}
                            resolvedCommentIDs={commentSummary.data?.resolved_ids ?? []}
                            onComment={ids => openComments(ids[0] ?? null, ids.length > 1 ? ids : [])}
                            onRequestComment={captureCommentSelection}
                            onAskAgent={!accessDenied && !trashed && assistantAvailable ? askAgent : undefined}
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
                  {page.type === 'knowledge' && model && properties ? (
                    <KnowledgePage
                      detail={contentDetail}
                      body={model}
                      draft={properties}
                      readTitle={() => titleDraft.value.value}
                      hasUnsavedChanges={() => drafts.hasUnsavedChanges.value}
                    />
                  ) : (
                    <PageContent
                      detail={contentDetail}
                      onRequestFileComment={!accessDenied && !trashed ? captureFileCommentSelection : undefined}
                      filePreviewRef={filePreviewRef}
                      searchFind={urlFind || undefined}
                      searchTarget={urlTarget}
                    />
                  )}
                </ErrorBoundary>
              ))}
          </div>
          {toolsAvailable && !isMobile && (
            <ErrorBoundary variant="inline" resetKeys={[page.id]}>
              <DocumentStats model={documentTools!} content={documentContent} />
            </ErrorBoundary>
          )}
        </div>
      </div>
      {isMobile
        ? commentsPanel
        : commentsAvailable &&
          (comments || !chat) && <PodPanelPresence animate={commentsMotion.animate}>{commentsPanel}</PodPanelPresence>}
      {!accessDenied && !trashed && !comments && assistantAvailable && (
        <PageChat
          mobile={isMobile}
          pageID={page.id}
          pageTitle={titleDraft.value.value}
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
                exportDraft()
                blocker.proceed?.()
              }}>
              {t('pod.content.download_draft_and_leave')}
            </Button>
            <Button
              variant="destructive"
              onClick={() => {
                drafts.discard()
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

function focusElement(target: HTMLElement | null | undefined): boolean {
  if (!target) return false
  target.focus()
  return document.activeElement === target
}

function focusWorkspaceStart(editor: Editor | null, root: HTMLElement | null): boolean {
  if (focusEditorStart(editor)) return true
  if (!root) return false
  const cellEditor = root.querySelector<HTMLTextAreaElement>('[data-spreadsheet-cell-editor]')
  if (focusElement(cellEditor)) return true
  const baseTarget =
    root.querySelector<HTMLElement>(
      '.pod-base-grid [data-grid-record] :is(input, [role="combobox"], textarea, button):not(:disabled)'
    ) ??
    root.querySelector<HTMLElement>('.pod-base-grid .pod-base-add-row button:not(:disabled)') ??
    root.querySelector<HTMLElement>('.pod-base-grid')
  return focusElement(baseTarget)
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
