import { type Leaf, Node, type Plot, Schema } from '../../core/doc'
import { Decoration, type Wordgard } from '../../core/editor'
import { history } from '../../core/history'
import { GardSelection, GardState, Transaction } from '../../core/state'
import { CellSelection } from '../../core/table'
import * as T from '../../core/types'
import { unwrapMathDelimiters } from '../../document/math-delimiters'
import { element, text, textOf } from '../../document/tree'
import { Attrs, extraAttrs, extraOf, inheritedInlineMarks, markSet } from '../../editor/attributes'
import type { BlockDefinition } from '../../editor/block'
import { dispatchStep, insertBlock, splitInsert } from '../../editor/block-insert'
import { isKnowledge } from '../../editor/knowledge-context'
import { editorPhrases } from '../../editor/phrases'
import { connectedWidget, widgetBlock } from '../../editor/widget'
import { InlineMath, MathBlock } from './leaf'

export { InlineMath, MathBlock }

type TemmlApi = typeof import('temml').default

let loadedTemml: TemmlApi | null = null
let temmlPromise: Promise<TemmlApi> | null = null

function loadTemml(): Promise<TemmlApi> {
  if (loadedTemml) return Promise.resolve(loadedTemml)
  temmlPromise ??= import('temml').then(({ default: Temml }) => {
    loadedTemml = Temml
    return Temml
  })
  return temmlPromise
}

/**
 * Validate unwrapped LaTeX syntax with Temml. Returns a synchronous boolean once `temml` has loaded
 * so live typing in `MathEditor` never flickers across keystrokes.
 */
export function validateFormulaSyntax(source: string, displayMode: boolean): boolean | Promise<boolean> {
  const unwrapped = unwrapMathDelimiters(source)
  if (!unwrapped.trim()) return true
  const check = (Temml: TemmlApi): boolean => {
    try {
      Temml.renderToString(unwrapped, { displayMode, throwOnError: true })
      return true
    } catch {
      return false
    }
  }
  return loadedTemml ? check(loadedTemml) : loadTemml().then(check, () => false)
}

const isMathNode = (node: Node | null | undefined): boolean => node?.type === MathBlock || node?.type === InlineMath

function mapMathPos(startDoc: Plot.Doc, newDoc: Plot.Doc, changes: Transaction['changes'], pos: number): number | null {
  const prevKind = startDoc.nodeAt(pos)?.type
  if (!prevKind) return null
  const tracked = changes.mapPos(pos, 1, 'after')
  if (tracked !== null) {
    return newDoc.nodeAt(tracked)?.type === prevKind ? tracked : null
  }
  const left = changes.mapPos(pos, -1, 'before')
  const right = changes.mapPos(pos + 1, 1, 'after')
  return left !== null && right === left + 1 && newDoc.nodeAt(left)?.type === prevKind ? left : null
}

/** Open the formula editor for the block or inline formula at this position. */
export const openMathEditor = Transaction.Effect.define<number>()
/** Close the formula editor. */
export const closeMathEditor = Transaction.Effect.define<null>()

/** The node position whose formula is being edited, or null. */
export const mathEditorField = GardState.Field.define<number | null>({
  create: () => null,
  update(value, tr) {
    let pos = value
    if (pos !== null && tr.docChanged) {
      pos = mapMathPos(tr.startState.doc, tr.state.doc, tr.changes, pos)
    }
    for (const effect of tr.effects) {
      if (effect.is(openMathEditor)) pos = effect.value
      else if (effect.is(closeMathEditor)) pos = null
    }
    return pos !== null && isMathNode(tr.state.doc.nodeAt(pos)) ? pos : null
  }
})

const mathEditorDirty = GardState.Field.define<boolean>({
  create: () => false,
  update(value, tr) {
    const prevPos = tr.startState.field(mathEditorField, false) ?? null
    const nextPos = tr.state.field(mathEditorField, false) ?? null
    if (nextPos === null) return false
    const mappedPrev =
      prevPos !== null && tr.docChanged ? mapMathPos(tr.startState.doc, tr.state.doc, tr.changes, prevPos) : prevPos
    let dirty = nextPos === mappedPrev ? value : false
    if (tr.docChanged && tr.isUserEvent('input.type.math')) dirty = true
    return dirty
  }
})

