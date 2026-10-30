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
import { RiAddLine, RiCloseLine, RiExternalLinkLine, RiHistoryLine } from '@remixicon/react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { lazy, Suspense, useEffect, useLayoutEffect, useState, useRef, type CSSProperties, type RefObject } from 'react'
import { Link } from '@tanstack/react-router'
import { podLocation } from '../common/browser-context'
import { ErrorBoundary, ErrorFallback } from '../common/error-boundary'
import { pageConversationsQuery, podKeys } from './api'
import { useRoomActions } from './chat/room-api'
import { ContentError } from './content-primitives'
import { isRealtimeAccessDenied } from './realtime'
import { useChatDrafts } from './chat-drafts'
import { PodPanelPresence, PodPanelSurface, type PanelInputEvent } from './panel-motion'
import './chat.css'

const ChatPage = lazy(() => import('./chat-page').then(module => ({ default: module.ChatPage })))

export function PageChat({
  mobile,
  pageID,
  pageTitle,
  selection,
  animate,
  select,
  returnFocus
}: {
  mobile: boolean
  pageID: string
  pageTitle: string
  selection: string | null
  animate: boolean
  select(id: string | null, flushSync?: boolean, event?: PanelInputEvent): void
  returnFocus: RefObject<HTMLElement | null>
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const drafts = useChatDrafts()
  const currentSelection = useRef(selection)
  useLayoutEffect(() => {
    currentSelection.current = selection
  }, [selection])
  // Keep the current conversation on the sheet until its close transition ends.
  const [displayedSelection, setDisplayedSelection] = useState(selection)
  if (selection && selection !== displayedSelection) setDisplayedSelection(selection)
  const selected = selection ?? displayedSelection
  const chats = useQuery({ ...pageConversationsQuery(pageID), enabled: !!selection })
  const accessDenied = isRealtimeAccessDenied(chats.error)
  const conversationID = selected === 'latest' || selected === 'new' ? undefined : (selected ?? undefined)
  const [width, setWidth] = useState(400)
  const [newScope, setNewScope] = useState<'participants' | 'anchor_page'>('participants')
  const resizing = useRef<{ x: number; width: number } | undefined>(undefined)
  const actions = useRoomActions(conversationID ?? '')
  const selectedChat = chats.data?.conversations.find(chat => chat.id === conversationID)
  useEffect(() => {
    // Read current drafts on each open, even when the closed panel stays mounted.
    if (selection === 'latest' && chats.data) {
      const unfinished = drafts.unfinishedPageConversation(pageID)
      if (unfinished || !chats.isFetching) select(unfinished ?? chats.data.conversations[0]?.id ?? 'new')
    }
  }, [selection, chats.data, chats.isFetching, drafts, pageID, select])
  const exitConversation = () => {
    void client.invalidateQueries({ queryKey: podKeys.pageConversations(pageID) })
    if (currentSelection.current) select('new', true)
  }
  const header = (
    <header className="pod-page-chat-header" title={pageTitle}>
      <div className="sheet-header gap-0.5">
        <h2 className="sheet-title">{t('pod.page_chat.title')}</h2>
        <div className="pod-page-chat-scope">
          <Select
            value={selectedChat?.accessScope ?? newScope}
            onValueChange={value => {
              if (value !== 'participants' && value !== 'anchor_page') return
              if (conversationID) actions.update.mutate({ accessScope: value })
              else setNewScope(value)
            }}
            disabled={accessDenied || actions.update.isPending || (!!conversationID && !selectedChat?.canManage)}>
            <SelectTrigger size="sm" variant="ghost" aria-label={t('pod.chat_room.visibility')}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="participants">{t('pod.chat_room.scope_participants')}</SelectItem>
              <SelectItem value="anchor_page">{t('pod.chat_room.scope_anchor_page')}</SelectItem>
            </SelectContent>
          </Select>
        </div>
        <Button
          size="icon-xs"
          variant="ghost"
          aria-label={t('pod.chat.new_conversation')}
          title={t('pod.chat.new_conversation')}
          disabled={accessDenied}
          onClick={() => select('new', true)}>
          <RiAddLine aria-hidden />
        </Button>
        <Select
          value={conversationID ?? 'new'}
          onValueChange={id => id && select(id, true)}
          disabled={chats.isPending || accessDenied}>
          <SelectTrigger
            aria-label={t('pod.page_chat.choose_chat')}
            title={t('pod.page_chat.choose_chat')}
            className="pod-page-chat-switcher"
            variant="ghost"
            size="sm">
            <RiHistoryLine aria-hidden />
            <SelectValue className="sr-only" />
          </SelectTrigger>
          <SelectContent align="end" className="pod-page-chat-history-menu">
            <SelectItem value="new">{t('pod.chat.new_conversation')}</SelectItem>
            {(chats.data?.conversations ?? []).map(chat => (
              <SelectItem key={chat.id} value={chat.id}>
                {chat.title}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        {conversationID && (
          <Button
            size="icon-xs"
            variant="ghost"
            aria-label={t('pod.page_chat.open_chat')}
            render={<Link to={podLocation(`/conversations/${conversationID}`).pathname} />}
            nativeButton={false}>
            <RiExternalLinkLine aria-hidden />
          </Button>
        )}
        <Button
          size="icon-xs"
          variant="ghost"
          aria-label={t('pod.page_chat.close')}
          onClick={event => select(null, true, event)}>
          <RiCloseLine aria-hidden />
        </Button>
      </div>
      {chats.data && chats.error && !accessDenied && (
        <ContentError error={chats.error} retry={() => void chats.refetch()} />
      )}
    </header>
  )
  const body =
    chats.error && (!chats.data || accessDenied) ? (
      <>
        {header}
        <div className="p-4">
          <ContentError error={chats.error} retry={() => void chats.refetch()} />
        </div>
      </>
    ) : chats.isPending || selected === 'latest' ? (
      <>
        {header}
        <p role="status" className="p-4 text-sm">
          {t('pod.chat.loading_history')}
        </p>
      </>
    ) : (
      <ErrorBoundary
        resetKeys={[pageID, conversationID ?? 'new']}
        fallback={({ error, reset }) => (
          <>
            {header}
            <div className="p-4">
              <ErrorFallback variant="panel" error={error} reset={reset} />
            </div>
          </>
        )}>
        <Suspense
          fallback={
            <>
              {header}
              <p role="status" className="p-4 text-sm">
                {t('pod.chat.loading_history')}
              </p>
            </>
          }>
          <ChatPage
            key={conversationID ?? 'new'}
            conversationID={conversationID}
            pageID={pageID}
            accessScope={newScope}
            pageHeader={header}
            pageChat={{
              pageTitle,
              conversations: chats.data?.conversations ?? [],
              conversationsPending: chats.isPending,
              listError: chats.data && chats.error && !accessDenied ? chats.error : undefined,
              onRetryList: () => void chats.refetch(),
              accessDenied,
              onSelectConversation: id => select(id, true),
              onNewConversation: () => select('new', true),
              onClose: event => select(null, true, event)
            }}
            onNewConversation={() => select('new', true)}
            onExitConversation={exitConversation}
            onConversationStarted={id => {
              if (currentSelection.current) select(id)
            }}
          />
        </Suspense>
      </ErrorBoundary>
    )
  if (mobile) {
    return (
      <Sheet open={!!selection} onOpenChange={open => !open && select(null, true)}>
        <SheetContent className="pod-page-chat-sheet" showCloseButton={false} finalFocus={returnFocus}>
          <SheetTitle className="sr-only">{t('pod.page_chat.title')}</SheetTitle>
          {body}
        </SheetContent>
      </Sheet>
    )
  }
  return (
    <PodPanelPresence animate={animate && !accessDenied}>
      {selection && (
        <PodPanelSurface
          key="page-chat"
          aria-label={t('pod.page_chat.title')}
          data-sheet
          className="pod-page-chat paper-sheet"
          style={{ '--pod-page-chat-width': `${width}px` } as CSSProperties}>
          <div
            role="separator"
            tabIndex={0}
            aria-label={t('pod.chat_room.resize_chat')}
            aria-orientation="vertical"
            aria-valuemin={360}
            aria-valuemax={480}
            aria-valuenow={width}
            className="pod-page-chat-resize"
            onPointerDown={event => {
              resizing.current = { x: event.clientX, width }
              event.currentTarget.setPointerCapture(event.pointerId)
              event.preventDefault()
            }}
            onPointerMove={event => {
              if (resizing.current) {
                setWidth(Math.max(360, Math.min(480, resizing.current.width + resizing.current.x - event.clientX)))
              }
            }}
            onPointerUp={() => {
              resizing.current = undefined
            }}
            onPointerCancel={() => {
              resizing.current = undefined
            }}
            onKeyDown={event => {
              if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
                event.preventDefault()
                setWidth(current => Math.max(360, Math.min(480, current + (event.key === 'ArrowLeft' ? 10 : -10))))
              }
            }}
          />
          {body}
        </PodPanelSurface>
      )}
    </PodPanelPresence>
  )
}
