import { composingKey } from '@ankole/uikit/lib/keyboard'
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Leaf, Node } from '../core/doc'
import { Wordgard } from '../core/editor'
import { GardSelection, GardState, Transaction } from '../core/state'
import { PhraseSet } from '../core/phrases'
import { applyBlockType } from '../editor/block-actions'
import { filterBlockOptions, type BlockOption, type BlockType } from '../editor/block-catalog'
import { mentionField } from '../editor/mention'
import { BlockTypeItems } from './block-type-items'
import { useAnchoredOverlay, type OverlayPosition } from './anchored-overlay'
import { useEditor, useEditorLabel, useEditorState } from './context'

/*
 * The slash menu (SPEC §7.6). `/` opens it at the start of a text run (for example right after bold
 * text or a link), or after whitespace or `(`, outside code blocks. In compact or narrow editors, a
 * corner `/` trigger can also open it at the current selection and morph the menu surface out of
 * that button. The query after `/` has at most 75 characters and can include spaces, but not line
 * breaks or punctuation. The menu state is a field of the editor state, so key handling and
 * rendering read the same value.
 */
const query = /(?:^|[\s(])\/([^\r\n\t.,+*?$|#{}()^\-[\]\\/!%'"~=<>_:;]{0,75})$/
const pinnedQueryPattern = /^[^\r\n\t.,+*?$|#{}()^\-[\]\\/!%'"~=<>_:;]{0,75}$/

type Slash = {
  /** The position of `/` (or the caret position where the corner trigger opened the menu, or null on non-text selections). */
  from: number | null
  /** The caret, at the end of the query. */
  to: number | null
  query: string
  options: readonly BlockOption[]
  /** The highlighted option. */
  index: number
  /** True when opened from the compact corner `/` trigger rather than a literal `/` character. */
  pinned?: boolean
}

const highlight = Transaction.Effect.define<number>()
const dismiss = Transaction.Effect.define<null>()
const openPinned = Transaction.Effect.define<number | null>()

function find(state: GardState, previous: Slash | null): Slash | null {
  const { selection } = state
  if (state.readOnly || !(selection instanceof GardSelection.Text) || !selection.empty) return null
  if (state.field(mentionField, false)) return null
  const head = state.sel.head
  if (!head.parent.node.isTextblock || head.parent.node.type.hasRole(Node.Role.Code)) return null
  // The text run that holds the caret, up to the caret.
  const run = head.inText ? head.parent.node.content[head.index] : head.nodeBefore
  if (!run?.is(Leaf.Text)) return null
  const match = query.exec(head.inText ? run.param.slice(0, head.inText) : run.param)
  if (!match) return null
  const text = match[1]!.toLowerCase()
  const options = filterBlockOptions(state, text)
  // A query without matches keeps the menu open on its empty row until the query takes a space.
  if (!options.length && /\s/.test(text)) return null
  const from = selection.head - match[1]!.length - 1
  const index =
    previous && previous.from === from && previous.query === match[1] ? Math.min(previous.index, options.length - 1) : 0
  return { from, to: selection.head, query: match[1]!, options, index }
}

function updatePinned(state: GardState, tr: Transaction, previous: Slash): Slash | null {
  if (state.readOnly || state.field(mentionField, false)) return null
  if (previous.from === null) {
    if (tr.docChanged || tr.selection) return null
    const options = filterBlockOptions(state, '')
    return {
      ...previous,
      options,
      index: Math.min(previous.index, Math.max(0, options.length - 1))
    }
  }
  const { selection } = state
  if (!(selection instanceof GardSelection.Text) || !selection.empty) return null
  const from = tr.docChanged ? tr.changes.mapPos(previous.from, -1) : previous.from
  if (selection.head < from) return null
  if (tr.selection && !tr.docChanged && selection.head !== (previous.to ?? from)) return null
  const head = state.sel.head
  if (!head.parent.node.isTextblock || head.parent.node.type.hasRole(Node.Role.Code)) return null
  const fromBlock = state.doc.resolve(from).textblockParent
  const toBlock = head.textblockParent
  if (!fromBlock || !toBlock || fromBlock.before !== toBlock.before) return null
  const rawQuery = state.doc.textContent({ from, to: selection.head })
  if (!pinnedQueryPattern.test(rawQuery)) return null
  const text = rawQuery.toLowerCase()
  const options = filterBlockOptions(state, text)
  if (!options.length && /\s/.test(text)) return null
  const index = previous.query === rawQuery ? Math.min(previous.index, Math.max(0, options.length - 1)) : 0
  return { from, to: selection.head, query: rawQuery, options, index, pinned: true }
}

const slashField = GardState.Field.define<Slash | null>({
  create: state => find(state, null),
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(dismiss)) return null
      // A hover can report a row of a list that React has not yet redrawn for the latest query.
      if (effect.is(highlight) && value && effect.value < value.options.length) return { ...value, index: effect.value }
      if (effect.is(openPinned)) {
        if (tr.state.readOnly || tr.state.field(mentionField, false)) return null
        const options = filterBlockOptions(tr.state, '')
        return {
          from: effect.value,
          to: effect.value,
          query: '',
          options,
          index: 0,
          pinned: true
        }
      }
    }
    const focus = tr.annotation(Wordgard.isFocusChange)
    if (focus === false) return null
    // Escape keeps the menu closed until the text, the caret or the focus changes.
    if (
      focus === undefined &&
      !tr.docChanged &&
      !tr.selection &&
      !PhraseSet.didChange(tr.state, tr.startState) &&
      tr.state.readOnly === tr.startState.readOnly
    ) {
      return value
    }
    const literal = find(tr.state, value)
    if (literal) return literal
    if (value?.pinned) return updatePinned(tr.state, tr, value)
    return null
  }
})

const optionId = (wg: Wordgard, index: number) => `${wg.contentDOM.id}-slash-${index}`

/** Delete the query and apply the block type at the caret, as one undo step. */
function choose(wg: Wordgard, type: BlockType) {
  const menu = wg.state.field(slashField, false)
  if (!menu) return
  if (menu.pinned) wg.dispatch({ effects: dismiss.of(null) })
  applyBlockType(wg, type, menu.from !== null && menu.to !== null ? { from: menu.from, to: menu.to } : undefined)
  wg.focus()
}

const keys = Wordgard.domEventHandler('keydown', (event, wg) => {
  const menu = wg.state.field(slashField, false)
  if (!menu || composingKey(event) || wg.composing) return false
  if (event.ctrlKey || event.metaKey || event.altKey) return false
  const count = menu.options.length
  if (event.key === 'Escape') {
    wg.dispatch({ effects: dismiss.of(null) })
    return true
  }
  if (menu.pinned && menu.query === '' && event.key === 'Backspace') {
    wg.dispatch({ effects: dismiss.of(null) })
    return true
  }
  // Without options, the empty row takes no keys and Enter or Tab edits the text as usual.
  if (!count) return false
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    const step = event.key === 'ArrowDown' ? 1 : -1
    wg.dispatch({ effects: highlight.of((menu.index + step + count) % count) })
    return true
  }
  if ((event.key === 'Enter' || event.key === 'Tab') && !event.shiftKey) {
    choose(wg, menu.options[menu.index]!.type)
    return true
  }
  return false
})

