import { expect, test } from 'bun:test'
import { Leaf, type Plot } from '../src/core/doc'
import * as T from '../src/core/types'
import { parseMarkdown } from '../src/document/markdown'
import { parseXml } from '../src/document/xml'
import { applyBlockType } from '../src/editor/block-actions'
import { redo, undo } from '../src/editor/commands'
import { PageSession } from '../src/editor/page-session'
import { open as openEditor, readTree, select, setComposing, typeText } from './helpers'

function open(source = 'Before') {
  const editor = openEditor(source)
  return { editor, session: new PageSession(editor) }
}

const appendParagraph = (editor: ReturnType<typeof openEditor>, text: string) =>
  editor.dispatch({ changes: { from: editor.state.doc.length, insert: [T.Paragraph.create([Leaf.text(text)])] } })

test('an XML write applies attributes, empty paragraphs and unknown elements in one undo step', () => {
  const { editor, session } = open()
  const xml =
    '<page><p /><p align="center" source="manual">hello</p><widget __proto__="own"><p>nested</p></widget></page>'
  const start = session.revision
  const applied = session.apply({ format: 'xml', source: xml, revision: start })
  expect(applied.warnings).toEqual(['<p> 的未知属性 source', '未知元素 <widget>'])
  expect([applied.revision, session.revision]).toEqual([start + 1, start + 1])
  expect(readTree(editor)).toEqual(parseXml(xml))
  expect(editor.state.doc.content.map(node => node.name)).toEqual(['Paragraph', 'Paragraph', 'UnknownBlock'])
  expect(undo(editor)).toBe(true)
  expect(session.read().markdown).toBe('Before')
  expect(redo(editor)).toBe(true)
  expect(readTree(editor)).toEqual(parseXml(xml))
})

test('attributes on a paragraph survive edits and copies', () => {
  const { editor, session } = open('<p __proto__="own" source="manual">hello</p>')
  select(editor)
  typeText(editor, ' world')
  const paragraph = editor.state.doc.content[0] as Plot
  editor.dispatch({ changes: { from: paragraph.length, insert: [paragraph.tag.create([Leaf.text('copied')])] } })
  const xml = session.read().xml
  expect(xml).toBe(
    '<page><p __proto__="own" source="manual">hello world</p><p __proto__="own" source="manual">copied</p></page>'
  )
  const { session: reopened } = open(session.read().markdown)
  expect(reopened.read().xml).toBe(xml)
})

test('stale writes and invalid sources change neither content nor revision', () => {
  const { editor, session } = open()
  const stale = session.read()
  appendParagraph(editor, 'newer')
  const before = session.read()
  expect(before.revision).not.toBe(stale.revision)
  expect(() => session.apply({ format: 'xml', source: '<page><p>stale</p></page>', revision: stale.revision })).toThrow(
    '已变化'
  )
  for (const source of [
    '<page><p></page>',
    '<page><p align="wrong">invalid</p></page>',
    '<page><p x="1" x="2"/></page>'
  ]) {
    expect(() => session.apply({ format: 'xml', source, revision: before.revision })).toThrow()
  }
  for (const source of ['会议 <job_id> 开始', '<!-- note -->', 'see <https://x.com>']) {
    expect(() => session.apply({ format: 'markdown', source, revision: before.revision })).toThrow()
  }
  expect(session.read()).toEqual(before)
})

// The headless editor composes only when the test says so. The e2e tests cover a real composition.
test('a write waits for the end of an input method composition', () => {
  const { editor, session } = open()
  setComposing(editor, true)
  const before = session.read()
  expect(() => session.apply({ format: 'markdown', source: 'replace', revision: before.revision })).toThrow('输入法')
  expect(session.read()).toEqual(before)
  setComposing(editor, false)
})

// The editor applies a dispatch at once and draws it in a later frame. The headless editor never draws.
test('the revision check sees an edit that the editor has not drawn yet', () => {
  const { editor, session } = open()
  const snapshot = session.read()
  appendParagraph(editor, 'pending')
  expect(() => session.apply({ format: 'markdown', source: 'stale', revision: snapshot.revision })).toThrow('已变化')
  expect(session.read().markdown).toContain('pending')
})

test('a model writes natural Markdown with times, ratios and colons', () => {
  const { session } = open()
  const source = '# 周会\n\n会议 10:30 开始，比例 3:1，`status:ok`。\n\n- [ ] 跟进 key:value 的问题'
  const applied = session.apply({ format: 'markdown', source, revision: session.revision })
  expect(applied.markdown).toBe(source)
  expect(applied.warnings).toEqual([])
})

test('block conversions keep paragraph attributes', () => {
  const { editor, session } = open('<p source="manual">hello</p>')
  select(editor)
  applyBlockType(editor, 'h2')
  expect(session.read().xml).toBe('<page><h2 source="manual">hello</h2></page>')
  applyBlockType(editor, 'callout')
  expect(session.read().xml).toBe('<page><callout><p source="manual">hello</p></callout></page>')
})

test.each(['hello', ''])('a list conversion keeps paragraph attributes: %s', value => {
  const { editor, session } = open(`<p source="manual">${value}</p>`)
  select(editor)
  applyBlockType(editor, 'bullet')
  const expected = parseXml(`<page><ul><li><p source="manual">${value}</p></li></ul></page>`)
  expect(readTree(editor)).toEqual(expected)
  const snapshot = session.read()
  session.apply({ format: 'xml', source: snapshot.xml, revision: snapshot.revision })
  expect(readTree(editor)).toEqual(expected)
})

test.each([
  '',
  '<p />',
  '<p />\n\n<p />',
  'a\nb',
  '- plain\n- [ ] todo\n- plain again',
  '- first\n  - child\n\n  after'
])('page structure survives a page write: %s', source => {
  const { editor, session } = open(source)
  expect(readTree(editor)).toEqual(parseMarkdown(source))
  const current = session.read()
  session.apply({ format: 'xml', source: current.xml, revision: current.revision })
  expect(readTree(editor)).toEqual(parseMarkdown(source))
})
