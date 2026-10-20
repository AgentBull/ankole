import { Button } from '@ankole/uikit/components/button'
import { Input } from '@ankole/uikit/components/input'
import {
  RiBold,
  RiCloseLine,
  RiCodeLine,
  RiItalic,
  RiLink,
  RiMarkPenLine,
  RiStrikethrough,
  RiUnderline
} from '@remixicon/react'
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Command } from '../core/command'
import type { Mark, Plot } from '../core/doc'
import type { Wordgard } from '../core/editor'
import browser from '../core/editor/browser'
import { GardSelection, type GardState } from '../core/state'
import * as T from '../core/types'
import { toggleFormat, type FormatName } from '../editor/commands'
import { linkAt, removeLink, setLink, type LinkInfo } from '../editor/links'
import { formats } from '../editor/schema'
import { editorPhrases } from '../editor/phrases'
import type { PhraseSet } from '../core/phrases'
import { useEditor, useEditorLabel, useEditorState } from './context'

const buttons = [
  { format: 'strong', label: editorPhrases.ref('bold'), Icon: RiBold },
  { format: 'em', label: editorPhrases.ref('italic'), Icon: RiItalic },
  { format: 'u', label: editorPhrases.ref('underline'), Icon: RiUnderline },
  { format: 's', label: editorPhrases.ref('strikethrough'), Icon: RiStrikethrough },
  { format: 'code', label: editorPhrases.ref('inline_code'), Icon: RiCodeLine }
] satisfies { format: FormatName; label: PhraseSet.Ref; Icon: typeof RiBold }[]