/** The slash menu state, its keys and the accessibility attributes of the editable element. */
export const slashMenu: GardState.Extension = [
  slashField,
  GardState.prec.highest(keys),
  Wordgard.contentAttributes.of((wg): Record<string, string | null> => {
    const menu = wg.hasFocus ? wg.state.field(slashField, false) : null
    if (!menu?.options.length) return { 'aria-autocomplete': 'list' }
    return {
      'aria-autocomplete': 'list',
      'aria-controls': `${wg.contentDOM.id}-slash`,
      'aria-activedescendant': optionId(wg, menu.index)
    }
  })
]

const CORNER_SIZE = 36
const CORNER_MARGIN = 14
const CLOSE_MORPH_MS = 210

type CornerPlacement = {
  left: number
  top: number
  right: number
  bottom: number
  roomAbove: number
}

function measureCornerPlacement(container: HTMLElement | null): CornerPlacement | null {
  if (!container || typeof window === 'undefined') return null
  const rect = container.getBoundingClientRect()
  if (rect.width <= 0 || rect.height <= 0) return null
  const viewport = window.visualViewport
  const vpLeft = viewport?.offsetLeft ?? 0
  const vpTop = viewport?.offsetTop ?? 0
  const vpRight = vpLeft + (viewport?.width ?? window.innerWidth)
  const vpBottom = vpTop + (viewport?.height ?? window.innerHeight)

  const visLeft = Math.max(rect.left, vpLeft)
  const visRight = Math.min(rect.right, vpRight)
  const visTop = Math.max(rect.top, vpTop)
  const visBottom = Math.min(rect.bottom, vpBottom)
  if (visRight - visLeft < 72 || visBottom - visTop < 52) return null

  const right = Math.max(visLeft + CORNER_SIZE + 8, visRight - CORNER_MARGIN)
  const bottom = Math.max(visTop + CORNER_SIZE + 8, visBottom - CORNER_MARGIN)
  return {
    left: right - CORNER_SIZE,
    top: bottom - CORNER_SIZE,
    right,
    bottom,
    roomAbove: Math.max(140, bottom - vpTop - 12)
  }
}

