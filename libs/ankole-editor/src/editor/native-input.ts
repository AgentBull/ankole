/*
 * Input events (SPEC §7.5 Input events). The core handles typing, replacement text, line breaks,
 * paragraphs, transposition, yank, the deletions, undo, redo, bold, italic, underline and
 * composition. This module adds strikethrough, cut, drag and drop, and cancels the input types
 * that the page does not support.
 */
import { ChangeSet } from '../core/doc'
import { Command, deleteCut, deleteRange, deleteUnit } from '../core/command'
import { Wordgard } from '../core/editor'
import { readClipboard } from '../core/editor/clipboard'
import { GardSelection } from '../core/state'
import { toggleFormat } from './commands'

/** Input types that change nothing on the page. */
const cancelled = new Set([
  'deleteEntireSoftLine',
  'formatSuperscript',
  'formatSubscript',
  'formatJustifyLeft',
  'formatJustifyCenter',
  'formatJustifyRight',
  'formatJustifyFull',
  'formatIndent',
  'formatOutdent',
  'formatRemove',
  'formatSetBlockTextDirection',
  'formatSetInlineTextDirection',
  'formatBackColor',
  'formatFontColor',
  'formatFontName',
  'insertOrderedList',
  'insertUnorderedList',
  'insertHorizontalRule',
  'insertLink'
])

/** The document range of the event's first target range, if the event has one. */
function targetRange(wg: Wordgard, event: InputEvent) {
  const range = event.getTargetRanges()[0]
  if (!range) return null
  const from = wg.posAtDOM(range.startContainer, range.startOffset)
  return { from, to: range.collapsed ? from : wg.posAtDOM(range.endContainer, range.endOffset) }
}

/**
 * Delete the target range. Without one, or when it is the selection, delete the selection as a cut
 * or Backspace does.
 */
function deleteTarget(wg: Wordgard, event: InputEvent, userEvent: 'delete.cut' | 'delete.drag') {
  const range = targetRange(wg, event)
  const selected = wg.state.selection.replacementRange
  if (!range || (range.from === selected.from && range.to === selected.to)) {
    if (wg.state.selection.empty) return
    if (userEvent == 'delete.cut') Command.dispatch(wg, deleteCut)
    else Command.dispatch(wg, deleteUnit, 'backward')
  } else if (range.from < range.to) {
    Command.dispatch(wg, deleteRange, { ...range, userEvent })
  }
}

/** Insert the dropped content at the drop point and select it. */
function drop(wg: Wordgard, event: InputEvent) {
  const at = targetRange(wg, event) ?? wg.state.selection.replacementRange
  const slice = event.dataTransfer && readClipboard(wg.state, event.dataTransfer, wg.state.doc.resolve(at.from), false)
  if (!slice) return
  const changes = ChangeSet.create(wg.state.doc, {
    from: at.from,
    to: at.to,
    insert: slice,
    fit: true
  })
  wg.dispatch({
    changes,
    selection: GardSelection.range(changes.mapPos(at.from, -1), changes.mapPos(at.to, 1)),
    scrollIntoView: true,
    userEvent: 'input.drop'
  })
}

export const nativeInput = Wordgard.domEventHandler('beforeinput', (event, wg) => {
  const type = event.inputType
  if (cancelled.has(type)) return true
  if (wg.state.readOnly) return false
  switch (type) {
    case 'formatStrikeThrough':
      toggleFormat(wg, 's')
      return true
    case 'deleteByCut':
      deleteTarget(wg, event, 'delete.cut')
      return true
    case 'deleteByDrag':
      deleteTarget(wg, event, 'delete.drag')
      // A browser that deletes the dragged text itself fires insertFromDrop with a target in the
      // changed DOM. Draw the deletion now, so that the DOM is the same.
      wg.flush()
      return true
    case 'insertFromDrop':
      drop(wg, event)
      return true
    default:
      return false
  }
})
