import { tablePresentation } from './table-presentation'
import type { Command } from '../core/command'
import { type ChangeSet, type Plot } from '../core/doc'
import { KeyBinding, Wordgard } from '../core/editor'
import { GardSelection, GardState, Transaction } from '../core/state'
import { CellSelection } from '../core/table'
import { TableMap } from '../core/table/tablemap'
import * as T from '../core/types'
import { Align, DataCell, HeaderCell, Table, TableRow, CellBackground, TableLayout, TableWidths } from './schema'
import { blockInsertion, dispatchStep } from './block-insert'
import { markChange } from './attributes'
import { headCell, editableTable, cellsIn, scopeRect, columnWidths, emptyCell, type TableScope } from './table-context'
import {
  padTable,
  insertAxis,
  deleteAxis,
  mergeCells,
  splitCells,
  moveAxis,
  sortRows,
  type StructureAction,
  type TableEdit
} from './table-structure'
export { editableTable } from './table-context'

export function tableInsertion(state: GardState): Transaction.Spec | null {
  if (state.readOnly || headCell(state)) return null
  const table = Table.create(
    Array.from({ length: 3 }, (_, row) => TableRow.create(Array.from({ length: 3 }, () => emptyCell(row === 0))))
  )
  const spec = blockInsertion(state, table)
  const changed = state.update(spec)
  let pos = 0
  changed.state.doc.iterate((node, at) => {
    if (node === table) pos = at
  })
  return { ...spec, selection: cx => GardSelection.near(cx, pos + 3, 1), userEvent: 'table.insert' }
}

export type TableAction =
  | StructureAction
  | 'header'
  | 'header_column'
  | 'align_left'
  | 'align_center'
  | 'align_right'
  | 'row_up'
  | 'row_down'
  | 'column_left'
  | 'column_right'
  | 'sort_ascending'
  | 'sort_descending'
  | 'distribute'
  | 'full_width'
  | 'delete_table'

export function changeTable(
  editor: Wordgard,
  action: TableAction,
  scope: TableScope = 'column',
  renderedWidth?: number
): boolean {
  let context = editableTable(editor.state)
  if (!context) return false
  // Normalize uneven rows only for structural operations, in the same undoable transaction.
  const padding = [
    'row_before',
    'row_after',
    'column_before',
    'column_after',
    'delete_row',
    'delete_column',
    'merge',
    'split'
  ].includes(action)
    ? padTable(context)
    : []
  const padded = editor.state.update({ changes: padding })
  context = editableTable(padded.state)!
  const { map, rect, table } = context
  const remove =
    action === 'delete_table' ||
    (action === 'delete_row' && rect.endRow - rect.startRow === map.height) ||
    (action === 'delete_column' && rect.endCol - rect.startCol === map.width)
  let edit: TableEdit | null = { changes: [], row: rect.startRow, column: rect.startCol }
  if (remove) edit.changes.push({ from: table.before, to: table.after, insert: [T.Paragraph.create([])] })
  else {
    switch (action) {
      case 'row_before':
        edit = insertAxis(context, 'row', rect.startRow)
        break
      case 'row_after':
        edit = insertAxis(context, 'row', rect.endRow)
        break
      case 'column_before':
        edit = insertAxis(context, 'column', rect.startCol)
        break
      case 'column_after':
        edit = insertAxis(context, 'column', rect.endCol)
        break
      case 'delete_row':
        edit = deleteAxis(context, 'row')
        break
      case 'delete_column':
        edit = deleteAxis(context, 'column')
        break
      case 'merge':
        edit = mergeCells(context)
        break
      case 'split':
        edit = splitCells(context)
        break
      case 'row_up':
        edit = moveAxis(context, 'row', rect.startRow - 1)
        break
      case 'row_down':
        edit = moveAxis(context, 'row', rect.endRow + 1)
        break
      case 'column_left':
        edit = moveAxis(context, 'column', rect.startCol - 1)
        break
      case 'column_right':
        edit = moveAxis(context, 'column', rect.endCol + 1)
        break
      case 'sort_ascending':
      case 'sort_descending':
        edit = sortRows(context, action === 'sort_descending')
        break
      case 'header':
      case 'header_column': {
        const cells = cellsIn(map, scopeRect(context, action === 'header' ? 'row' : 'column'))
        const type = cells.every(pos => map.getCell(pos).type === HeaderCell.type) ? DataCell : HeaderCell
        for (const pos of cells) {
          edit.changes.push({ from: pos, to: pos + 1, insert: [type.withMarks(map.getCell(pos).marks)] })
        }
        break
      }
      case 'align_left':
      case 'align_center':
      case 'align_right': {
        const align = ({ align_left: 'left', align_center: 'center', align_right: 'right' } as const)[action]
        for (const pos of cellsIn(map, scopeRect(context, scope))) {
          edit.changes.push({ from: pos, add: Align.of(align) })
        }
        break
      }
      case 'full_width': {
        const change = markChange(table.node, table.before, TableLayout, table.node.mark(TableLayout) ? null : 'full')
        if (change) edit.changes.push(change)
        break
      }
      case 'distribute': {
        const widths = columnWidths(context, renderedWidth)
        const area = scopeRect(context, scope)
        const width = Math.round(
          widths.slice(area.startCol, area.endCol).reduce((sum, n) => sum + n, 0) / (area.endCol - area.startCol)
        )
        widths.fill(width, area.startCol, area.endCol)
        edit.changes.push({ from: table.before, add: TableWidths.of(widths.join(',')) })
        break
      }
    }
  }
  if (!edit) return false
  const target = edit
  const preserveSelection = [
    'header',
    'header_column',
    'align_left',
    'align_center',
    'align_right',
    'full_width',
    'distribute'
  ].includes(action)
  const operation: Transaction.Spec = {
    changes: edit.changes,
    selection: preserveSelection
      ? undefined
      : cx => {
          if (remove) return GardSelection.near(cx, table.before + 1, 1)
          const updated = cx.doc.nodeAt(table.before) as Plot
          const next = TableMap.get(updated, table.start)
          const pos = next.cellAt(target.column, target.row) ?? next.nearestCell(table.start, 1)?.from
          return GardSelection.near(cx, (pos ?? table.start) + 1, 1)
        }
  }
  dispatchStep(editor, {
    ...Transaction.merge(editor.state, padded, { ...operation, sequential: true }),
    userEvent: 'table.configure'
  })
  editor.focus()
  return true
}

