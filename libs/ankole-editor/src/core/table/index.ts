// Table editing support. Defines a custom {@link CellSelection cell
// selection} type, a number of commands, and some support extensions
// to make table editing work.

// ### Support

// Miscellaneous extensions needed for working with tables.

export { tables } from './table'
export { tableMenu } from './menu'

// ### Cell Selection

// Custom handling of cross-cell selections makes it possible to
// select rows, columns, or rectangles in a table.

export { CellSelection } from './cellselection'

// ### Commands

// Table editing commands.

export { addColumn, addRow, deleteColumn, deleteRow, toggleHeaderCell, mergeCells, splitCell } from './tablecommands'

export { handleTablePaste } from './tablepaste'
