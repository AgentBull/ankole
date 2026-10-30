import { useLayoutEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { Leaf, Node } from '../core/doc'
import { Wordgard } from '../core/editor'
import { GardSelection, GardState, Transaction } from '../core/state'
import { PhraseSet } from '../core/phrases'
import { applyBlockType } from '../editor/block-actions'
import { filterBlockOptions, type BlockOption, type BlockType } from '../editor/block-catalog'
import { mentionField } from '../editor/mention'
import { BlockTypeItems } from './BlockTypeItems'
import { useAnchoredOverlay } from './anchored-overlay'
import { useEditor, useEditorLabel, useEditorState } from './context'

/*
 * The slash menu (SPEC §7.6). `/` opens it at the start of a text run (for example right after bold
 * text or a link), or after whitespace or `(`, outside code blocks. The query after `/` has at most
 * 75 characters and can include spaces, but not line breaks or punctuation. The menu state is a
 * field of the editor state, so key handling and rendering read the same value.
 */
const query = /(?:^|[\s(])\/([^\r\n\t.,+*?$|#{}()^\-[\]\\/!%'"~=<>_:;]{0,75})$/

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
function choose(wg: Wordgard, type: BlockType) {
  const menu = wg.state.field(slashField, false)
  if (!menu) return
  applyBlockType(wg, type, { from: menu.from, to: menu.to })
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
    choose(wg, menu.options[menu.index]!.type)
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
  Wordgard.contentAttributes.of((wg): Record<string, string | null> => {
    const menu = wg.hasFocus ? wg.state.field(slashField, false) : null
    if (!menu) return { 'aria-autocomplete': 'list' }
    return {
      'aria-autocomplete': 'list',
      'aria-controls': `${wg.contentDOM.id}-slash`,
      'aria-activedescendant': optionId(wg, menu.index)
    }
  })
]

export function SlashMenu() {
  const label = useEditorLabel()
  const editor = useEditor()
  const menu = useEditorState(state => (editor.hasFocus ? (state.field(slashField, false) ?? null) : null))
  const list = useRef<HTMLDivElement>(null)
  const from = menu?.from
  const count = menu?.options.length
  const position = useAnchoredOverlay({
    open: menu !== null,
    panelRef: list,
    anchor: () => (from === undefined ? null : editor.coordsAtPos(from, 1)),
    dependencies: [from, count]
  })

  useLayoutEffect(() => {
    if (menu) list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
  }, [menu])

  if (!menu) return null
  return createPortal(
    <div
      ref={list}
      id={`${editor.contentDOM.id}-slash`}
      className="block-menu slash-menu ankole-editor-overlay ceramic ceramic-primary"
      role="listbox"
      aria-label={label('slash_menu')}
      style={position ?? { visibility: 'hidden' }}>
      <BlockTypeItems
        options={menu.options}
        onChoose={type => choose(editor, type)}
        slash={{
          index: menu.index,
          id: index => optionId(editor, index),
          highlight: index => {
            if (editor.state.field(slashField, false)?.index !== index) {
              editor.dispatch({ effects: highlight.of(index) })
            }
          }
        }}
      />
    </div>,
    document.body
  )
}
