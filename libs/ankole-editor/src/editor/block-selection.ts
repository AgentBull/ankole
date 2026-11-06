import { type ChangeSet, Node, Plot, type Pos, Slice, Leaf, type Token, ValidationError } from '../core/doc'
import { Decoration, KeyBinding, Wordgard } from '../core/editor'
import { setDOMSelection } from '../core/editor/selection'
import { compositionComplete } from '../core/editor/input'
import { history } from '../core/history'
import { GardSelection, GardState, Transaction } from '../core/state'
import { Command, insertText } from '../core/command'
import { CellSelection } from '../core/table'
import { TableMap } from '../core/table/tablemap'
import * as T from '../core/types'
import { MathBlock, openMathEditor } from '../blocks/math'
import { InfographicBlock, InfographicView } from '../blocks/infographic'
import { MermaidBlock, MermaidView } from '../blocks/mermaid'
import { isList } from './block-insert'
import { adjacentUnit, blockContent, blockRemovalRanges, blocksBetween, targetAt, unitAt } from './block-target'
import { flattenColumns } from './corrections'
import { Columns } from './schema'

/** Whole blocks, including children and ranges across list boundaries. */
export class BlockSelection extends GardSelection {
  constructor(
    readonly first: Pos.Node,
    readonly last: Pos.Node,
    readonly chosen: readonly Pos.Node[] | null = null
  ) {
    super(
      first.before <= last.before ? first.before : Math.max(first.after, last.after),
      first.before <= last.before ? Math.max(first.after, last.after) : last.before
    )
  }

  static between(doc: Plot.Doc, anchor: number, head = anchor): BlockSelection | null {
    const first = targetAt(doc, anchor)
    const last = targetAt(doc, head)
    if (!first || !last) return null
    return new BlockSelection(first, last)
  }

  static of(doc: Plot.Doc, positions: readonly number[]): BlockSelection | null {
    const units: Pos.Node[] = []
    for (const pos of [...new Set(positions)].sort((a, b) => a - b)) {
      const unit = targetAt(doc, pos)
      if (unit && (!units.length || unit.before >= units.at(-1)!.after)) units.push(unit)
    }
    return units.length ? new BlockSelection(units[0]!, units.at(-1)!, units) : null
  }

  eq(other: GardSelection) {
    return (
      other instanceof BlockSelection &&
      this.first.before === other.first.before &&
      this.last.before === other.last.before &&
      this.blocks.length === other.blocks.length &&
      this.blocks.every((unit, i) => unit.before === other.blocks[i]!.before)
    )
  }

  map(changes: ChangeSet, cx: GardSelection.Context) {
    const mapped = (before: number) => {
      const pos = changes.mapPos(before, 1, 'after')
      return pos === null ? null : (unitAt(cx.doc, pos, 1)?.before ?? null)
    }
    if (this.chosen) {
      const positions = this.chosen.flatMap(unit => {
        const pos = mapped(unit.before)
        return pos === null ? [] : [pos]
      })
      return BlockSelection.of(cx.doc, positions) ?? GardSelection.near(cx, changes.mapPos(this.from, -1), 1)
    }
    const first = mapped(this.first.before)
    const last = mapped(this.last.before)
    return (
      (first !== null && last !== null && BlockSelection.between(cx.doc, first, last)) ||
      GardSelection.near(cx, changes.mapPos(this.from, -1), 1)
    )
  }

  get blocks(): Pos.Node[] {
    return this.chosen ? [...this.chosen] : blocksBetween(this.first.doc, this.from, this.to)
  }

  get replacementRange() {
    return this.ranges[0]!
  }

  // A DOM caret between blocks sends a native IME composition into a neighbouring block, so a
  // single selected empty paragraph keeps the caret inside it.
  override get domSelection(): GardSelection['domSelection'] {
    const blocks = this.blocks
    if (blocks.length !== 1 || !isEmptyMarklessParagraph(blocks[0]!.node)) return this
    const pos = blocks[0]!.before + 1
    return { anchor: pos, head: pos, anchorSide: 1 as const, headSide: 1 as const }
  }

  get ranges() {
    return blockRemovalRanges(this.blocks)
  }

  toSlice(doc: Plot.Doc) {
    return Slice.of(blockContent(this.blocks), doc.contextAt(this.from))
  }
}

const isNonEditableBlock = (node: Node) =>
  node.isLeaf ||
  (node.type === MermaidBlock.type && node.mark(MermaidView) === 'diagram') ||
  (node.type === InfographicBlock.type && node.mark(InfographicView) === 'diagram')

