import { Button, Input } from '@ankole/uikit'
import { RiArrowUpSLine, RiArrowDownSLine, RiCloseLine } from '@remixicon/react'
import { useEffect, useRef, useState, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { ContentError } from '../content-primitives'
import type { useChatHistory } from '../chat-history'

/** Keep matches across inline markup and highlighted code in one message. */
export function conversationFindRanges(root: HTMLElement, query: string): Range[] {
  if (!query.trim()) return []
  const ranges: Range[] = []
  for (const message of root.querySelectorAll('[data-chat-message-id]')) {
    const nodes: Text[] = [],
      offsets: number[] = []
    let text = ''
    const walker = document.createTreeWalker(message, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        return node.parentElement?.closest(
          'button, [aria-hidden="true"], [hidden], details:not([open]) > :not(summary)'
        )
          ? NodeFilter.FILTER_REJECT
          : NodeFilter.FILTER_ACCEPT
      }
    })
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      nodes.push(node as Text)
      offsets.push(text.length)
      text += node.textContent
    }
    const search = text.toLocaleLowerCase(),
      needle = query.toLocaleLowerCase()
    for (let offset = search.indexOf(needle); offset !== -1; offset = search.indexOf(needle, offset + needle.length)) {
      const range = document.createRange()
      const start = offsets.findLastIndex(position => position <= offset)
      const endOffset = offset + needle.length
      const end = offsets.findLastIndex(position => position < endOffset)
      range.setStart(nodes[start]!, offset - offsets[start]!)
      range.setEnd(nodes[end]!, endOffset - offsets[end]!)
      ranges.push(range)
    }
  }
  return ranges
}

export function SessionFindBar({
  root,
  history,
  inputRef,
  onClose
}: {
  root: RefObject<HTMLElement | null>
  history: ReturnType<typeof useChatHistory>
  inputRef?: RefObject<HTMLInputElement | null>
  onClose(): void
}) {
  const { t } = useTranslation()
  const [query, setQuery] = useState(''),
    [index, setIndex] = useState(0),
    [count, setCount] = useState(0)
  const indexRef = useRef(index)
  const selected = useRef<Range | undefined>(undefined)
  const located = useRef(false)
  const search = (step: number | 'new' | 'refresh') => {
    const element = root.current
    const ranges = element ? conversationFindRanges(element, query) : []
    const current = selected.current
    const retained = current
      ? ranges.findIndex(
          range =>
            range.startContainer === current.startContainer &&
            range.startOffset === current.startOffset &&
            range.endContainer === current.endContainer &&
            range.endOffset === current.endOffset
        )
      : -1
    let next = retained >= 0 ? retained : Math.min(indexRef.current, Math.max(0, ranges.length - 1))
    if (step === 'new') {
      located.current = false
      const top = element?.getBoundingClientRect().top ?? 0
      next = Math.max(
        0,
        ranges.findIndex(range => range.getBoundingClientRect().bottom > top)
      )
    } else if (typeof step === 'number' && ranges.length) next = (next + step + ranges.length) % ranges.length
    indexRef.current = next
    selected.current = ranges[next]
    const firstMatch = !located.current && !!ranges[next]
    if (ranges[next]) located.current = true
    setIndex(next)
    setCount(ranges.length)
    if ('highlights' in CSS) {
      CSS.highlights.set('pod-chat-find', new Highlight(...ranges))
      CSS.highlights.set('pod-chat-find-current', new Highlight(...ranges.slice(next, next + 1)))
    }
    if ((step !== 'refresh' || firstMatch) && ranges[next]) {
      history.jumpToMatch.current?.(ranges[next]!)
    }
  }
  const searchRef = useRef(search)
  searchRef.current = search
  useEffect(() => {
    searchRef.current('new')
  }, [query])
  useEffect(() => {
    const element = root.current
    if (!element) return
    let timer: ReturnType<typeof setTimeout> | undefined
    const observer = new MutationObserver(() => {
      timer ??= setTimeout(() => {
        timer = undefined
        searchRef.current('refresh')
      }, 150)
    })
    observer.observe(element, {
      characterData: true,
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['open']
    })
    return () => {
      observer.disconnect()
      clearTimeout(timer)
      if ('highlights' in CSS) {
        CSS.highlights.delete('pod-chat-find')
        CSS.highlights.delete('pod-chat-find-current')
      }
    }
  }, [root])
  return (
    <div className="pod-chat-find" role="search">
      <Input
        ref={inputRef}
        autoFocus
        value={query}
        aria-label={t('pod.chat_room.find')}
        placeholder={t('pod.chat_room.find')}
        onChange={event => setQuery(event.target.value)}
        onKeyDown={event => {
          if (event.nativeEvent.isComposing) return
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
