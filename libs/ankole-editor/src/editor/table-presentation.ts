import { Decoration } from '../core/editor'
import { GardState, Transaction } from '../core/state'
import { TableMap, Rect } from '../core/table/tablemap'
import { Table, TableWidths, HeaderCell } from './schema'
import { cellsIn } from './table-context'

export const previewTableWidth = Transaction.Effect.define<{ pos: number; widths: readonly number[] } | null>()
export const tableResizePreview = GardState.Field.define<{ pos: number; widths: readonly number[] } | null>({
  create: () => null,
  update(value, tr) {
    if (tr.docChanged) return null
    for (const effect of tr.effects) if (effect.is(previewTableWidth)) value = effect.value
    return value
  }
})

export const tablePresentation = [
  tableResizePreview,
  Decoration.Point.source.of(state => {
    const points: [Decoration.Point, number][] = []
    const preview = state.field(tableResizePreview)
    state.doc.iterate((node, pos) => {
      if (node.type !== Table.type || !node.isPlot) return
      const map = TableMap.get(node, pos + 1)
      const widths = preview?.pos === pos ? preview.widths : node.mark(TableWidths)?.split(',').map(Number)
      const complete = widths?.length === map.width
      const header = (rect: Rect) => {
        const cells = cellsIn(map, rect)
        return cells.length > 0 && cells.every(cell => map.getCell(cell).type === HeaderCell.type)
      }
      points.push([
        Decoration.Point.attributes({
          ...(header(new Rect(0, 0, map.width, 1)) ? { 'data-table-header-row': '' } : {}),
          ...(header(new Rect(0, 0, 1, map.height)) ? { 'data-table-header-column': '' } : {}),
          style: `--table-width: ${complete ? `${widths.reduce((sum, n) => sum + n, 0)}px` : '100%'}; --table-min-width: ${complete ? 0 : map.width * 80}px`
        }),
        pos
      ])
    })
    return Decoration.Point.set(points)
  })
]