/**
 * Increments whenever `openMathEditor` opens or switches the edited formula, and resets to 0
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

/**
 * Normalize outer math delimiters (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`) and isolate undo history
 * whenever an edited formula session closes or switches to another formula, while leaving
 * untouched formulas alone on `Escape` or outside click.
 */
const finalizeMathEdit = Transaction.appender.of((trs, state) => {
  const startState = trs[0]!.startState
  const startPos = startState.field(mathEditorField, false) ?? null
  if (startPos === null) return null
  const dirty = (startState.field(mathEditorDirty, false) ?? false) || trs.some(tr => tr.isUserEvent('input.type.math'))
  if (!dirty) return null
  let mappedPos: number | null = startPos
  for (const tr of trs) {
    if (!tr.docChanged) continue
    mappedPos = mapMathPos(tr.startState.doc, tr.state.doc, tr.changes, mappedPos)
    if (mappedPos === null) return null
  }
  const nextOpenPos = state.field(mathEditorField, false) ?? null
  if (nextOpenPos === mappedPos) return null
  const node = state.doc.nodeAt(mappedPos)
  if (!node || !isMathNode(node)) return null
  const currentSource = (node as Leaf<string>).param
  const cleaned = unwrapMathDelimiters(currentSource)
  const spec = cleaned !== currentSource ? mathSourceChange(state, mappedPos, cleaned) : null
  if (!spec) {
    return nextOpenPos === null ? { annotations: history.isolate.of(true) } : null
  }
  const prevSel = state.selection
  const targetsMappedNode = prevSel.from === mappedPos && prevSel.to === mappedPos + 1
  const blockBetween =
    targetsMappedNode && !(prevSel instanceof GardSelection.Text) && !(prevSel instanceof GardSelection.Node)
      ? (prevSel.constructor as { between?: (doc: typeof state.doc, a: number, b: number) => GardSelection | null })
          .between
      : undefined
  const targetPos = mappedPos
  return {
    ...spec,
    ...(targetsMappedNode && prevSel instanceof GardSelection.Node
      ? { selection: cx => GardSelection.node(targetPos, cx.doc.nodeAt(targetPos)!) }
      : blockBetween
        ? { selection: cx => blockBetween(cx.doc, targetPos, targetPos) ?? GardSelection.cursor(targetPos + 1) }
        : {}),
    annotations: history.isolate.of('after')
  }
})

type MathWidgetValue = { source: string; placeholder: string }

function renderFormulaInto(
  Temml: TemmlApi,
  source: string,
  unwrapped: string,
  element: HTMLElement,
  displayMode: boolean
) {
  try {
    element.classList.remove('is-invalid')
    Temml.render(unwrapped, element, { displayMode, throwOnError: true })
  } catch {
    element.classList.add('is-invalid')
    element.textContent = source
  }
}

function populateFormulaDOM(dom: HTMLElement, source: string, placeholder: string, displayMode: boolean): boolean {
  const unwrapped = unwrapMathDelimiters(source)
  if (!unwrapped.trim()) {
    if (!displayMode) dom.classList.add('is-empty')
    const empty = document.createElement('span')
    empty.className = 'math-placeholder'
    empty.textContent = placeholder
    dom.append(empty)
    return true
  }
  dom.setAttribute('aria-label', unwrapped)
  if (loadedTemml) {
    renderFormulaInto(loadedTemml, source, unwrapped, dom, displayMode)
    return true
  }
  dom.textContent = unwrapped
  return false
}

function hydrateFormulaAsync(source: string, element: HTMLElement, displayMode: boolean): () => void {
  const unwrapped = unwrapMathDelimiters(source)
  if (!unwrapped.trim() || loadedTemml) return () => {}
  let active = true
  void loadTemml()
    .then(Temml => {
      if (active) renderFormulaInto(Temml, source, unwrapped, element, displayMode)
    })
    .catch(() => {
      if (active) element.classList.add('is-invalid')
    })
  return () => {
    active = false
  }
}

