// This file defines a correction that normalizes tables, making sure
// no cells overlap (which can happen, if you have the wrong col- and
// rowspans). Uses the problems reported by `TableMap`.

import { Plot, ChangeSet } from '../doc'
import { Table, ColSpan, RowSpan } from '../types'
import { Correction } from '../state'
import { TableMap } from './tablemap'

export const tableCorrection = Correction.onContent(Table, pos => {
  const map = TableMap.get(pos.node, pos.start)
  if (!map.data.problems) return null

  const { schema } = pos.doc
  // Track which rows we must add cells to, so that we can adjust that
  // when fixing collisions.
  const mustAdd: number[] = [],
    changes: ChangeSet.Spec[] = []
  for (let i = 0; i < map.height; i++) mustAdd.push(0)
  for (let i = 0; i < map.data.problems.length; i++) {
    const prob = map.data.problems[i]!
    if (prob.type == 'collision') {
      const pos = prob.pos + map.start,
        rect = map.cellRect(pos),
        cell = map.getCell(pos)
      const colSpan = ColSpan.isInSet(cell.marks),
        rowSpan = RowSpan.isInSet(cell.marks)
      if (colSpan) changes.push({ from: pos, remove: colSpan })
      if (rowSpan) changes.push({ from: pos, remove: rowSpan })
      for (let row = rect.startRow, endRow = row + (rowSpan ? rowSpan.value : 1), first = true; row < endRow; row++) {
        for (let col = rect.startCol, endCol = col + (colSpan ? colSpan.value : 1); col < endCol; col++) {
          if (first) {
            first = false
          } else if (map.cellAt(col, row) == pos) {
            let from = pos
            for (let scan = 0; from == pos; scan++) from = map.cellInsertionPos(col + scan, row)
            changes.push({ from, insert: [schema.createAndFill(cell.type.default!)] })
          }
        }
      }
    } else if (prob.type == 'missing') {
      mustAdd[prob.row]! += prob.n
    } else if (prob.type == 'overlong_rowspan') {
      const cell = map.getCell(prob.pos + map.start),
        cur = RowSpan.isInSet(cell.marks)!,
        newVal = cur.value - prob.n
      const from = pos.start + prob.pos
      changes.push(newVal == 1 ? { from, remove: cur } : { from, add: RowSpan.of(newVal) })
    }
  }
  let first, last
  for (let i = 0; i < mustAdd.length; i++) {
    if (mustAdd[i]) {
      if (first == null) first = i
      last = i
    }
  }
  // Add the necessary cells, using a heuristic for whether to add the
  // cells at the start or end of the rows (if it looks like a 'bite'
  // was taken out of the table, add cells at the start of the row
  // after the bite. Otherwise add them at the end).
  for (let i = 0, curPos = pos.start; i < map.height; i++) {
    const row = pos.node.content[i] as Plot,
      end = curPos + row.length
    const add = mustAdd[i]!
    if (add > 0) {
      const cell = schema.defaultContentPlot(row.tag.type)!
      const nodes = []
      for (let j = 0; j < add; j++) nodes.push(schema.createAndFill(cell))
      const side = (i == 0 || first == i - 1) && last == i ? curPos + 1 : end - 1
      changes.push({ from: side, insert: nodes })
    }
    curPos = end
  }

  return changes
})
