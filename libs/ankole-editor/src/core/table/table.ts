import { Wordgard } from '../editor'
import { GardState } from '../state'
import { Table, TableRow, Cell, HeaderCell, BlockCell, BlockHeaderCell, ColSpan, RowSpan } from '../types'
import { CellSelection } from './cellselection'
import { tableCorrection } from './correct'
import { tablePasteHandler, tableDropHandler } from './tablepaste'
import { tableMenu } from './menu'

const tableTheme = Wordgard.styles({
  table: {
    borderCollapse: 'collapse',
    tableLayout: 'fixed',
    width: '100%',
    overflow: 'hidden'
  },
  'td, th': {
    verticalAlign: 'top',
    border: '1px solid var(--wg-border-color)',
    padding: '3px 6px',
    textAlign: 'left'
  },

  '.wg-selected-cell': {
    background: '#ddf',
    '&::selection, & ::selection': { backgroundColor: 'transparent' },
    '& :focus ::selection, & :focus::selection': { backgroundColor: 'Highlight' }
  },

  '.wg-dimension-announce': {
    position: 'absolute',
    width: '0px',
    overflow: 'hidden'
  },
  '.wg-dimension-cell': {
    fill: 'none',
    stroke: '#ccc',
    strokeWidth: '1.5px',
    rx: '2px'
  },
  '.wg-dimension-cell-active': {
    stroke: 'var(--wg-highlight-color)'
  }
})

/**
 * Enable table support with the given configuration. The returned
 * extension will include the necessary schema elements, the {@link
 * CellSelection cell selection}, {@link tables.correction correction},
 * {@link tables.pasteHandler paste} and {@link tables.dropHandler
 * drop} handlers, and {@link tableMenu menu items}.
 */
export function tables(config: tables.Spec = {}): GardState.Extension {
  const result: GardState.Extension[] = [
    GardState.schemaElement.of(Table),
    GardState.schemaElement.of(TableRow),
    tableTheme,
    CellSelection,
    tableCorrection,
    tablePasteHandler,
    tableDropHandler,
    tableMenu()
  ]
  if (config.cellContent == 'block') {
    result.push(GardState.schemaElement.of(BlockCell))
    if (config.headerCells != false) result.push(GardState.schemaElement.of(BlockHeaderCell))
  } else {
    result.push(GardState.schemaElement.of(Cell))
    if (config.headerCells != false) result.push(GardState.schemaElement.of(HeaderCell))
  }
  if (config.cellSpanning != false) {
    result.push(GardState.schemaElement.of(RowSpan), GardState.schemaElement.of(ColSpan))
  }
  return result
}

export namespace tables {
  /** Configuration options for the {@link tables} function. */
  export type Spec = {
    /** Controls whether headers cells are enabled. Defaults to true. */
    headerCells?: boolean
    /**
     * By default, cells can be {@link mergeCells merged}, making
     * them span more than one row or column. Set this to false to
     * disable that.
     */
    cellSpanning?: boolean
    /**
     * Determines whether cells contain inline content or block
     * content. Defaults to `"inline"`.
     */
    cellContent?: 'inline' | 'block'
  }

  /** Correct tables where the cells do not form a proper rectangle. */
  export const correction = tableCorrection

  /**
   * A paste handler that makes pasting into tables fill the entire
   * cell selection or, if table cell content is being pasted into a
   * cell, to expand the pasted region over the shape covered by the
   * pasted content.
   */
  export const pasteHandler = tablePasteHandler

  /** A drop handler that overrides drops that move table cells. */
  export const dropHandler = tableDropHandler
}
