import { expect, test } from 'bun:test'
import { Transaction, GardState } from '../src/core/state'
import { undoDepth } from '../src/core/history'
import { Leaf } from '../src/core/doc'
import { initialState, editorExtension } from '../src/editor/extension'
import { editorPhrases } from '../src/editor/phrases'
import { blockOptions } from '../src/editor/block-actions'
import { readTree } from '../src/editor/convert'

test('host labels change block names without changing the document, selection or undo history', () => {
  const labels = GardState.Compartment.define()
  const initial = initialState('Saved text', [editorExtension(), labels.of([])])
  const before = initial.update({ changes: { from: initial.selection.head, insert: [Leaf.text('!')] } }).state
  expect(undoDepth(before)).toBe(1)
  const after = before.update({
    effects: labels.reconfigure(
      editorPhrases.translatePartial({ paragraph_title: 'Text', paragraph_detail: 'Plain paragraph' })
    ),
    annotations: Transaction.addToHistory.of(false)
  }).state
  const paragraph = blockOptions.find(option => option.type === 'paragraph')!
  expect(paragraph.title(before)).toBe('正文')
  expect(paragraph.title(after)).toBe('Text')
  expect(paragraph.detail(after)).toBe('Plain paragraph')
  expect(editorPhrases.get(after, 'undo')).toBe('撤销')
  expect(readTree(after.doc)).toEqual(readTree(before.doc))
  expect(after.selection.eq(before.selection)).toBe(true)
  expect(undoDepth(after)).toBe(undoDepth(before))
})
