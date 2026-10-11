import { Command, toggleMark } from '../core/command'
import type { Wordgard } from '../core/editor'
import { redo as redoCommand, undo as undoCommand } from '../core/history'
import { formats } from './schema'

export type FormatName = keyof typeof formats

/** Toggle a text format on the selection. Returns whether the command applied. */
export function toggleFormat(editor: Wordgard, format: FormatName): boolean {
  return Command.dispatch(editor, toggleMark, formats[format])
}

export function undo(editor: Wordgard): boolean {
  return Command.dispatch(editor, undoCommand)
}

export function redo(editor: Wordgard): boolean {
  return Command.dispatch(editor, redoCommand)
}