/** The address for the link form input, or null when it is not a usable address (SPEC §7.6). */
function linkUrl(value: string) {
  const url = value.trim()
  if (/^(https?:\/\/|mailto:|tel:|\/|#)/i.test(url)) return url
  if (/^[^\s/:]+\.[^\s/:]+(?:[/?#].*)?$/.test(url)) return `https://${url}`
  return null
}

/** Whether every inline node in the range that can carry the format has it. */
function hasFormat(doc: Plot.Doc, from: number, to: number, mark: Mark) {
  let found = false,
    missing = false
  doc.iterate(from, to, node => {
    if (missing) return false
    if (node.isLeaf && node.isInline && doc.schema.markAllowed(mark.type, node.type)) {
      if (mark.isInSet(node.marks)) found = true
      else missing = true
    }
  })
  return found && !missing
}

type Range = { from: number; to: number }

/** The selected range that the toolbar formats: non-blank text outside code blocks. */
function formattable(state: GardState): Range | null {
  const { selection, doc } = state
  if (!(selection instanceof GardSelection.Text) || selection.empty) return null
  const { from, to } = selection
  if (!doc.textContent({ from, to }).trim()) return null
  let code = false
  doc.iterate(from, to, node => {
    if (node.type === T.CodeBlock.type) code = true
    return !code
  })
  return code ? null : { from, to }
}

/** The part of the viewport that shows editor content: inside scrolling ancestors, below the editor toolbar. */
function visibleArea(editor: Wordgard) {
  let top = 0,
    bottom = window.innerHeight
  for (let element = editor.dom.parentElement; element && element !== document.body; element = element.parentElement) {
    if (getComputedStyle(element).overflowY === 'visible') continue
    const rect = element.getBoundingClientRect()
    top = Math.max(top, rect.top)
    bottom = Math.min(bottom, rect.bottom)
  }
  const toolbar = editor.dom.closest('.ankole-editor')?.querySelector('.editor-toolbar')
  if (toolbar) top = Math.max(top, toolbar.getBoundingClientRect().bottom)
  return { top, bottom }
}

/** The rectangle of the selection: the DOM range that the editor shows, or the document positions. */
function selectionRect(editor: Wordgard, { from, to }: Range) {
  const dom = window.getSelection()
  if (
    dom?.rangeCount &&
    !dom.isCollapsed &&
    editor.contentDOM.contains(dom.anchorNode) &&
    editor.contentDOM.contains(dom.focusNode)
  ) {
    return dom.getRangeAt(0).getBoundingClientRect()
  }
  const start = editor.coordsAtPos(from, 1),
    end = editor.coordsAtPos(to, -1)
  const left = Math.min(start.left, end.left),
    top = Math.min(start.top, end.top)
  return new DOMRect(left, top, Math.max(start.right, end.right) - left, Math.max(start.bottom, end.bottom) - top)
}

const composingKey = (event: KeyboardEvent) => event.isComposing || event.keyCode === 229

type Info = { rect: DOMRect; active: boolean[]; highlight: boolean; link: boolean }
/** The open link form, with the link that it edits, if any. */
type LinkForm = { link: LinkInfo | null }

export function SelectionToolbar() {
  const label = useEditorLabel()
  const editor = useEditor()
  const state = useEditorState()
  const toolbar = useRef<HTMLDivElement>(null)
  const [info, setInfo] = useState<Info | null>(null)
  const [linkForm, setLinkForm] = useState<LinkForm | null>(null)
  const [url, setUrl] = useState('')
  const [error, setError] = useState(false)
  const [position, setPosition] = useState({ left: 0, top: 0 })
  const form = useRef<LinkForm | null>(null)
  form.current = linkForm
  // The selection that Escape hid the toolbar for. Another selection shows it again.
  const dismissed = useRef<GardSelection | null>(null)
  const refresh = useRef(() => {})

  // ⌘K and the link button: edit the selected text, or the link at the caret.
  const openLink = () => {
    const { state } = editor
    const range = formattable(state)
    const link = linkAt(state)
    const target = range ?? (state.selection.empty ? link : null)
    if (!target) return false
    setLinkForm({ link })
    setUrl(link?.href ?? '')
    setError(false)
    setInfo(info => info ?? { rect: selectionRect(editor, target), active: [], highlight: false, link: !!link })
    return true
  }

  const closeLink = () => {
    setLinkForm(null)
    setError(false)
    editor.focus()
  }

  useEffect(() => {
    let frame = 0,
      pointer = false,
      composing = false
    const update = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => {
        // The toolbar keeps its place while the user works in it.
        if (toolbar.current?.contains(document.activeElement)) return
        const focused = document.activeElement === editor.contentDOM
        // The link form takes focus right after it opens.
        if (form.current && focused) return
        const { state } = editor
        const range = formattable(state)
        if (!range || !focused || pointer || composing || editor.composing || dismissed.current?.eq(state.selection)) {
          setInfo(null)
          setLinkForm(null)
          return
        }
        dismissed.current = null
        const rect = selectionRect(editor, range)
        const area = visibleArea(editor)
        if ((!rect.width && !rect.height) || rect.bottom < area.top || rect.top > area.bottom) {
          setInfo(null)
          return
        }
        setInfo({
          rect,
          active: buttons.map(({ format }) => hasFormat(state.doc, range.from, range.to, formats[format])),
          highlight: hasFormat(state.doc, range.from, range.to, formats.mark),
          link: !!linkAt(state)
        })
      })
    }
    refresh.current = update
    const content = editor.contentDOM
    const pointerDown = () => {
      pointer = true
      update()
    }
    const pointerUp = () => {
      pointer = false
      update()
    }
    const compositionStart = () => {
      composing = true
      setLinkForm(null)
      update()
    }
    const compositionEnd = () => {
      composing = false
      update()
    }
    const key = (event: KeyboardEvent) => {
      if (event.defaultPrevented || composingKey(event) || editor.composing) return
      // ⌘K on Apple platforms, where Ctrl+K deletes to the end of the line; Ctrl+K elsewhere.
      const mod = browser.mac ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey
      if (event.key === 'Escape') {
        if (formattable(editor.state)) {
          dismissed.current = editor.state.selection
          update()
        }
      } else if (event.altKey && event.key === 'F10') {
        const button = toolbar.current?.querySelector('button')
        if (button) {
          event.preventDefault()
          button.focus()
        }
      } else if (mod && !event.altKey && !event.shiftKey && event.key.toLowerCase() === 'k') {
        if (openLink()) event.preventDefault()
      }
    }
    document.addEventListener('focusin', update)
    document.addEventListener('focusout', update)
    document.addEventListener('pointerup', pointerUp)
    content.addEventListener('pointerdown', pointerDown)
    content.addEventListener('compositionstart', compositionStart)
    content.addEventListener('compositionend', compositionEnd)
    content.addEventListener('keydown', key)
    window.addEventListener('scroll', update, true)
    window.addEventListener('resize', update)
    window.visualViewport?.addEventListener('resize', update)
    window.visualViewport?.addEventListener('scroll', update)
    return () => {
      cancelAnimationFrame(frame)
      document.removeEventListener('focusin', update)
      document.removeEventListener('focusout', update)
      document.removeEventListener('pointerup', pointerUp)
      content.removeEventListener('pointerdown', pointerDown)
      content.removeEventListener('compositionstart', compositionStart)
      content.removeEventListener('compositionend', compositionEnd)
      content.removeEventListener('keydown', key)
      window.removeEventListener('scroll', update, true)
      window.removeEventListener('resize', update)
      window.visualViewport?.removeEventListener('resize', update)
      window.visualViewport?.removeEventListener('scroll', update)
    }
    // `openLink` reads only the editor and state setters, which do not change.
  }, [editor])

  // Each editor update can change the selection, its formats or its place.
  useEffect(() => refresh.current(), [state])

  useLayoutEffect(() => {
    if (!info || !toolbar.current) return
    const { width, height } = toolbar.current.getBoundingClientRect()
    const viewport = window.visualViewport
    const minX = (viewport?.offsetLeft ?? 0) + 8
    const maxX = minX + (viewport?.width ?? window.innerWidth) - 16
    const minY = Math.max(viewport?.offsetTop ?? 0, visibleArea(editor).top) + 8
    const maxY = (viewport?.offsetTop ?? 0) + (viewport?.height ?? window.innerHeight) - 8
    const { rect } = info
    setPosition({
      left: Math.max(minX, Math.min(rect.left + rect.width / 2 - width / 2, maxX - width)),
      top: rect.top - height - 8 >= minY ? rect.top - height - 8 : Math.min(rect.bottom + 8, maxY - height)
    })
  }, [editor, info, linkForm, error])

  const apply = (format: FormatName) => {
    toggleFormat(editor, format)
    editor.focus()
  }

  const submitLink = () => {
    const href = linkUrl(url)
    if (!href) {
      setError(true)
      return
    }
    Command.dispatch(editor, setLink, { href })
    closeLink()
  }

  if (!info) return null
  return createPortal(
    <div
      ref={toolbar}
      className="selection-toolbar ankole-editor-overlay ceramic"
      style={position}
      role={linkForm ? 'dialog' : 'toolbar'}
      aria-label={label(linkForm ? 'edit_link' : 'selection_format')}
      onKeyDown={event => {
        if (composingKey(event.nativeEvent)) return
        if (event.key === 'Escape') {
          event.preventDefault()
          event.stopPropagation()
          if (linkForm) closeLink()
          else {
            dismissed.current = editor.state.selection
            setInfo(null)
            editor.focus()
          }
        } else if (!linkForm && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
          const all = [...event.currentTarget.querySelectorAll('button')]
          const index = all.indexOf(document.activeElement as HTMLButtonElement)
          const next =
            event.key === 'Home'
              ? 0
              : event.key === 'End'
                ? all.length - 1
                : (index + (event.key === 'ArrowRight' ? 1 : -1) + all.length) % all.length
          event.preventDefault()
          all[next]?.focus()
        }
      }}>
      {linkForm ? (
        <form
          className="link-form"
          onSubmit={event => {
            event.preventDefault()
            submitLink()
          }}>
          <div className="link-form-row">
            <Input
              autoFocus
              aria-label={label('link_address')}
              value={url}
              placeholder={label('link_placeholder')}
              aria-invalid={!!error}
              onChange={event => {
                setUrl(event.target.value)
                setError(false)
              }}
              onKeyDown={event => {
                if (event.key === 'Enter' && composingKey(event.nativeEvent)) event.preventDefault()
              }}
            />
            <Button type="submit" size="xs">
              {label('apply_link')}
            </Button>
            <Button type="button" variant="ghost" size="icon-xs" aria-label={label('cancel_link')} onClick={closeLink}>
              <RiCloseLine />
            </Button>
          </div>
          {error && <p role="alert">{label('invalid_link')}</p>}
          {linkForm.link && (
            <Button
              type="button"
              variant="ghost"
              size="xs"
              onClick={() => {
                Command.dispatch(editor, removeLink)
                closeLink()
              }}>
              {label('remove_link')}
            </Button>
          )}
        </form>
      ) : (
        <>
          {buttons.map(({ format, label, Icon }, index) => (
            <Button
              key={format}
              variant="ghost"
              size="icon-xs"
              aria-label={label(state)}
              title={label(state)}
              aria-pressed={info.active[index]}
              onMouseDown={event => event.preventDefault()}
              onClick={() => apply(format)}>
              <Icon />
            </Button>
          ))}
          <span className="toolbar-divider" />
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label={label('link')}
            title={`${label('link')} ⌘/Ctrl+K`}
            aria-pressed={info.link}
            onMouseDown={event => event.preventDefault()}
            onClick={openLink}>
            <RiLink />
          </Button>
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label={label('highlight')}
            title={label('highlight')}
            aria-pressed={info.highlight}
            onMouseDown={event => event.preventDefault()}
            onClick={() => apply('mark')}>
            <RiMarkPenLine />
          </Button>
        </>
      )}
    </div>,
    document.body
  )
}
