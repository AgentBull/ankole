import { Button } from '@ankole/uikit'
import {
  useEffect,
  useImperativeHandle,
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

export type CompletionOption = { id: string; group?: string; content: ReactNode; choose(): void }
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
      if (event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return false
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
        return true
      }
      if (event.key === 'Tab' && (event.shiftKey || !options.length)) {
        onClose()
        return false
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
    <div className="pod-chat-composer-picker">
      <div ref={list} id={id} role="listbox" aria-label={t('pod.chat_room.completion_results')}>
        {!options.length && (
          <p className="pod-chat-completion-empty" role="status">
            {t(loading ? 'common.loading' : 'pod.chat_room.no_matches')}
          </p>
        )}
        {options.map((option, position) => (
          <div key={option.id}>
            {option.group && option.group !== options[position - 1]?.group && (
              <div className="pod-chat-completion-group">{option.group}</div>
            )}
            <button
              type="button"
              id={`${id}-${position}`}
              role="option"
              aria-selected={position === index}
              tabIndex={-1}
              className="pod-chat-completion-option"
              onPointerDown={event => event.preventDefault()}
              onPointerMove={() => setSelection({ query, index: position, armed: false })}
              onClick={option.choose}>
              {option.content}
            </button>
          </div>
        ))}
      </div>
      {children}
      <div className="pod-chat-completion-footer">
        <span>{t('pod.chat_room.completion_hint')}</span>
        <Button size="xs" variant="ghost" onPointerDown={event => event.preventDefault()} onClick={onClose}>
          {t('common.close')}
        </Button>
      </div>
    </div>
  )
}
