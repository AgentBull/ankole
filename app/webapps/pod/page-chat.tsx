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
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { lazy, Suspense, useEffect, useState, type RefObject } from 'react'
import { Link } from '@tanstack/react-router'
import { podLocation } from '../common/browser-context'
import { pageConversationsQuery } from './api'
import { ContentError } from './content-primitives'
import { isRealtimeAccessDenied } from './realtime'
import { useChatDrafts } from './chat-drafts'
import './chat.css'

const ChatPage = lazy(() => import('./chat-page').then(module => ({ default: module.ChatPage })))

export function PageChat({
  mobile,
  pageID,
  pageTitle,
  selection,
  select,
  returnFocus
}: {
  mobile: boolean
  pageID: string
  pageTitle: string
  selection: string | null
  select(id: string | null, flushSync?: boolean): void
  returnFocus: RefObject<HTMLElement | null>
}) {
  const { t } = useTranslation()
  const drafts = useChatDrafts()
  // Keep the current conversation on the sheet until its close transition ends.
  const [displayedSelection, setDisplayedSelection] = useState(selection)
  if (selection && selection !== displayedSelection) setDisplayedSelection(selection)
  const selected = selection ?? displayedSelection
  const chats = useQuery({ ...pageConversationsQuery(pageID), enabled: !!selection })
  const accessDenied = isRealtimeAccessDenied(chats.error)
  const conversationID = selected === 'latest' || selected === 'new' ? undefined : (selected ?? undefined)
  const selectedChat = chats.data?.conversations.find(chat => chat.id === conversationID)
  useEffect(() => {
    // Read current drafts on each open, even when the closed panel stays mounted.
    if (selection === 'latest' && chats.data) {
      const unfinished = drafts.unfinishedPageConversation(pageID)
      if (unfinished || !chats.isFetching) select(unfinished ?? chats.data.conversations[0]?.id ?? 'new')
    }
  }, [selection, chats.data, chats.isFetching, drafts, pageID, select])
  const header = (
    <header className="pod-page-chat-header">
      <div className="pod-page-chat-heading">
        {mobile ? (
          <SheetTitle className="pod-page-chat-title">{t('pod.page_chat.title')}</SheetTitle>
        ) : (
          <h2 className="pod-page-chat-title">{t('pod.page_chat.title')}</h2>
        )}
        <Button
          size="icon-sm"
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
            size="icon-sm"
            variant="ghost"
            aria-label={t('pod.page_chat.open_chat')}
            render={<Link to={podLocation(`/conversations/${conversationID}`).pathname} />}
            nativeButton={false}>
            <RiExternalLinkLine aria-hidden />
          </Button>
        )}
        <Button size="icon-sm" variant="ghost" aria-label={t('pod.page_chat.close')} onClick={() => select(null, true)}>
          <RiCloseLine aria-hidden />
        </Button>
      </div>
      {selectedChat && (
        <h3 className="pod-page-chat-selected-title" title={selectedChat.title}>
          {selectedChat.title}
        </h3>
      )}
      <p className="pod-page-chat-context" title={pageTitle}>
        {t('pod.page_chat.context_page')}: {pageTitle || t('pod.content.untitled')}
      </p>
      {chats.data && chats.error && !accessDenied && (
        <ContentError error={chats.error} retry={() => void chats.refetch()} />
      )}
    </header>
  )
  const body =
    chats.error && (!chats.data || accessDenied) ? (
      <div className="p-4">
        <ContentError error={chats.error} retry={() => void chats.refetch()} />
      </div>
    ) : chats.isPending || selected === 'latest' ? (
      <p role="status" className="p-4 text-sm">
        {t('pod.chat.loading_history')}
      </p>
    ) : (
      <Suspense
        fallback={
          <p role="status" className="p-4 text-sm">
            {t('pod.chat.loading_history')}
          </p>
        }>
        <ChatPage
          key={conversationID ?? 'new'}
          conversationID={conversationID}
          pageID={pageID}
          onConversationStarted={id => {
            if (selection) select(id)
          }}
        />
      </Suspense>
    )
  if (mobile) {
    return (
      <Sheet open={!!selection} onOpenChange={open => !open && select(null, true)}>
        <SheetContent className="pod-page-chat-sheet" showCloseButton={false} finalFocus={returnFocus}>
          {header}
          {body}
        </SheetContent>
      </Sheet>
    )
  }
  if (!selection) return null
  return (
    <aside aria-label={t('pod.page_chat.title')} className="pod-page-chat">
      {header}
      {body}
    </aside>
  )
}
