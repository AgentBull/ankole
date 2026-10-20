import { useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Leaf } from '../core/doc'
import { Wordgard } from '../core/editor'
import { GardSelection, GardState, Transaction } from '../core/state'
import { PhraseSet } from '../core/phrases'
import * as T from '../core/types'
import { applyBlockType, blockOptions, type BlockOption } from '../editor/block-actions'
import { useEditor, useEditorLabel, useEditorState } from './context'

/*
 * The slash menu (SPEC §7.6). `/` opens it at the start of a text run (for example right after bold
 * text or a link), or after whitespace or `(`, outside code blocks. The query after `/` has at most
 * 75 characters and no whitespace or punctuation. The menu state is a field of the editor state, so
 * key handling and rendering read the same value.
 */
const query = /(?:^|[\s(])\/([^\s.,+*?$@|#{}()^\-[\]\\/!%'"~=<>_:;]{0,75})$/

type Slash = {
  /** The position of `/`. */
  from: number
  /** The caret, at the end of the query. */
  to: number
  query: string
  options: readonly BlockOption[]
  /** The highlighted option. */
  index: number
}

const highlight = Transaction.Effect.define<number>()
const dismiss = Transaction.Effect.define<null>()

function find(state: GardState, previous: Slash | null): Slash | null {
  const { selection } = state
  if (state.readOnly || !(selection instanceof GardSelection.Text) || !selection.empty) return null
  const head = state.sel.head
  if (!head.parent.node.isTextblock || head.parent.node.type == T.CodeBlock.type) return null
  // The text run that holds the caret, up to the caret.
  const run = head.inText ? head.parent.node.content[head.index] : head.nodeBefore
  if (!run?.is(Leaf.Text)) return null
  const match = query.exec(head.inText ? run.param.slice(0, head.inText) : run.param)
  if (!match) return null
  const text = match[1]!.toLowerCase()
  const options = blockOptions.filter(option =>
    `${option.title(state)} ${option.detail(state)} ${option.keywords ?? ''}`.toLowerCase().includes(text)
  )
  if (!options.length) return null
  const from = selection.head - match[1]!.length - 1
  const index =
    previous && previous.from === from && previous.query === match[1] ? Math.min(previous.index, options.length - 1) : 0
  return { from, to: selection.head, query: match[1]!, options, index }
}

const slashField = GardState.Field.define<Slash | null>({
  create: state => find(state, null),
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(dismiss)) return null
      if (effect.is(highlight) && value) return { ...value, index: effect.value }
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
    return find(tr.state, value)
  }
})

const optionId = (wg: Wordgard, index: number) => `${wg.contentDOM.id}-slash-${index}`

/** Delete the query and apply the block type at the caret, as one undo step. */
function choose(wg: Wordgard, option: BlockOption) {
  const menu = wg.state.field(slashField, false)
  if (!menu) return
  applyBlockType(wg, option.type, { from: menu.from, to: menu.to })
  wg.focus()
}

const keys = Wordgard.domEventHandler('keydown', (event, wg) => {
  const menu = wg.state.field(slashField, false)
  if (!menu || event.isComposing || event.keyCode === 229 || wg.composing) return false
  if (event.ctrlKey || event.metaKey || event.altKey) return false
  const count = menu.options.length
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    const step = event.key === 'ArrowDown' ? 1 : -1
    wg.dispatch({ effects: highlight.of((menu.index + step + count) % count) })
    return true
  }
  if ((event.key === 'Enter' || event.key === 'Tab') && !event.shiftKey) {
    choose(wg, menu.options[menu.index]!)
    return true
  }
  if (event.key === 'Escape') {
    wg.dispatch({ effects: dismiss.of(null) })
    return true
  }
  return false
})

/** The slash menu state, its keys and the accessibility attributes of the editable element. */
export const slashMenu: GardState.Extension = [
  slashField,
  GardState.prec.highest(keys),
  Wordgard.contentAttributes.of(wg => {
    const menu = wg.hasFocus ? wg.state.field(slashField, false) : null
    return {
      'aria-autocomplete': 'list',
      'aria-controls': menu ? `${wg.contentDOM.id}-slash` : null,
      'aria-activedescendant': menu ? optionId(wg, menu.index) : null
    }
  })
]

export function SlashMenu() {
  const label = useEditorLabel()
  const editor = useEditor()
  const menu = useEditorState(state => (editor.hasFocus ? (state.field(slashField, false) ?? null) : null))
  const list = useRef<HTMLDivElement>(null)
  const [position, setPosition] = useState<{ left: number; top: number } | null>(null)
  const from = menu?.from
  // The height changes with the number of options. A menu above the caret moves with it.
  const count = menu?.options.length

  useLayoutEffect(() => {
    if (from === undefined) {
      setPosition(null)
      return
    }
    const place = () => {
      const element = list.current
      if (!element || !editor.state.field(slashField, false)) return
      const caret = editor.coordsAtPos(from, 1)
      const { width, height } = element.getBoundingClientRect()
      const below = caret.bottom + 4
      setPosition({
        left: Math.max(8, Math.min(caret.left, window.innerWidth - width - 8)),
        top: below + height > window.innerHeight - 8 && caret.top - height - 4 > 8 ? caret.top - height - 4 : below
      })
    }
    place()
    window.addEventListener('scroll', place, true)
    window.addEventListener('resize', place)
    return () => {
      window.removeEventListener('scroll', place, true)
      window.removeEventListener('resize', place)
    }
  }, [editor, from, count])

  useLayoutEffect(() => {
    if (menu) list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
  }, [menu])

  if (!menu) return null
  return createPortal(
    <div
      ref={list}
      id={`${editor.contentDOM.id}-slash`}
      className="slash-menu ankole-editor-overlay ceramic ceramic-primary"
      role="listbox"
      aria-label={label('slash_menu')}
      style={position ?? { visibility: 'hidden' }}>
      <div className="menu-label">{label('add_content')}</div>
      {menu.options.map((option, index) => (
        <button
          key={option.type}
          id={optionId(editor, index)}
          type="button"
          tabIndex={-1}
          className={index === menu.index ? 'selected' : ''}
          role="option"
          aria-selected={index === menu.index}
          onMouseDown={event => event.preventDefault()}
          onMouseEnter={() => {
            if (editor.state.field(slashField, false)?.index !== index) {
              editor.dispatch({ effects: highlight.of(index) })
            }
          }}
          onClick={() => choose(editor, option)}>
          <span className="menu-icon">{option.glyph}</span>
          <span>
            {option.title(editor.state)}
            <small>{option.detail(editor.state)}</small>
          </span>
        </button>
      ))}
    </div>,
    document.body
  )
}
