import { composingKey } from '@ankole/uikit/lib/keyboard'
import { Button, MenuFooter } from '@ankole/uikit'
import {
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
  type Ref,
  type RefObject
} from 'react'
import { useTranslation } from 'react-i18next'

export type ComposerCompletion = { kind: 'mention' | 'page' | 'slash'; start: number; end: number; query: string }
export type CompletionHandle = { onKeyDown(event: KeyboardEvent<HTMLTextAreaElement>): boolean }

export function insertCompletionTrigger(
  value: string,
  selectionStart: number,
  selectionEnd: number,
  kind: ComposerCompletion['kind']
): { value: string; completion: ComposerCompletion; cursor: number } {
  const rawStart = Math.max(0, Math.min(selectionStart, value.length))
  const rawEnd = Math.max(rawStart, Math.min(selectionEnd, value.length))
  const previous = rawStart > 0 ? value[rawStart - 1]! : ''
  const needsSpace =
    kind === 'slash' ? !!previous && !/\s/.test(previous) : !!previous && /[\p{L}\p{N}_@]/u.test(previous)
  const prefix = needsSpace ? ' ' : ''
  const trigger = kind === 'slash' ? '/' : '@'
  const start = rawStart + prefix.length
  const cursor = start + 1
  return {
    value: `${value.slice(0, rawStart)}${prefix}${trigger}${value.slice(rawEnd)}`,
    completion: { kind, start, end: cursor, query: '' },
    cursor
  }
}

export function completionAt(
  text: string,
  start: number,
  end = start,
  active?: ComposerCompletion
): ComposerCompletion | undefined {
  if (start !== end) return
  const before = text.slice(0, start)
  const mention = /(?:^|[^A-Za-z0-9_@])@([^\s@]*)$/.exec(before)
  if (mention) return { kind: 'mention', start: start - mention[1]!.length - 1, end: start, query: mention[1]! }
  const slash = /(?:^|\n)\/([^\s/]*)$/.exec(before)
  if (slash) return { kind: 'slash', start: start - slash[1]!.length - 1, end: start, query: slash[1]! }
  if (active && start > active.start) {
    const token = text.slice(active.start, start)
    const match = (active.kind === 'slash' ? /^\/([^\s/]*)$/ : /^@([^@\r\n]*)$/).exec(token)
    if (match) return { ...active, end: start, query: match[1]! }
  }
}

/** Enter waits for results that are still loading, so the composer never sends the typed query as a message. */
export function holdsEnter(event: Pick<KeyboardEvent, 'key' | 'shiftKey'>, loading: boolean, optionCount: number) {
  return event.key === 'Enter' && !event.shiftKey && loading && optionCount === 0
}

export type CompletionOption = { id: string; group?: string; content: ReactNode; choose(): void }

export function ComposerMenuHighlight() {
  const ref = useRef<HTMLSpanElement>(null)
  useLayoutEffect(() => {
    const marker = ref.current
    const menu = marker?.parentElement
    if (!marker || !menu) return

    let current: HTMLElement | null = null
    const place = () => {
      const active = menu.querySelector<HTMLElement>(
        '[role="option"][aria-selected="true"], [data-highlighted]:not([data-disabled])'
      )
      if (current !== active) {
        if (current) sizes.unobserve(current)
        if (active) sizes.observe(active)
        current = active
      }
      marker.toggleAttribute('data-visible', !!active)
      if (!active) return
      let top = active.offsetTop
      for (
        let parent = active.offsetParent;
        parent instanceof HTMLElement && parent !== menu;
        parent = parent.offsetParent
      ) {
        top += parent.offsetTop + parent.clientTop
      }
      marker.style.translate = `0 ${top}px`
      marker.style.height = `${active.offsetHeight}px`
    }
    const sizes = new ResizeObserver(place)
    const changes = new MutationObserver(place)
    sizes.observe(menu)
    changes.observe(menu, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['aria-selected', 'data-highlighted', 'data-disabled']
    })
    place()
    return () => {
      sizes.disconnect()
      changes.disconnect()
    }
  }, [])

  return <span ref={ref} aria-hidden className="pod-chat-completion-highlight" />
}

export function ComposerCompletionList({
  id,
  query,
  options,
  input,
  handle,
  onClose,
  children,
  enterSelects = true,
  loading = false
}: {
  id: string
  query: string
  options: CompletionOption[]
  input: RefObject<HTMLTextAreaElement | null>
  handle: Ref<CompletionHandle>
  onClose(): void
  children?: ReactNode
  enterSelects?: boolean
  loading?: boolean
}) {
  const { t } = useTranslation()
  const [selection, setSelection] = useState({ query, index: 0, armed: false })
  const index = selection.query === query ? Math.min(selection.index, Math.max(options.length - 1, 0)) : 0
  const list = useRef<HTMLDivElement>(null)
  const activeID = options[index] ? `${id}-${index}` : undefined
  useEffect(() => {
    const editor = input.current
    if (activeID) {
      editor?.setAttribute('aria-activedescendant', activeID)
      list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
    }
    return () => editor?.removeAttribute('aria-activedescendant')
  }, [activeID, query, input])
  useImperativeHandle(handle, () => ({
    onKeyDown(event) {
      if (composingKey(event.nativeEvent)) return false
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
        return true
      }
      if (event.key === 'Tab' && (event.shiftKey || !options.length)) {
        onClose()
        return false
      }
      if (holdsEnter(event, loading, options.length)) {
        event.preventDefault()
        return true
      }
      if (!options.length || event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return false
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault()
        setSelection({
          query,
          index: (index + (event.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length,
          armed: true
        })
        return true
      }
      if (
        event.key === 'Tab' ||
        (event.key === 'Enter' && (enterSelects || (selection.query === query && selection.armed)))
      ) {
        event.preventDefault()
        options[index]!.choose()
        return true
      }
      return false
    }
  }))
  return (
    <div className="pod-chat-composer-picker composer-menu">
      <div ref={list} id={id} role="listbox" aria-label={t('pod.chat_room.completion_results')}>
        <ComposerMenuHighlight />
        {!options.length && (
          <p className="px-4 py-3 text-sm text-muted-foreground" role="status">
            {t(loading ? 'common.loading' : 'pod.chat_room.no_matches')}
          </p>
        )}
        {options.map((option, position) => (
          <div key={option.id}>
            {option.group && option.group !== options[position - 1]?.group && (
              <div className="menu-group-label">{option.group}</div>
            )}
            <button
              type="button"
              id={`${id}-${position}`}
              role="option"
              aria-selected={position === index}
              tabIndex={-1}
              className="flex min-h-10 w-full items-center gap-2.5 px-2.5 py-2 text-start text-sm leading-5 aria-selected:bg-layer-hover"
              onPointerDown={event => event.preventDefault()}
              onPointerMove={() => setSelection({ query, index: position, armed: false })}
              onClick={option.choose}>
              {option.content}
            </button>
          </div>
        ))}
      </div>
      {children}
      <MenuFooter>
        <span>{t('pod.chat_room.completion_hint')}</span>
        <Button size="xs" variant="ghost" onPointerDown={event => event.preventDefault()} onClick={onClose}>
          {t('common.close')}
        </Button>
      </MenuFooter>
    </div>
  )
}
