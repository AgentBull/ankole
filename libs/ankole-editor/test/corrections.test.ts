import { expect, test } from 'bun:test'
import { Leaf, type Plot } from '../src/core/doc'
import * as T from '../src/core/types'
import { readTree } from '../src/editor/convert'
import { headlessState } from '../src/editor/extension'
import { blockInsertion } from '../src/editor/block-insert'
import { BlockStyle, TextStyle } from '../src/editor/schema'

test('formats added inside a code block are removed', () => {
  const state = headlessState('```js\nlet a\n```')
  const next = state.update({ changes: { from: 1, to: 6, add: T.Strong } }).state
  expect((next.doc.content[0] as Plot).content[0]!.marks).toEqual([])
  expect(readTree(next.doc)).toEqual(readTree(state.doc))
})

test('text with formats pasted into a code block becomes plain', () => {
  const state = headlessState('```\nab\n```')
  const next = state.update({ changes: { from: 2, insert: [Leaf.text('x', T.Strong.addToSet([]))] } }).state
  expect((next.doc.content[0] as Plot).content.every(child => !child.marks.length)).toBe(true)
})

test('a code block that splits around an inserted block keeps its language and meta in both parts', () => {
  const state = headlessState('```js title\nab\n```')
  const next = state.update({
    ...blockInsertion(state.update({ selection: { anchor: 2 } }).state, T.HorizontalRule)
  }).state
  const pres = readTree(next.doc).children.filter(child => child.type === 'element' && child.name === 'pre')
  expect(pres.map(pre => (pre.type === 'element' ? pre.attrs : {}))).toEqual([
    { lang: 'js', meta: 'title' },
    { lang: 'js', meta: 'title' }
  ])
})

test('styles that reach the document keep only the declarations that the page stores', () => {
  const state = headlessState('alpha omega')
  const next = state.update({
    changes: [
      { from: 1, to: 6, add: TextStyle.of('position:fixed;color:red') },
      { from: 7, to: 12, add: TextStyle.of('position:fixed') },
      { from: 0, add: BlockStyle.of('margin:0;color:blue') }
    ]
  }).state
  const paragraph = next.doc.content[0] as Plot
  expect(paragraph.mark(BlockStyle)).toBe('color:blue')
  expect(paragraph.content.map(child => [(child as Leaf).param, child.mark(TextStyle) ?? null])).toEqual([
    ['alpha', 'color:red'],
    [' omega', null]
  ])
})
