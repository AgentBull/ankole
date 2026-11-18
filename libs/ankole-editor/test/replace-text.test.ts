import { expect, test } from 'bun:test'
import { parseXml, printXml } from '../src/document/xml'
import { replaceText, undo } from '../src/editor/commands'
import { open, readTree } from './helpers'

const page = (body: string) => open(parseXml(`<page>${body}</page>`))
const body = (editor: ReturnType<typeof page>) => printXml(readTree(editor))
const expected = (xml: string) => printXml(parseXml(`<page>${xml}</page>`))
function textStart(editor: ReturnType<typeof page>, text: string) {
  let result = -1
  editor.state.doc.iterate((node, pos) => {
    if (node.isPlot && node.inlineContent && node.textContent() === text) result = pos + 1
  })
  if (result < 0) throw new Error(`Missing block: ${text}`)
  return result
}

test('replaceText replaces every range in one edit that a single undo restores', () => {
  const editor = page('<p>foo bar foo</p><p>foo</p>')
  const first = textStart(editor, 'foo bar foo')
  const second = textStart(editor, 'foo')
  const ranges = [
    { from: first, to: first + 3 },
    { from: first + 8, to: first + 11 },
    { from: second, to: second + 3 }
  ]
  expect(replaceText(editor, ranges, 'quux')).toBe(true)
  expect(body(editor)).toBe(expected('<p>quux bar quux</p><p>quux</p>'))
  undo(editor)
  expect(body(editor)).toBe(expected('<p>foo bar foo</p><p>foo</p>'))
})

test('replaceText deletes the range when the replacement is empty and does nothing without ranges', () => {
  const editor = page('<p>foo bar</p>')
  const start = textStart(editor, 'foo bar')
  expect(replaceText(editor, [], 'x')).toBe(false)
  expect(replaceText(editor, [{ from: start, to: start + 4 }], '')).toBe(true)
  expect(body(editor)).toBe(expected('<p>bar</p>'))
})