const isEmptyMarklessParagraph = (node: Node) =>
  node.type === T.Paragraph.type && node.isPlot && !node.content.length && !node.marks.length

/** Editing a parent starts in its own first editable block, before any nested children. */
function firstEditableBlock(doc: Plot.Doc, root: Pos.Node): Pos.Node | null {
  if (isNonEditableBlock(root.node)) return null
  if (root.node.isPlot && root.node.inlineContent) return root
  if (!root.node.isPlot) return null
  if (!root.node.content.length) {
    return doc.schema.canContain(root.node.type, T.Paragraph.type) ? root : null
  }
  let pos = root.before + 1
  for (const child of root.node.content) {
    const found = firstEditableBlock(doc, doc.resolveNode(pos)!)
    if (found) return found
    pos += child.length
  }
  return doc.schema.canContain(root.node.type, T.Paragraph.type) ? root : null
}

function tableHeadCell(state: GardState): Pos.Plot | null {
  const { selection, schema } = state
  const head = selection instanceof CellSelection ? state.doc.resolve(selection.headCell + 1) : state.sel.head
  return head.matchingParent(plot => schema.matchNode(plot.type, Node.Group.TableCell))
}

/** Select every cell in `table`, or null when the table has no cells. */
export function allTableCells(doc: Plot.Doc, table: Pos.Plot): CellSelection | null {
  const map = TableMap.get(table.node, table.start)
  if (!map.width || !map.height) return null
  const cells = map.cellsInRect({ startCol: 0, startRow: 0, endCol: map.width, endRow: map.height })
  if (!cells.length) return null
  return CellSelection.between(doc, cells[0]!, map.cellEnd(cells.at(-1)!))
}

function moveSelectedCell(state: GardState, dx: -1 | 0 | 1, dy: -1 | 0 | 1): Transaction.Spec | false {
  const { selection, doc } = state
  if (!(selection instanceof CellSelection)) return false
  const table = tableHeadCell(state)?.parent?.parent
  if (!table) return false
  const map = TableMap.get(table.node, table.start)
  if (!map.width || !map.height) return {}
  const rect = map.cellRect(selection.headCell)
  const dirX = dx && !state.textLTR ? (-dx as -1 | 1) : dx
  const col = Math.max(
    0,
    Math.min(map.width - 1, dirX < 0 ? rect.startCol - 1 : dirX > 0 ? rect.endCol : rect.startCol)
  )
  const row = Math.max(0, Math.min(map.height - 1, dy < 0 ? rect.startRow - 1 : dy > 0 ? rect.endRow : rect.startRow))
  const nextPos = map.cellAt(col, row) ?? selection.headCell
  const next = CellSelection.between(doc, nextPos, map.cellEnd(nextPos))
  if (!next || next.eq(selection)) return {}
  return { selection: next, scrollIntoView: true, userEvent: 'select' }
}

function insertParagraphBelow(state: GardState, block: Pos.Node): Transaction.Spec | false {
  if (state.readOnly) return false
  let at = block.after
  const insert: Token[] = [T.Paragraph.create()]
  const parent = block.parent!
  if (isList(parent.node)) {
    if (at === parent.end) at = parent.after
    else insert.splice(0, insert.length, Plot.End, ...insert, parent.node.tag)
  }
  return {
    changes: { from: at, insert },
    selection: GardSelection.cursor(at + (insert[0] === Plot.End ? 2 : 1)),
    annotations: history.isolate.of(true),
    scrollIntoView: true,
    userEvent: 'block.insert'
  }
}

const escapeSelection: Command = ({ state }) => {
  if (state.readOnly) return false
  if (state.selection instanceof BlockSelection) {
    const last = state.selection.last
    const editable = firstEditableBlock(state.doc, last)
    const selection = editable
      ? GardSelection.near(state, editable.after - 1, -1)
      : GardSelection.cursor(last.after, -1)
    return { selection, scrollIntoView: true, userEvent: 'select' }
  }
  if (state.selection instanceof CellSelection) {
    const table = tableHeadCell(state)?.parent?.parent
    const unit = table && unitAt(state.doc, table.before, 1)
    const selection = unit && BlockSelection.between(state.doc, unit.before, unit.before)
    return selection ? { selection, scrollIntoView: true, userEvent: 'select.block' } : false
  }
  const cell = tableHeadCell(state)
  if (cell) {
    const selection = CellSelection.between(state.doc, cell.before, cell.after)
    if (selection) return { selection, scrollIntoView: true, userEvent: 'select' }
  }
  const empty = state.selection.empty
  const from = unitAt(state.doc, state.selection.from, empty ? state.selection.headSide : 1)
  const to = unitAt(state.doc, state.selection.to, empty ? state.selection.headSide : -1)
  if (!from || !to) return false
  const selection = BlockSelection.between(state.doc, from.before, to.before) ?? new BlockSelection(from, from)
  return { selection, userEvent: 'select.block' }
}