const mathWidget = connectedWidget<MathWidgetValue, HTMLDivElement>({
  render: ({ source, placeholder }) => {
    const dom = document.createElement('div')
    dom.className = 'math-block'
    dom.contentEditable = 'false'
    dom.tabIndex = 0
    dom.setAttribute('role', 'button')
    dom.setAttribute('data-math', source)
    populateFormulaDOM(dom, source, placeholder, true)
    return dom
  },
  connect: ({ source }, element, editor) => {
    const disposePreview = hydrateFormulaAsync(source, element, true)
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
      disposePreview()
      element.removeEventListener('mousedown', mouseDown)
      element.removeEventListener('click', activate)
      element.removeEventListener('keydown', keyDown)
    }
  },
  // The block owns its own click and keyboard behavior; the editor keeps its caret out of it.
  propagateEvent: false
})

const inlineMathWidget = connectedWidget<MathWidgetValue, HTMLSpanElement>({
  render: ({ source, placeholder }) => {
    const dom = document.createElement('span')
    dom.className = 'math-inline'
    dom.contentEditable = 'false'
    dom.setAttribute('data-inline-math', source)
    populateFormulaDOM(dom, source, placeholder, false)
    return dom
  },
  connect: ({ source }, element, editor) => {
    const disposePreview = hydrateFormulaAsync(source, element, false)
    const activate = (event: Event) => {
      if (editor.state.readOnly) return
      const found = widgetBlock(editor, element)
      if (found?.node.type === InlineMath) {
        event.preventDefault()
        editor.dispatch({
          selection: GardSelection.node(found.pos, found.node),
          effects: openMathEditor.of(found.pos)
        })
      }
    }
    const mouseDown = (event: MouseEvent) => {
      if (event.button === 0 && !editor.state.readOnly) event.preventDefault()
    }
    element.addEventListener('mousedown', mouseDown)
    element.addEventListener('click', activate)
    return () => {
      disposePreview()
      element.removeEventListener('mousedown', mouseDown)
      element.removeEventListener('click', activate)
    }
  },
  propagateEvent: event => event.type === 'copy' || event.type === 'cut'
})

/** If the selection spans exactly one `InlineMath` node, return its position; otherwise `null`. */
export function singleSelectedInlineMathPos(state: GardState): number | null {
  if (state.selection instanceof GardSelection.Node && state.selection.node.type === InlineMath) {
    return state.selection.from
  }
  if (state.selection instanceof GardSelection.Text && state.selection.ranges.length === 1) {
    const { from, to } = state.selection.ranges[0]!
    if (to === from + 1 && state.doc.nodeAt(from)?.type === InlineMath) return from
  }
  return null
}

/** Whether the current selection can insert or wrap an inline formula. */
export function canInsertInlineMath(state: GardState): boolean {
  if (state.readOnly || isKnowledge(state)) return false
  if (state.selection instanceof GardSelection.Node) return state.selection.node.type === InlineMath
  if (state.selection instanceof GardSelection.Text) {
    if (state.selection.ranges.length !== 1) return false
    const { from, to } = state.selection.ranges[0]!
    const startBlock = state.doc.resolve(from).parent
    const endBlock = state.doc.resolve(to).parent
    if (startBlock.node.type.hasRole(Node.Role.Code)) return false
    if (!startBlock.node.isTextblock) return from === to
    return startBlock.before === endBlock.before
  }
  return !(state.selection instanceof CellSelection)
}

