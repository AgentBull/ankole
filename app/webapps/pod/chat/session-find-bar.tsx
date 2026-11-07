import { Button, Input } from '@ankole/uikit'
import { RiArrowUpSLine, RiArrowDownSLine, RiCloseLine } from '@remixicon/react'
import { useEffect, useRef, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { ContentError } from '../content-primitives'
import type { useChatHistory } from '../chat-history'
import {
  buildSearchableTextIndex,
  collectRangesFromTextIndex,
  isImeComposingKey,
  useDomFindController,
  type SearchableTextIndex
} from '../find-bar'

function buildConversationMessageIndexes(root: HTMLElement): SearchableTextIndex[] {
  const indexes: SearchableTextIndex[] = []
  for (const message of root.querySelectorAll('[data-chat-message-id]')) {
    indexes.push(buildSearchableTextIndex(message))
  }
  return indexes
}

export function SessionFindBar({
  root,
  history,
  inputRef: externalInputRef,
  initial,
  seededQuery,
  focusTrigger = 0,
  onClose
}: {
  root: RefObject<HTMLElement | null>
  history: ReturnType<typeof useChatHistory>
  inputRef?: RefObject<HTMLInputElement | null>
  /** Opens with a query, and selects its first match inside `messageID` when that message is loaded. */
  initial?: { query: string; messageID?: string }
  seededQuery?: string
  focusTrigger?: number
  onClose(): void
}) {
  const { t } = useTranslation()
  const targetMessage = useRef(initial?.messageID)
  const messageIndexesRef = useRef<SearchableTextIndex[] | null>(null)

  useEffect(() => {
    targetMessage.current = initial?.messageID
  }, [initial?.messageID])

  const { query, setQuery, index, count, inputRef, search } = useDomFindController({
    root,
    inputRef: externalInputRef,
    initialQuery: initial?.query ?? '',
    seededQuery,
    focusTrigger,
    targetKey: initial?.messageID ?? '',
    highlightKeys: ['pod-chat-find', 'pod-chat-find-current'],
    attributeFilter: ['open'],
    debounceMs: 150,
    invalidateCache: () => {
      messageIndexesRef.current = null
    },
    collectRanges: (element, activeQuery) => {
      messageIndexesRef.current ??= buildConversationMessageIndexes(element)
      const ranges: Range[] = []
      for (const msgIndex of messageIndexesRef.current) {
        ranges.push(...collectRangesFromTextIndex(msgIndex, activeQuery))
      }
      return ranges
    },
    resolveInitialIndex: (element, ranges, step) => {
      if (targetMessage.current) {
        const target = element.querySelector(`[data-chat-message-id="${CSS.escape(targetMessage.current)}"]`)
        const inTarget = target ? ranges.findIndex(range => target.contains(range.startContainer)) : -1
        if (inTarget >= 0) {
          targetMessage.current = undefined
          return inTarget
        }
      }
      if (step === 'new') {
        const top = element.getBoundingClientRect().top
        return Math.max(
          0,
          ranges.findIndex(range => range.getBoundingClientRect().bottom > top)
        )
      }
      return undefined
    },
    scrollToRange: range => {
      history.jumpToMatch.current?.(range)
    }
  })

  return (
    <div className="pod-chat-find" role="search">
      <Input
        ref={inputRef}
        variant="overlay"
        autoFocus
        value={query}
        autoCorrect="off"
        autoCapitalize="off"
        spellCheck={false}
        aria-label={t('pod.chat_room.find')}
        placeholder={t('pod.chat_room.find')}
        onChange={event => setQuery(event.target.value)}
        onKeyDown={event => {
          if (isImeComposingKey(event)) return
          if (event.key === 'Escape') {
            event.stopPropagation()
            onClose()
          }
          if (event.key === 'Enter') {
            event.preventDefault()
            search(event.shiftKey ? -1 : 1)
          }
        }}
      />
      <span aria-live="polite">
        {count ? index + 1 : 0}/{count}
        {query.trim() && history.hasOlder ? '+' : ''}
      </span>
      {!!query.trim() && history.hasOlder && (
        <Button size="sm" variant="ghost" disabled={history.isPending} onClick={() => history.mutate(null)}>
          {t(history.isPending ? 'pod.chat_room.find_loading_history' : 'pod.chat_room.find_load_older', {
            count: history.loadedCount
          })}
        </Button>
      )}
      <ContentError error={history.error} retry={() => history.mutate(null)} />
      <Button
        size="icon-xs"
        variant="ghost"
        disabled={!count}
        aria-label={t('pod.chat_room.previous_match')}
        onClick={() => search(-1)}>
        <RiArrowUpSLine aria-hidden />
      </Button>
      <Button
        size="icon-xs"
        variant="ghost"
        disabled={!count}
        aria-label={t('pod.chat_room.next_match')}
        onClick={() => search(1)}>
        <RiArrowDownSLine aria-hidden />
      </Button>
      <Button size="icon-xs" variant="ghost" aria-label={t('common.close')} onClick={onClose}>
        <RiCloseLine aria-hidden />
      </Button>
    </div>
  )
}