const move =
  (dir: -1 | 1, extend = false): Command =>
  ({ state }) => {
    if (!extend && state.selection instanceof CellSelection) return moveSelectedCell(state, 0, dir)
    const selected = state.selection
    if (!(selected instanceof BlockSelection)) return false
    const last = selected.last
    const shrinkingParent =
      extend && dir > 0 && last.before < selected.first.before && last.after >= selected.first.after
    const next = shrinkingParent ? selected.first : adjacentUnit(last, dir)
    if (!next) {
      if (dir > 0 && !extend && !state.readOnly && !(!last.parent?.parent && isEmptyMarklessParagraph(last.node))) {
        const at = state.doc.length
        return {
          changes: { from: at, insert: [T.Paragraph.create()] },
          selection: cx => {
            const created = targetAt(cx.doc, at)
            return created ? new BlockSelection(created, created) : GardSelection.near(cx, at + 1, 1)
          },
          annotations: history.isolate.of(true),
          scrollIntoView: true,
          userEvent: 'block.insert'
        }
      }
      return true
    }
    return {
      selection: new BlockSelection(extend ? selected.first : next, next),
      scrollIntoView: true,
      userEvent: 'select.block'
    }
  }

const editEdge =
  (end: boolean): Command =>
  ({ state }) => {
    if (state.selection instanceof CellSelection) return moveSelectedCell(state, end ? 1 : -1, 0)
    if (!(state.selection instanceof BlockSelection)) return false
    const block = state.selection.last
    const editable = firstEditableBlock(state.doc, block)
    const selection = editable
      ? GardSelection.near(state, end ? editable.after - 1 : editable.before + 1, end ? -1 : 1)
      : GardSelection.near(state, end ? block.after : block.before, end ? 1 : -1)
    return { selection, scrollIntoView: true }
  }

const enterSelection: Command = ({ state }) => {
  if (state.selection instanceof CellSelection) {
    return {
      selection: GardSelection.near(state, state.selection.replacementRange.to, -1),
      scrollIntoView: true
    }
  }
  if (!(state.selection instanceof BlockSelection)) return false
  const blocks = state.selection.blocks
  const first = blocks[0]!
  if (blocks.length === 1 && first.node.type === MathBlock && !state.readOnly) {
    return { effects: openMathEditor.of(first.before), scrollIntoView: true }
  }
  if (blocks.length === 1 && isNonEditableBlock(first.node)) {
    return insertParagraphBelow(state, first)
  }
  const editable = firstEditableBlock(state.doc, first)
  if (!editable) return insertParagraphBelow(state, state.selection.last)
  return {
    selection: GardSelection.near(state, editable.after - 1, -1),
    scrollIntoView: true
  }
}

// Modifier and input-mode keys, such as Shift in Microsoft Pinyin, also send keydown 229, but no
// composition follows them.
const switchesInput = /^(Shift|Control|Alt|Meta|CapsLock|Lang|Convert|NonConvert|KanaMode|Escape|Tab|Arrow)/

/** An IME composition replaces a block selection with an empty paragraph that holds the caret. */
function composeOverBlocks(wg: Wordgard): false {
  const { selection } = wg.state
  if (wg.state.readOnly || !(selection instanceof BlockSelection)) return false
  const blocks = selection.blocks
  if (blocks.length === 1 && isEmptyMarklessParagraph(blocks[0]!.node)) {
    // The DOM caret is already inside the paragraph (see `domSelection`). Redrawing now would
    // replace the node that the composition started in.
    wg.dispatch({ selection: GardSelection.cursor(blocks[0]!.before + 1) })
    return false
  }
  wg.dispatch({
    changes: {
      correct: selection.ranges.map((range, index) => ({
        ...range,
        insert: index ? [] : [T.Paragraph.create()],
        fit: true
      })),
      local: true
    },
    selection: (cx, changes) => GardSelection.near(cx, changes.mapPos(selection.ranges[0]!.from, 1), 1),
    userEvent: 'input.type.compose.start',
    scrollIntoView: true
  })
  wg.flush()
  return false
}

