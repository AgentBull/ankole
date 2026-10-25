import { Button } from '@ankole/uikit'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useLayoutEffect, useRef, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { conversationDetail } from './api/generated/sdk.gen'
import { conversationQuery, podKeys, type ConversationDetail } from './api'
import { ContentError } from './content-primitives'
import { mergeMessageWindow } from './state/message-history'
import type { StickToBottomInstance } from 'use-stick-to-bottom'
import type { ChatModel, ChatPresentation, ChatReadingPosition, DisplayMessage } from './state/chat'

export function useChatHistory(id: string | undefined, detail: ConversationDetail | undefined) {
  const client = useQueryClient()
  const anchor = useRef<{ element: HTMLElement; height: number; top: number } | null>(null)
  const jumpToMatch = useRef<((range: Range) => void) | undefined>(undefined)
  const load = useMutation({
    mutationFn: async (element: HTMLElement | null) => {
      if (!id) return
      const current = client.getQueryData<ConversationDetail>(podKeys.detail(id))
      const before = current?.olderMessagesBeforeSeq
      if (before == null) return
      const older = await client.fetchQuery({
        ...conversationQuery(id),
        queryKey: [...podKeys.detail(id), 'before', before],
        queryFn: ({ signal }) => conversationDetail({ path: { id }, query: { beforeSeq: before }, signal }),
        staleTime: 0,
        gcTime: 0
      })
      if (element?.isConnected) anchor.current = { element, height: element.scrollHeight, top: element.scrollTop }
      client.setQueryData<ConversationDetail>(podKeys.detail(id), latest =>
        latest ? mergeMessageWindow(latest, older, true) : undefined
      )
    }
  })
  useLayoutEffect(() => {
    const position = anchor.current
    if (!position) return
    position.element.scrollTop = position.top + position.element.scrollHeight - position.height
    anchor.current = null
  }, [detail?.messages])
  return {
    ...load,
    jumpToMatch,
    hasOlder: detail?.olderMessagesBeforeSeq != null,
    loadedCount: detail?.messages.length ?? 0
  }
}

export function OlderMessages({
  history,
  scrollRef
}: {
  history: ReturnType<typeof useChatHistory>
  scrollRef: RefObject<HTMLElement | null>
}) {
  const { t } = useTranslation()
  if (!history.hasOlder && !history.error) return null
  return (
    <div className="pod-chat-older-messages">
      <Button variant="ghost" size="sm" disabled={history.isPending} onClick={() => history.mutate(scrollRef.current)}>
        {t(history.isPending ? 'pod.chat.loading_history' : 'pod.chat.load_earlier')}
      </Button>
      <ContentError error={history.error} />
    </div>
  )
}

export function messageID(message: DisplayMessage) {
  return message.type === 'committed' ? message.message.id : message.message.messageID
}

export function useChatReading(
  model: InstanceType<typeof ChatModel>,
  presentation: ChatPresentation,
  { scrollRef, contentRef, state, stopScroll, scrollToBottom }: StickToBottomInstance,
  messageKeys: string,
  jumpToMatch: ReturnType<typeof useChatHistory>['jumpToMatch']
) {
  const position = useRef<ChatReadingPosition | undefined>(model.reading.peek()[presentation])
  const elements = useRef<HTMLElement[]>([])
  const byID = useRef(new Map<string, HTMLElement>())

  const capture = () => {
    const scroll = scrollRef.current
    if (!scroll || !elements.current.length) return
    let next: ChatReadingPosition
    if (state.isNearBottom || (state.isAtBottom && state.animation)) {
      next = { atBottom: true }
    } else {
      const top = scroll.getBoundingClientRect().top
      let low = 0
      let high = elements.current.length - 1
      // Message order is stable. Measure only the search path on each scroll.
      while (low < high) {
        const middle = Math.floor((low + high) / 2)
        if (elements.current[middle]!.getBoundingClientRect().bottom <= top) low = middle + 1
        else high = middle
      }
      const element = elements.current[low]!
      next = {
        atBottom: false,
        messageID: element.dataset.chatMessageId!,
        offset: element.getBoundingClientRect().top - top
      }
    }
    position.current = next
    model.rememberReading(presentation, next)
  }
  const restore = () => {
    const saved = position.current
    const scroll = scrollRef.current
    if (!scroll || saved?.atBottom !== false || state.isAtBottom) return
    const element = byID.current.get(saved.messageID)
    if (!element) {
      position.current = undefined
      model.rememberReading(presentation, undefined)
      void scrollToBottom('instant')
      return
    }
    const difference = element.getBoundingClientRect().top - scroll.getBoundingClientRect().top - saved.offset
    if (Math.abs(difference) > 0.5) state.scrollTop += difference
  }
  const callbacks = useRef({ capture, restore })
  callbacks.current = { capture, restore }

  useLayoutEffect(() => {
    jumpToMatch.current = range => {
      const scroll = scrollRef.current
      if (!scroll) return
      stopScroll()
      state.scrollTop +=
        range.getBoundingClientRect().top - scroll.getBoundingClientRect().top - scroll.clientHeight / 2
      callbacks.current.capture()
    }
    return () => {
      jumpToMatch.current = undefined
    }
  }, [jumpToMatch, scrollRef, state, stopScroll])

  useLayoutEffect(() => {
    const scroll = scrollRef.current
    const content = contentRef.current
    if (!scroll || !content) return
    if (position.current?.atBottom === false) stopScroll()
    const onScroll = () => callbacks.current.capture()
    scroll.addEventListener('scroll', onScroll, { passive: true })
    const observer = new ResizeObserver(() => callbacks.current.restore())
    observer.observe(scroll)
    observer.observe(content)
    return () => {
      callbacks.current.capture()
      observer.disconnect()
      scroll.removeEventListener('scroll', onScroll)
    }
  }, [contentRef, scrollRef, stopScroll])

  useLayoutEffect(() => {
    elements.current = Array.from(contentRef.current?.querySelectorAll<HTMLElement>('[data-chat-message-id]') ?? [])
    byID.current = new Map(elements.current.map(element => [element.dataset.chatMessageId!, element]))
    callbacks.current.restore()
  }, [contentRef, messageKeys])
}
