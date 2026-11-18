import { Command, toggleMark } from '../core/command'
import type { Wordgard } from '../core/editor'
import { redo as redoCommand, undo as undoCommand } from '../core/history'
import { formats, ImageTitle } from './schema'
import { GardSelection } from '../core/state'
import { Leaf } from '../core/doc'
import { Image, ImageAlt } from '../core/types'
import { dispatchStep } from './block-insert'
import { isKnowledge } from './knowledge'

export type FormatName = keyof typeof formats

/** Toggle a text format on the selection. Returns whether the command applied. */
export function toggleFormat(editor: Wordgard, format: FormatName): boolean {
  if (isKnowledge(editor.state) && !['strong', 'em', 's', 'code'].includes(format)) return false
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
  const { ranges } = selection
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

/**
 * Replace each range with `text` as one undoable edit. A replacement keeps the marks of the text it replaces.
 * Ranges are positions in the current document and must not overlap. Returns whether the document changed.
 */
export function replaceText(editor: Wordgard, ranges: readonly { from: number; to: number }[], text: string): boolean {
  if (editor.state.readOnly || editor.composing || !ranges.length) return false
  const before = editor.state.doc
  dispatchStep(editor, {
    changes: {
      correct: ranges.map(({ from, to }) => ({
        from,
        to,
        insert: text ? [Leaf.text(text, before.resolve(from).marks(before.resolve(to)))] : [],
        fit: true
      })),
      local: true
    },
    userEvent: 'input.replace'
  })
  return editor.state.doc !== before
}