const selectedBlock = Decoration.Point.attributes({ class: 'editor-selected-block' })

export const clearCompositionHost = Transaction.Annotation.define<boolean>()

/** The editor follows the original text block when a pointer action moves the caret before completion. */
export const compositionHost = GardState.Field.define<number | null>({
  create: () => null,
  update(position, tr) {
    if (tr.annotation(clearCompositionHost)) return null
    if (tr.docChanged && !tr.annotation(Transaction.remote)) {
      if (!tr.isUserEvent('input.type.compose')) return null
      if (position === null || tr.isUserEvent('input.type.compose.start')) {
        const host = tr.newSelection.resolve(tr.newDoc).head.parent
        return host.node.isTextblock ? host.before : null
      }
    }
    return position === null ? null : tr.changes.mapPos(position, 1, 'after')
  }
})

export const blockSelection: GardState.Extension = [
  compositionHost,
  Command.handler(insertText, ({ state }, input) => {
    const selection = state.selection
    if (!(selection instanceof BlockSelection) || state.readOnly) return false
    const composing = input.userEvent.startsWith('input.type.compose')
    const first = selection.blocks[0]!
    if (composing && first.node.type === T.Paragraph.type) {
      // The browser has already chosen its composing Text node. Keep the paragraph's boundary
      // tokens, so that replacing its content does not detach that node and end the composition.
      const range = selection.ranges[0]!
      return {
        changes: {
          correct: [
            ...first.node.marks.map(remove => ({ from: first.before, to: first.before + 1, remove })),
            { from: first.before + 1, to: first.after - 1, insert: input.insert ? [Leaf.text(input.insert)] : [] },
            ...(first.after < range.to ? [{ from: first.after, to: range.to }] : []),
            ...selection.ranges.slice(1).map(range => ({ ...range, insert: [] }))
          ],
          local: true
        },
        selection: (_cx, changes) => GardSelection.cursor(changes.mapPos(first.before + 1, -1) + input.insert.length),
        userEvent: input.userEvent,
        scrollIntoView: true
      }
    }
    if (selection.ranges.length < 2) return false
    return {
      changes: {
        correct: selection.ranges.map((range, index) => ({
          ...range,
          insert: index ? [] : [Leaf.text(input.insert)],
          fit: true
        })),
        local: true
      },
      selection: (cx, changes) => GardSelection.near(cx, changes.mapPos(selection.ranges[0]!.to, 1), -1),
      userEvent: input.userEvent,
      scrollIntoView: true
    }
  }),
  Wordgard.pasteHandler.of((editor, _event, slice) => {
    const selection = editor.state.selection
    if (!(selection instanceof BlockSelection) || selection.ranges.length < 2 || editor.state.readOnly) return false
    editor.dispatch({
      changes: {
        correct: selection.ranges.map((range, index) => ({ ...range, insert: index ? [] : slice, fit: true })),
        local: true
      },
      selection: (cx, changes) => GardSelection.near(cx, changes.mapPos(selection.ranges[0]!.to, 1), -1),
      userEvent: 'input.paste',
      scrollIntoView: true
    })
    return true
  }),
  // A keydown 229 can prepare a structural replacement before the browser starts composing.
  // Without that keydown, a paragraph keeps its Text node until the first composition input.
  Wordgard.domEventHandler(
    'keydown',
    (event, wg) => event.keyCode === 229 && !switchesInput.test(event.code) && composeOverBlocks(wg)
  ),
  // Prepare structural replacements before the core records the native composing node.
  Wordgard.domEventObserver('compositionstart', (_event, wg) => {
    const { selection } = wg.state
    if (selection instanceof BlockSelection && selection.blocks[0]!.node.type !== T.Paragraph.type) {
      composeOverBlocks(wg)
    }
  }),
  Wordgard.domEventHandler('compositionstart', (_event, wg) => {
    if (wg.state.readOnly) return false
    const { selection } = wg.state
    const first = selection instanceof BlockSelection ? selection.blocks[0]! : null
    if (first?.node.type === T.Paragraph.type) {
      setDOMSelection(wg, { anchor: first.before + 1, head: first.after - 1, anchorSide: 1, headSide: -1 })
    } else {
      composeOverBlocks(wg)
    }
    // A prepared paragraph already started this composition's undo event before its first text.
    if (
      wg.inputState.composing &&
      wg.state.selection.isCursor &&
      wg.state.field(compositionHost) === wg.state.sel.head.parent.pos
    ) {
      wg.inputState.composing.changes ||= 1
    }
    return false
  }),
  Wordgard.domEventHandler('compositionend', (_event, wg) => {
    if (!wg.state.readOnly && wg.state.selection instanceof BlockSelection) setDOMSelection(wg)
    return false
  }),
  compositionComplete.of(wg => {
    const position = wg.state.field(compositionHost, false)
    if (wg.state.readOnly || position == null) return
    let parent: Pos.Plot | null = wg.state.doc.resolve(position + 1).parent
    while (parent) {
      const changes = parent.node.type === Columns.type && flattenColumns.correct(parent)
      if (changes) {
        const before = wg.state
        wg.dispatch({ changes, userEvent: 'input.type.compose' })
        if (wg.state === before) break
        const mapped = wg.state.field(compositionHost, false)
        if (mapped == null) break
        // Cleanup can unwrap several ancestors; follow the original text block through those changes.
        parent = wg.state.doc.resolve(mapped + 1).parent
      } else {
        parent = parent.parent
      }
    }
  }),
  GardSelection.define(
    'blocks',
    BlockSelection,
    selection => ({
      anchor: selection.first.before,
      head: selection.last.before,
      ...(selection.chosen ? { positions: selection.chosen.map(unit => unit.before) } : {})
    }),
    (doc, json: { anchor: number; head: number; positions?: number[] }) => {
      const selection = json.positions
        ? BlockSelection.of(doc, json.positions)
        : BlockSelection.between(doc, json.anchor, json.head)
      if (!selection) throw new ValidationError('Invalid block selection')
      return selection
    }
  ),
  Decoration.Point.source.of(state =>
    state.selection instanceof BlockSelection
      ? Decoration.Point.set(state.selection.blocks.map(block => [selectedBlock, block.before]))
      : Decoration.Point.none
  ),
  GardState.prec.high([
    Wordgard.domEventHandler('mousedown', (event, wg) => {
      const selected = wg.state.selection
      if (event.button !== 0 || !event.shiftKey || !(selected instanceof BlockSelection)) return false
      const pos = wg.posAtCoords({ x: event.clientX, y: event.clientY })
      const target = unitAt(wg.state.doc, pos.pos, pos.side)
      const selection = target && BlockSelection.between(wg.state.doc, selected.first.before, target.before)
      if (!selection) return false
      wg.dispatch({ selection, userEvent: 'select.block' })
      return true
    }),
    KeyBinding.of({ key: 'Escape', run: escapeSelection }),
    KeyBinding.of({ key: 'ArrowUp', run: move(-1), shift: move(-1, true) }),
    KeyBinding.of({ key: 'ArrowDown', run: move(1), shift: move(1, true) }),
    KeyBinding.of({ key: 'ArrowLeft', run: editEdge(false) }),
    KeyBinding.of({ key: 'ArrowRight', run: editEdge(true) }),
    KeyBinding.of({ key: 'Enter', run: enterSelection }),
    KeyBinding.of({
      key: 'Space',
      allowDefault: true,
      run: ({ state }) => {
        if (state.readOnly || !(state.selection instanceof BlockSelection)) return false
        const blocks = state.selection.blocks
        if (blocks.length !== 1 || blocks[0]!.node.type !== MathBlock) return false
        return { effects: openMathEditor.of(blocks[0]!.before), scrollIntoView: true }
      }
    }),
    KeyBinding.of({
      key: 'Mod-a',
      run: ({ state }) => {
        const selected = state.selection
        if (selected instanceof CellSelection) {
          const table = tableHeadCell(state)?.parent?.parent
          const whole = table && allTableCells(state.doc, table)
          return whole && !whole.eq(selected) ? { selection: whole, userEvent: 'select' } : false
        }
        if (!(selected instanceof BlockSelection)) return false
        const first = state.doc.resolveNode(0)!
        const last = state.doc.resolveNode(state.doc.length - state.doc.lastChild!.length)!
        return { selection: new BlockSelection(first, last), userEvent: 'select.block' }
      }
    })
  ])
]

/** The complete blocks touched by the current text or block selection. */
export function selectedUnits(state: GardState): Pos.Node[] | null {
  if (state.selection instanceof BlockSelection) return state.selection.blocks
  const { doc, selection } = state
  const forward = selection.anchor <= selection.head
  const anchor = unitAt(doc, selection.anchor, forward ? 1 : -1)
  const head = unitAt(doc, selection.head, forward ? -1 : 1)
  if (!anchor) return null
  if (!head) return [anchor]
  return blocksBetween(doc, Math.min(anchor.before, head.before), Math.max(anchor.after, head.after))
}