function prefersReducedMotion(): boolean {
  return typeof window !== 'undefined' && typeof window.matchMedia === 'function'
    ? window.matchMedia('(prefers-reduced-motion: reduce)').matches
    : false
}

function toggleCornerSlash(editor: Wordgard) {
  if (editor.state.readOnly) return
  if (editor.state.field(slashField, false)) {
    editor.dispatch({ effects: dismiss.of(null) })
    editor.focus()
    return
  }
  editor.focus()
  const { state } = editor
  const { selection } = state
  if (selection instanceof GardSelection.Text) {
    const head = state.sel.head
    if (head.parent.node.isTextblock && !head.parent.node.type.hasRole(Node.Role.Code)) {
      const at = selection.to
      editor.dispatch({
        ...(selection.empty ? {} : { selection: GardSelection.cursor(at) }),
        effects: openPinned.of(at)
      })
      return
    }
  }
  editor.dispatch({ effects: openPinned.of(null) })
}

type ClosingSnapshot = {
  options: readonly BlockOption[]
  index: number
  corner: CornerPlacement
  position: OverlayPosition
}

export function SlashMenu({
  compact = false,
  container
}: {
  compact?: boolean
  container?: HTMLElement | null
} = {}) {
  const label = useEditorLabel()
  const editor = useEditor()
  const menu = useEditorState(state => (editor.hasFocus ? (state.field(slashField, false) ?? null) : null))
  const list = useRef<HTMLDivElement>(null)
  const [corner, setCorner] = useState<CornerPlacement | null>(null)
  const [morph, setMorph] = useState<'closed' | 'open' | 'closing'>('closed')
  const [closingSnapshot, setClosingSnapshot] = useState<ClosingSnapshot | null>(null)
  const closeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useLayoutEffect(() => {
    if (!compact || !container) {
      setCorner(null)
      return
    }
    let frame = 0
    const update = () => {
      const next = measureCornerPlacement(container)
      setCorner(prev =>
        prev && next && prev.left === next.left && prev.top === next.top && prev.roomAbove === next.roomAbove
          ? prev
          : next
      )
    }
    const schedule = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(update)
    }
    update()
    window.addEventListener('scroll', schedule, true)
    window.addEventListener('resize', schedule)
    window.visualViewport?.addEventListener('resize', schedule)
    window.visualViewport?.addEventListener('scroll', schedule)
    const observer = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(schedule) : undefined
    observer?.observe(container)
    return () => {
      cancelAnimationFrame(frame)
      window.removeEventListener('scroll', schedule, true)
      window.removeEventListener('resize', schedule)
      window.visualViewport?.removeEventListener('resize', schedule)
      window.visualViewport?.removeEventListener('scroll', schedule)
      observer?.disconnect()
    }
  }, [compact, container])

  const useCornerOrigin = Boolean(compact && corner)
  const from = menu?.from
  const count = menu?.options.length

  const caretPosition = useAnchoredOverlay({
    open: menu !== null && !useCornerOrigin,
    panelRef: list,
    anchor: () => {
      if (from === undefined) return null
      if (from === null) return editor.contentDOM.getBoundingClientRect()
      return editor.coordsAtPos(from, 1)
    },
    onClose: menu?.pinned ? () => editor.dispatch({ effects: dismiss.of(null) }) : undefined,
    dependencies: [from, count, useCornerOrigin]
  })

  const [cornerMenuPosition, setCornerMenuPosition] = useState<OverlayPosition>(null)

  useLayoutEffect(() => {
    if (!menu || !useCornerOrigin || !corner || !list.current) {
      if (!menu) setCornerMenuPosition(null)
      return
    }
    const place = () => {
      const panel = list.current
      if (!panel) return
      const width = panel.offsetWidth
      const height = panel.offsetHeight
      const viewport = window.visualViewport
      const minX = (viewport?.offsetLeft ?? 0) + 8
      const minY = (viewport?.offsetTop ?? 0) + 8
      setCornerMenuPosition(prev => {
        const left = Math.max(minX, corner.right - width)
        const top = Math.max(minY, corner.bottom - height)
        return prev && prev.left === left && prev.top === top ? prev : { left, top }
      })
    }
    place()
    const observer = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(place) : undefined
    observer?.observe(list.current)
    return () => observer?.disconnect()
  }, [menu, useCornerOrigin, corner, count])

  useEffect(() => {
    if (!menu || !useCornerOrigin) return
    const outside = (event: PointerEvent) => {
      const target = event.target as Element | null
      if (!target || list.current?.contains(target) || target.closest('[data-slash-corner-trigger]')) return
      editor.dispatch({ effects: dismiss.of(null) })
    }
    document.addEventListener('pointerdown', outside, true)
    return () => document.removeEventListener('pointerdown', outside, true)
  }, [editor, menu, useCornerOrigin])

  const lastOpenRef = useRef<ClosingSnapshot | null>(null)
  if (menu && useCornerOrigin && corner && cornerMenuPosition) {
    lastOpenRef.current = {
      options: menu.options,
      index: menu.index,
      corner,
      position: cornerMenuPosition
    }
  }

  useLayoutEffect(() => {
    if (closeTimerRef.current !== null) {
      clearTimeout(closeTimerRef.current)
      closeTimerRef.current = null
    }
    if (!useCornerOrigin) {
      setMorph(menu ? 'open' : 'closed')
      setClosingSnapshot(null)
      return
    }
    if (menu) {
      setClosingSnapshot(null)
      if (prefersReducedMotion()) {
        setMorph('open')
        return
      }
      setMorph('closed')
      let innerFrame = 0
      const outerFrame = requestAnimationFrame(() => {
        void list.current?.getBoundingClientRect()
        innerFrame = requestAnimationFrame(() => setMorph('open'))
      })
      return () => {
        cancelAnimationFrame(outerFrame)
        cancelAnimationFrame(innerFrame)
      }
    }
    const snapshot = lastOpenRef.current
    lastOpenRef.current = null
    if (!snapshot || prefersReducedMotion()) {
      setMorph('closed')
      setClosingSnapshot(null)
      return
    }
    setClosingSnapshot(snapshot)
    setMorph('closing')
    closeTimerRef.current = setTimeout(() => {
      closeTimerRef.current = null
      setMorph('closed')
      setClosingSnapshot(null)
    }, CLOSE_MORPH_MS)
  }, [Boolean(menu), useCornerOrigin])

  useEffect(
    () => () => {
      if (closeTimerRef.current !== null) clearTimeout(closeTimerRef.current)
    },
    []
  )

  useLayoutEffect(() => {
    if (menu) list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
  }, [menu])

  const isClosingGhost = !menu && useCornerOrigin && morph === 'closing' && closingSnapshot !== null
  const activeCorner = isClosingGhost ? closingSnapshot.corner : corner
  const activePosition = useCornerOrigin
    ? isClosingGhost
      ? closingSnapshot.position
      : cornerMenuPosition
    : caretPosition

  const cornerButton =
    compact && activeCorner
      ? createPortal(
          <button
            type="button"
            data-slash-corner-trigger=""
            data-hidden={Boolean(menu || isClosingGhost) || undefined}
            aria-label={label('slash_menu')}
            title={`${label('slash_menu')} (/)`}
            aria-expanded={Boolean(menu)}
            aria-controls={menu ? `${editor.contentDOM.id}-slash` : undefined}
            style={{ left: activeCorner.left, top: activeCorner.top }}
            onMouseDown={event => event.preventDefault()}
            onClick={() => toggleCornerSlash(editor)}
            className="slash-corner-trigger ankole-editor-overlay ceramic ceramic-primary">
            <span aria-hidden="true">/</span>
          </button>,
          document.body
        )
      : null

  if (!menu && !isClosingGhost) return cornerButton

  const shownOptions = menu ? menu.options : closingSnapshot!.options
  const shownIndex = menu ? menu.index : closingSnapshot!.index

  // The list's rows run from edge to edge, so it takes the tight ceramic radius and keeps 8px above and below them.
  const menuOverlay = createPortal(
    <div
      ref={list}
      id={isClosingGhost ? undefined : `${editor.contentDOM.id}-slash`}
      data-compact={useCornerOrigin ? '' : undefined}
      data-morph={useCornerOrigin ? morph : undefined}
      aria-hidden={isClosingGhost ? 'true' : undefined}
      className={`block-menu ${isClosingGhost ? 'slash-menu-closing pointer-events-none' : 'slash-menu'} ankole-editor-overlay ceramic ceramic-primary ceramic-tight fixed z-30 ${useCornerOrigin ? '' : 'menu-scrollbar py-2'}`}
      role={isClosingGhost ? 'presentation' : 'listbox'}
      aria-label={isClosingGhost ? undefined : label('slash_menu')}
      style={{
        ...(activePosition ?? { visibility: 'hidden' }),
        ...(useCornerOrigin && activeCorner
          ? ({ '--slash-corner-room': `${activeCorner.roomAbove}px` } as Record<string, string>)
          : {})
      }}>
      {useCornerOrigin ? (
        <>
          <div className="slash-morph-list menu-scrollbar py-2">
            <BlockTypeItems
              options={shownOptions}
              onChoose={type => choose(editor, type)}
              slash={{
                index: shownIndex,
                id: index =>
                  isClosingGhost ? `${editor.contentDOM.id}-slash-closing-${index}` : optionId(editor, index),
                highlight: index => {
                  if (!isClosingGhost && editor.state.field(slashField, false)?.index !== index) {
                    editor.dispatch({ effects: highlight.of(index) })
                  }
                }
              }}
            />
          </div>
          <span aria-hidden="true" className="slash-morph-glyph">
            /
          </span>
        </>
      ) : (
        <BlockTypeItems
          options={shownOptions}
          onChoose={type => choose(editor, type)}
          slash={{
            index: shownIndex,
            id: index => optionId(editor, index),
            highlight: index => {
              if (editor.state.field(slashField, false)?.index !== index) {
                editor.dispatch({ effects: highlight.of(index) })
              }
            }
          }}
        />
      )}
    </div>,
    document.body
  )

  return (
    <>
      {cornerButton}
      {menuOverlay}
    </>
  )
}