export function colorTableCells(editor: Wordgard, color: string | null, scope: TableScope): boolean {
  const context = editableTable(editor.state)
  if (!context || (color !== null && !/^#[0-9a-fA-F]{6}$/.test(color))) return false
  const changes: ChangeSet.Spec[] = []
  for (const pos of cellsIn(context.map, scopeRect(context, scope))) {
    const change = markChange(context.map.getCell(pos), pos, CellBackground, color)
    if (change) changes.push(change)
  }
  dispatchStep(editor, { changes, userEvent: 'table.format' })
  editor.focus()
  return true
}

export function resizeTable(editor: Wordgard, pos: number, widths: readonly number[]): boolean {
  const table = editor.state.doc.nodeAt(pos)
  if (editor.state.readOnly || table?.type !== Table.type || !widths.length) return false
  const value = widths.map(width => Math.max(25, Math.min(9999, Math.round(width)))).join(',')
  dispatchStep(editor, { changes: { from: pos, add: TableWidths.of(value) }, userEvent: 'table.resize' })
  return true
}

export function moveTableAxis(editor: Wordgard, axis: 'row' | 'column', destination: number): boolean {
  const context = editableTable(editor.state)
  if (!context) return false
  const edit = moveAxis(context, axis, destination)
  if (!edit) return false
  dispatchStep(editor, {
    changes: edit.changes,
    selection: cx => {
      const map = TableMap.get(cx.doc.nodeAt(context.table.before) as Plot, context.table.start)
      return GardSelection.near(cx, map.cellAt(edit.column, edit.row)! + 1, 1)
    },
    userEvent: 'table.move'
  })
  editor.focus()
  return true
}

/** CSV preserves visible cell text; merged continuations are empty, and spreadsheet formulas are inert. */
export function tableCSV(context: NonNullable<ReturnType<typeof editableTable>>): string {
  const { map } = context
  return Array.from({ length: map.height }, (_, row) =>
    Array.from({ length: map.width }, (_, col) => {
      const pos = map.cellAt(col, row)
      const box = pos === null ? null : map.cellRect(pos)
      let value = pos !== null && box!.startRow === row && box!.startCol === col ? map.getCell(pos).textContent() : ''
      const numeric = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?%?$/.test(value.trim())
      if (!numeric && /^\s*[=+@-]/.test(value)) value = `'${value}`
      return `"${value.replace(/"/g, '""')}"`
    }).join(',')
  ).join('\r\n')
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
    if (!target && dir > 0 && editableTable(state)) {
      if (!changeTable(wg, 'row_after')) return false
      const context = editableTable(wg.state)!
      wg.dispatch({ selection: GardSelection.near(wg.state, context.map.cellAt(0, context.row)! + 1, 1) })
      return true
    }
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
  tablePresentation,
  selectedCells,
  // Before list and paragraph indentation, which also use Tab.
  GardState.prec.high([
    KeyBinding.of({ key: 'Tab', run: moveToCell(1), shift: moveToCell(-1) }),
    KeyBinding.of({ key: 'Mod-Enter', run: editor => changeTable(editor, 'row_after') })
  ])
]
