import { Command, toggleMark } from '../core/command'
import type { Wordgard } from '../core/editor'
import { redo as redoCommand, undo as undoCommand } from '../core/history'
import { formats, ImageTitle } from './schema'
import { GardSelection } from '../core/state'
import { Image, ImageAlt } from '../core/types'
import { dispatchStep } from './block-insert'
import { BlockSelection } from './block-selection'

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

/** Insert an uploaded image into the current selection as one undoable edit. */
export function insertImage(editor: Wordgard, image: { src: string; alt?: string; title?: string }): boolean {
  if (editor.state.readOnly || editor.composing) return false
  const before = editor.state.doc
  const selection = editor.state.selection
  const ranges = selection instanceof BlockSelection ? selection.ranges : [selection.replacementRange]
  const { to } = ranges[0]!
  const marks = [
    ...(image.alt === undefined ? [] : [ImageAlt.of(image.alt)]),
    ...(image.title === undefined ? [] : [ImageTitle.of(image.title)])
  ]
  dispatchStep(editor, {
    changes: {
      correct: ranges.map((range, index) => ({
        from: range.from,
        to: range.to,
        insert: index ? [] : [Image.of(image.src, marks)],
        fit: true
      })),
      local: true
    },
    selection: (context, changes) => GardSelection.near(context, changes.mapPos(to, 1), -1),
    userEvent: 'image.insert'
  })
  return editor.state.doc !== before
}
