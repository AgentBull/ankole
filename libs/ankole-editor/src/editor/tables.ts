/*
 * Table editing (SPEC §7.6 keyboard table). Tab and Shift+Tab move to the end of the next and the
 * previous cell. A selection across cells becomes the core's cell selection, so that typing and
 * deleting change the content of the cells and keep the table. Rows can differ in length and can
 * be empty.
 */
import type { Command } from '../core/command'
import { Node, type Plot, type Pos } from '../core/doc'
import { KeyBinding, Wordgard } from '../core/editor'
import { GardSelection, GardState } from '../core/state'
import { CellSelection } from '../core/table'

/** The innermost table cell that holds the selection head. */
function headCell(state: GardState): Pos.Plot | null {
  const { selection, schema } = state
  // The head of a cell selection is at a cell boundary.
  const head = selection instanceof CellSelection ? state.doc.resolve(selection.headCell + 1) : state.sel.head
  return head.matchingParent(plot => schema.matchNode(plot.type, Node.Group.TableCell))
}

/** Move the caret to the end of the next or the previous cell, or out of the table after its last cell. */
const moveToCell =
  (dir: 1 | -1): Command =>
  wg => {
    const { state } = wg
    const cell = headCell(state)
    if (!cell) return false
    const table = cell.parent!.parent!
    // The cells of the table in document order, as [position before the cell, cell].
    const cells: [number, Plot][] = []
    let rowPos = table.start
    for (const row of table.node.content as Plot[]) {
      let cellPos = rowPos + 1
      for (const node of row.content as Plot[]) {
        cells.push([cellPos, node])
        cellPos += node.length
      }
      rowPos += row.length
    }
    const target = cells[cells.findIndex(([pos]) => pos === cell.before) + dir]
    const selection = target
      ? GardSelection.near(state, target[0] + target[1].length - 1, -1)
      : GardSelection.near(state, dir > 0 ? table.after : table.before, dir)
    return selection.eq(state.selection) || { selection, scrollIntoView: true, userEvent: 'select' }
  }

const selectedCells = Wordgard.styles({
  '.wg-selected-cell': {
    background: 'var(--color-brand-20)',
    // The DOM selection covers one of the cells. Show it like the others.
    '&::selection, & ::selection': { backgroundColor: 'transparent', color: 'currentColor' }
  }
})

export const tableEditing: GardState.Extension = [
  CellSelection.extension,
  selectedCells,
  // Before list and paragraph indentation, which also use Tab.
  GardState.prec.high(KeyBinding.of({ key: 'Tab', run: moveToCell(1), shift: moveToCell(-1) }))
]
