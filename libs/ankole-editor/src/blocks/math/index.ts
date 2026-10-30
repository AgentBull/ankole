import { Leaf, Node, Schema } from '../../core/doc'
import { Decoration } from '../../core/editor'
import { GardState, Transaction } from '../../core/state'
import { element, text, textOf } from '../../document/tree'
import { Attrs, extraAttrs, extraOf, markSet } from '../../editor/attributes'
import type { BlockDefinition } from '../../editor/block'
import { insertBlock } from '../../editor/block-insert'
import { editorPhrases } from '../../editor/phrases'
import { connectedWidget, widgetBlock } from '../../editor/widget'

/**
 * `math`: a display formula. The node parameter is the LaTeX source. The block is a leaf, so it has
 * no editable text of its own; the formula editor writes a new leaf in its place.
 */
export const MathBlock = Leaf.Type.define<string>('Math', {
  group: Node.Group.Content,
  selectable: true,
  validate: 'string',
  toText: leaf => leaf.param as string,
  shape: { element: 'div', attributes: { class: 'math-block', contenteditable: 'false' } }
})

/** Open the formula editor for the block at this position. */
export const openMathEditor = Transaction.Effect.define<number>()
/** Close the formula editor. */
export const closeMathEditor = Transaction.Effect.define<null>()

/** The block position whose formula is being edited, or null. */
export const mathEditorField = GardState.Field.define<number | null>({
  create: () => null,
  update(value, tr) {
    let pos = value !== null && tr.docChanged ? tr.changes.mapPos(value, -1) : value
    for (const effect of tr.effects) {
      if (effect.is(openMathEditor)) pos = effect.value
      else if (effect.is(closeMathEditor)) pos = null
    }
    return pos !== null && tr.state.doc.nodeAt(pos)?.type === MathBlock ? pos : null
  }
})

/**
 * Increments whenever `openMathEditor` opens or switches the edited formula block, and resets to 0
 * when closed. Document edits that only map the position keep the same key so the input is not
 * refocused or reselected.
 */
export const mathEditorOpenKey = GardState.Field.define<number>({
  create: () => 0,
  update(value, tr) {
    let key = value
    for (const effect of tr.effects) {
      if (effect.is(openMathEditor)) key = value + 1
      else if (effect.is(closeMathEditor)) key = 0
    }
    return (tr.state.field(mathEditorField, false) ?? null) === null ? 0 : key
  }
})

type MathWidgetValue = { source: string; placeholder: string }

const mathWidget = connectedWidget<MathWidgetValue, HTMLDivElement>({
  render: ({ source, placeholder }) => {
    const dom = document.createElement('div')
    dom.className = 'math-block'
    dom.contentEditable = 'false'
    dom.tabIndex = 0
    dom.setAttribute('role', 'button')
    dom.setAttribute('data-math', source)
    if (source.trim()) {
      dom.textContent = source
    } else {
      const empty = document.createElement('span')
      empty.className = 'math-placeholder'
      empty.textContent = placeholder
      dom.append(empty)
    }
    return dom
  },
  connect: ({ source }, element, editor) => {
    let active = true
    if (source.trim()) {
      void import('temml')
        .then(({ default: Temml }) => {
          if (!active) return
          try {
            Temml.render(source, element, { displayMode: true, throwOnError: true })
          } catch {
            element.classList.add('is-invalid')
            element.textContent = source
          }
        })
        .catch(() => {
          if (active) element.classList.add('is-invalid')
        })
    }

    if (source.trim()) element.setAttribute('aria-label', source)
    else element.removeAttribute('aria-label')
    const activate = (event: Event) => {
      event.preventDefault()
      if (editor.state.readOnly) return
      const found = widgetBlock(editor, element)
      if (found?.node.type === MathBlock) editor.dispatch({ effects: openMathEditor.of(found.pos) })
    }
    const mouseDown = (event: MouseEvent) => {
      if (event.button === 0) event.preventDefault()
    }
    const keyDown = (event: KeyboardEvent) => {
      if (event.key === 'Enter' || event.key === ' ') activate(event)
    }
    element.addEventListener('mousedown', mouseDown)
    element.addEventListener('click', activate)
    element.addEventListener('keydown', keyDown)
    return () => {
      active = false
      element.removeEventListener('mousedown', mouseDown)
      element.removeEventListener('click', activate)
      element.removeEventListener('keydown', keyDown)
    }
  },
  // The block owns its own click and keyboard behavior; the editor keeps its caret out of it.
  propagateEvent: false
})

/** The transaction that replaces a formula's source while keeping its marks. */
export function mathSourceChange(state: GardState, pos: number, source: string): Transaction.Spec | null {
  const current = state.doc.nodeAt(pos)
  if (!current || current.type !== MathBlock || (current as Leaf<string>).param === source) return null
  return {
    changes: {
      from: pos,
      to: pos + current.length,
      insert: [MathBlock.of(source, current.marks)]
    },
    userEvent: 'input.type.math'
  }
}

export const math: BlockDefinition = {
  name: 'math',
  type: MathBlock,
  schema: [MathBlock, Schema.Override.markTarget(Attrs, target => [target, MathBlock])],
  extension: [
    mathEditorField,
    mathEditorOpenKey,
    Decoration.Tag.shape.derived(MathBlock, state => {
      const placeholder = editorPhrases.get(state, 'math_placeholder')
      return tag => mathWidget.of({ source: tag.param as string, placeholder })
    })
  ],
  import: node => MathBlock.of(textOf(node), markSet([extraAttrs(node.attrs)])),
  read: node =>
    element('math', extraOf(node), (node as Leaf<string>).param ? [text((node as Leaf<string>).param)] : []),
  insert: {
    title: editorPhrases.ref('math_title'),
    detail: editorPhrases.ref('math_detail'),
    keywords: 'math latex equation formula 公式',
    turnInto: false,
    insert: wg => {
      insertBlock(wg, MathBlock.of(''), at => ({ effects: openMathEditor.of(at) }))
    }
  }
}
