import { Wordgard } from '../editor'
import { GardState, GardSelection } from '../state'
import { Table, TableRow, RowSpan, ColSpan } from '../types'
import { Plot, ChangeSet } from '../doc'
import { Command, Menu } from '../command'
import { tablePhrases } from '../phrases'
import {
  cellTag,
  headerCellTag,
  addRow,
  deleteRow as _deleteRow,
  addColumn,
  deleteColumn as _deleteColumn,
  mergeCells as _mergeCells,
  splitCell as _splitCell,
  toggleHeaderCell
} from './tablecommands'
import { CellSelection } from './cellselection'

const SVG = 'http://www.w3.org/2000/svg'
const Grid = { Size: 15, Margin: 4, Skip: 15 + 4, MaxW: 15, MaxH: 15 }

class DimensionPicker {
  dom: HTMLElement
  svg: SVGElement
  announce: HTMLElement
  width = 2
  height = 2
  gridWidth = 6
  gridHeight = 4
  ltr: boolean

  constructor(
    readonly wg: Wordgard,
    readonly finish: (width: number, height: number) => void
  ) {
    this.dom = document.createElement('div')
    this.dom.className = 'wg-dimension-picker'
    this.announce = this.dom.appendChild(document.createElement('div'))
    this.announce.className = 'wg-dimension-announce'
    this.announce.setAttribute('aria-live', 'polite')
    this.svg = this.dom.appendChild(document.createElementNS(SVG, 'svg'))
    this.svg.setAttribute('aria-hidden', 'true')
    this.ltr = wg.state.textLTR
    this.render()
    this.dom.addEventListener('mousemove', e => {
      const rect = this.svg.getBoundingClientRect()
      const xOff = this.ltr ? e.clientX - Grid.Margin - rect.left : rect.right - Grid.Margin - e.clientX
      const yOff = e.clientY - Grid.Margin - rect.top
      const x = Math.max(0, Math.floor(xOff / Grid.Skip)),
        y = Math.max(0, Math.floor(yOff / Grid.Skip))
      this.setSize(x + 1, y + 1)
    })
    this.dom.addEventListener('mousedown', e => {
      if (e.button == 0) {
        e.preventDefault()
        this.finish(this.width, this.height)
      }
    })
    this.dom.addEventListener('keydown', e => {
      if (e.key == (this.ltr ? 'ArrowLeft' : 'ArrowRight') && this.width > 1) {
        this.setSize(this.width - 1, this.height)
      } else if (e.key == (this.ltr ? 'ArrowRight' : 'ArrowLeft') && this.width < Grid.MaxW) {
        this.setSize(this.width + 1, this.height)
      } else if (e.key == 'ArrowUp' && this.height > 1) {
        this.setSize(this.width, this.height - 1)
      } else if (e.key == 'ArrowDown' && this.height < Grid.MaxH) {
        this.setSize(this.width, this.height + 1)
      } else if (e.key == ' ' || e.key == 'Enter') {
        this.finish(this.width, this.height)
      } else {
        return
      }
      e.preventDefault()
    })
  }

  render() {
    this.dom.setAttribute('aria-label', tablePhrases.get(this.wg.state, 'dimensions_title', this.width, this.height))
    this.announce.textContent = tablePhrases.get(this.wg.state, 'dimensions_live', this.width, this.height)
    this.svg.textContent = ''
    const width = this.gridWidth * Grid.Skip + Grid.Margin
    this.svg.setAttribute('width', String(width))
    this.svg.setAttribute('height', String(this.gridHeight * Grid.Skip + Grid.Margin))
    for (let y = 0; y < this.gridHeight; y++) {
      for (let x = 0; x < this.gridWidth; x++) {
        const rect = this.svg.appendChild(document.createElementNS(SVG, 'rect'))
        rect.setAttribute('width', String(Grid.Size))
        rect.setAttribute('height', String(Grid.Size))
        rect.setAttribute('x', String(this.ltr ? x * Grid.Skip + Grid.Margin : width - (x + 1) * Grid.Skip))
        rect.setAttribute('y', String(y * Grid.Skip + Grid.Margin))
        rect.setAttribute(
          'class',
          x < this.width && y < this.height ? 'wg-dimension-cell wg-dimension-cell-active' : 'wg-dimension-cell'
        )
      }
    }
  }

  setSize(width: number, height: number) {
    if (width == this.width && height == this.height) return
    this.width = Math.min(Grid.MaxW, width)
    this.height = Math.min(Grid.MaxH, height)
    if (this.gridWidth <= this.width) this.gridWidth = Math.min(Grid.MaxW, this.width + 1)
    if (this.gridHeight <= this.height) this.gridHeight = Math.min(Grid.MaxH, this.height + 1)
    this.render()
  }
}

function insertTable(wg: Wordgard, width: number, height: number) {
  const { state } = wg
  const { schema } = state.doc
  const cell = cellTag(schema)
  if (!cell) return
  const cellNode = schema.createAndFill(cell) as Plot,
    cells: Plot[] = []
  for (let i = 0; i < width; i++) cells.push(cellNode)
  const row = TableRow.create(cells),
    rows: Plot[] = []
  for (let i = 0; i < height; i++) rows.push(row)
  const table = Table.create(rows),
    { from, to } = state.selection.replacementRange
  const changes = ChangeSet.create(state.doc, { from, to, insert: [table], fit: true })
  const tablePos = changes.findInserted(tag => tag.type == Table.type)
  wg.dispatch({
    changes,
    selection: cx => GardSelection.near(cx, tablePos == null ? from : tablePos + 3, 1),
    userEvent: 'insert.table'
  })
}