/** Transaction spec that inserts an inline formula (or wraps selected text) and opens `MathEditor`. */
export function insertInlineMathSpec(state: GardState): Transaction.Spec | null {
  if (!canInsertInlineMath(state)) return null
  const existingPos = singleSelectedInlineMathPos(state)
  if (existingPos !== null) {
    return { effects: openMathEditor.of(existingPos), scrollIntoView: true }
  }
  if (state.selection instanceof GardSelection.Text) {
    const { from, to } = state.selection.replacementRange
    const parent = state.doc.resolve(from).parent
    if (parent.node.isTextblock && !parent.node.type.hasRole(Node.Role.Code)) {
      const rawSelected = from < to ? state.doc.textContent({ from, to }).replace(/\r\n?|\n/g, ' ') : ''
      const initial = rawSelected ? unwrapMathDelimiters(rawSelected) : ''
      const leaf = InlineMath.of(initial, inheritedInlineMarks(state, from, InlineMath, T.Code.type))
      return {
        changes: { from, to, insert: [leaf] },
        selection: GardSelection.cursor(from + leaf.length),
        effects: openMathEditor.of(from),
        userEvent: 'math.insert'
      }
    }
    if (from === to && !parent.node.content.length && state.schema.canContain(parent.node.type, T.Paragraph.type)) {
      const leaf = InlineMath.of('')
      return {
        changes: { from, to, insert: [T.Paragraph.create([leaf])] },
        selection: GardSelection.cursor(from + 2),
        effects: openMathEditor.of(from + 1),
        userEvent: 'math.insert'
      }
    }
  }
  const head = state.sel.head
  const leaf = InlineMath.of('')
  const { changes, at } = splitInsert(state.doc, head.pos, [T.Paragraph.create([leaf])], false)
  return {
    changes,
    selection: GardSelection.cursor(at + 2),
    effects: openMathEditor.of(at + 1),
    userEvent: 'math.insert'
  }
}

/** Insert an inline formula (converting selected text if any) and open `MathEditor` as one undo step. */
export function insertInlineMath(editor: Wordgard): boolean {
  if (editor.composing) return false
  if (editor.connected) editor.flush()
  const spec = insertInlineMathSpec(editor.state)
  if (!spec) return false
  dispatchStep(editor, spec)
  editor.focus()
  return true
}

/** The transaction that replaces a formula's source while keeping its marks. */
export function mathSourceChange(state: GardState, pos: number, source: string): Transaction.Spec | null {
  const current = state.doc.nodeAt(pos)
  if (!current || !isMathNode(current)) return null
  const normalized = current.type === InlineMath ? source.replace(/\r\n?|\n/g, ' ') : source
  if ((current as Leaf<string>).param === normalized) return null
  const replacement =
    current.type === MathBlock ? MathBlock.of(normalized, current.marks) : InlineMath.of(normalized, current.marks)
  return {
    changes: {
      from: pos,
      to: pos + current.length,
      insert: [replacement]
    },
    userEvent: 'input.type.math'
  }
}

export const math: BlockDefinition = {
  name: 'math',
  type: MathBlock,
  schema: [MathBlock, InlineMath, Schema.Override.markTarget(Attrs, target => [target, MathBlock, InlineMath])],
  extension: [
    mathEditorField,
    mathEditorDirty,
    mathEditorOpenKey,
    finalizeMathEdit,
    Decoration.Tag.shape.derived(MathBlock, state => {
      const placeholder = editorPhrases.get(state, 'math_placeholder')
      return tag => mathWidget.of({ source: tag.param as string, placeholder })
    }),
    Decoration.Tag.shape.derived(InlineMath, state => {
      const placeholder = editorPhrases.get(state, 'inline_math_placeholder')
      return tag => inlineMathWidget.of({ source: tag.param as string, placeholder })
    })
  ],
  import: node => MathBlock.of(textOf(node), markSet([extraAttrs(node.attrs)])),
  read: node =>
    element('math', extraOf(node), (node as Leaf<string>).param ? [text((node as Leaf<string>).param)] : []),
  insert: {
    title: editorPhrases.ref('math_title'),
    detail: editorPhrases.ref('math_detail'),
    keywords: 'math latex equation formula block math 公式 块级公式 数学公式 gs eq',
    turnInto: false,
    insert: wg => {
      insertBlock(wg, MathBlock.of(''), at => ({ effects: openMathEditor.of(at) }))
    }
  }
}
