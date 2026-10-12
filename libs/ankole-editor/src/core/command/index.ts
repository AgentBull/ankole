// This module exports abstractions to represent editor commands,
// which represent user actions, as well as a collection of commands
// and supporting functions.

// ### Command Abstraction

// Commands functions are used by things like key bindings, menus,
// and event handlers to dispatch a specific type of user action.
// They have a parameter type (which may be null and ignored).

export { Command } from './command'

// ### Menu System

// A set of abstractions used to define generic menu items and
// structure. This does not include an actual implementation of a
// menu component. For that, see {@link editor.menuBar}.

export { Menu } from './menu'

// ### Basic Editing Commands

// Commands for fundamental editing actions.

export { insertText, insertLineBreak, enter, transposeChars, undo, redo } from './commands'

// ### Selection Commands

// Commands that move the selection. Most take an `extend` flag that
// controls whether they move or extend the selection.

export {
  moveByUnit,
  moveByWord,
  moveByLine,
  moveByPage,
  moveToLineSide,
  moveToTextblockSide,
  moveToDocSide,
  selectAll
} from './commands'

// ### Deletion Commands

// Commands that delete content.

export {
  deleteUnit,
  deleteWord,
  deleteToLineEnd,
  deleteLine,
  deleteCut,
  deleteRange,
  killToLineEnd,
  yankKilled
} from './commands'

// ### Block Manipulation Commands

// Commands that act on the document's block structure.

export { setAlignment, setDirection } from './commands'

// ### Inline Mark Commands

// Commands that toggle inline marks.

export { toggleMark, toggleEmphasis, toggleStrong, toggleUnderline } from './commands'

// ### Utility Functions

// Functions that may be useful when implementing your own commands.

export { deleteSelection, selectedTextblocks } from './helper'