const dimensionPicker = Menu.CustomControl.define({
  render(wg, done) {
    return new DimensionPicker(wg, (width, height) => {
      done()
      insertTable(wg, width, height)
      wg.focus()
    })
  }
})

/**
 * Returns the full table menu. This consists of two buttons that
 * look the same but behave differently. When the selection is not in
 * a table, {@link tableMenu.createTable} is shown, which provides an
 * interface for creating a new table. Otherwise, {@link
 * tableMenu.modifyTable} is visible, which contains menu items for
 * manipulating the current table.
 */
export function tableMenu(): GardState.Extension {
  return [
    tableMenu.createTable,
    tableMenu.modifyTable,
    tableMenu.toggleHeader,
    tableMenu.addRowAbove,
    tableMenu.addRowBelow,
    tableMenu.deleteRow,
    tableMenu.addColumnBefore,
    tableMenu.addColumnAfter,
    tableMenu.deleteColumn,
    tableMenu.mergeCells,
    tableMenu.splitCell
  ]
}

const tableIcon = {
  icon: 'M0 23a23 13 0 0 1 13-13h74a13 13 0 0 1 13 13v54a 13 13 0 0 1 -13 13h-74a13 13 0 0 1 -13 -13v-54M7 31v14h25v-14h-25M37 31v14h26v-14h-26M68 31v14h25v-14h-26M7 50v14h25v-14h-25M37 50v14h26v-14h-26M68 50v14h25v-14h-26M7 69v8a6 6 0 0 0 6 6h19v-14h-25M37 69v14h26v-14h-26M68 69v14h19a6 6 0 0 0 6 -6v-8h-26'
}

export namespace tableMenu {
  /**
   * A menu button that expands into a dimension picker when
   * activated, which inserts a table with the given dimensions when
   * confirmed.
   */
  export const createTable = Menu.Submenu.define({
    select(state) {
      return state.schema.has(Table) && !state.sel.head.matchingParent(plot => plot.type == Table.type)
    },
    label: tableIcon,
    description: tablePhrases.ref('insert_table'),
    enable: s => !s.readOnly,
    parent: Menu.Group.insert,
    rank: 70,
    content: [dimensionPicker]
  })

  /** A submenu with for table manipulation items. */
  export const modifyTable = Menu.Submenu.define({
    select(state) {
      return !!state.sel.head.matchingParent(plot => plot.type == Table.type)
    },
    label: tableIcon,
    description: tablePhrases.ref('modify_table'),
    parent: Menu.Group.block,
    rank: 90
  })

  /**
   * A button that toggles the selected cells between header and
   * normal cells.
   */
  export const toggleHeader = Menu.Button.define({
    run: toggleHeaderCell,
    select: state => !!headerCellTag(state.schema),
    label: tablePhrases.ref('toggle_header'),
    enable: s => !s.readOnly,
    parent: modifyTable,
    rank: 10
  })

  /** Adds a row above the selected cell(s). */
  export const addRowAbove = Menu.Button.define({
    run: wg => Command.dispatch(wg, addRow, 'before'),
    label: tablePhrases.ref('add_row_above'),
    enable: s => !s.readOnly,
    parent: modifyTable,
    rank: 20
  })

  /** Adds a row below the selected cell(s). */
  export const addRowBelow = Menu.Button.define({
    run: wg => Command.dispatch(wg, addRow, 'after'),
    label: tablePhrases.ref('add_row_below'),
    enable: s => !s.readOnly,
    parent: modifyTable,
    rank: 21
  })

  /** Deletes the row(s) that hold the selection. */
  export const deleteRow = Menu.Button.define({
    run: _deleteRow,
    label: tablePhrases.ref('delete_row'),
    enable: s => !s.readOnly,
    parent: modifyTable,
    rank: 25
  })

  /** Button to insert a column before the selection. */
  export const addColumnBefore = Menu.Button.define({
    run: wg => Command.dispatch(wg, addColumn, 'before'),
    label: tablePhrases.ref('add_col_before'),
    enable: s => !s.readOnly,
    parent: modifyTable,
    rank: 30
  })

  /** Add a column after the selection. */
  export const addColumnAfter = Menu.Button.define({
    run: wg => Command.dispatch(wg, addColumn, 'after'),
    label: tablePhrases.ref('add_col_after'),
    enable: s => !s.readOnly,
    parent: modifyTable,
    rank: 31
  })

  /** Delete the selected column(s). */
  export const deleteColumn = Menu.Button.define({
    run: _deleteColumn,
    label: tablePhrases.ref('delete_col'),
    enable: s => !s.readOnly,
    parent: modifyTable,
    rank: 35
  })

  /** When multiple cells are selected, merge them into a single cell. */
  export const mergeCells = Menu.Button.define({
    run: _mergeCells,
    select: state => {
      const { selection } = state
      return (
        selection instanceof CellSelection &&
        selection.ranges.length > 1 &&
        state.schema.has(ColSpan) &&
        state.schema.has(RowSpan)
      )
    },
    label: tablePhrases.ref('merge_cells'),
    enable: s => !s.readOnly,
    parent: modifyTable,
    rank: 40
  })

  /**
   * When a merged cell is selected, split it into its smallest
   * elements again.
   */
  export const splitCell = Menu.Button.define({
    run: _splitCell,
    select: state => {
      const { selection } = state
      if (!(selection instanceof CellSelection) || selection.ranges.length != 1) return false
      const cell = state.sel.from.nodeAfter
      return !!(cell && (cell.mark(ColSpan) || cell.mark(RowSpan)))
    },
    label: tablePhrases.ref('split_cell'),
    enable: s => !s.readOnly,
    parent: modifyTable,
    rank: 41
  })
}
