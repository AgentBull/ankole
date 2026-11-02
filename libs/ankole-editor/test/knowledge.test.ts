import { describe, expect, test } from 'bun:test'
import { knowledgeExtension } from '../src/editor/knowledge'
import { changeTable, editableTable } from '../src/editor/tables'
import { open, readTree, select } from './helpers'
import corpus from '../corpus/knowledge.json'
import { parseXml, printXml, parseMarkdown, printMarkdown, validateKnowledge } from '../src/document'

describe('knowledge vocabulary shared with the native codec', () => {
  for (const fixture of corpus) {
    test(fixture.name, () => {
      const tree = validateKnowledge(parseXml(fixture.xml))
      expect(printXml(parseMarkdown(printMarkdown(tree)))).toBe(printXml(tree))
    })
  }
  test('rejects doc-only layout, comments, and cell styling before saving', () => {
    for (const xml of [
      '<page><columns><column><p>A</p></column><column><p>B</p></column></columns></page>',
      '<page><embed ref="019a0000-0000-7000-8000-000000000001"/></page>',
      '<page><table><tr><th background="#123456"><p>A</p></th></tr></table></page>'
    ]) {
      expect(() => validateKnowledge(parseXml(xml))).toThrow()
    }
  })
})

test('knowledge table insertion and deletion keep exactly one header row', () => {
  const editor = open('| Header |\n| --- |\n| First |\n| Second |', knowledgeExtension)
  let position = 0
  editor.state.doc.iterate((node, pos) => {
    if (node.isText && node.param === 'Header') position = pos
  })
  select(editor, position)
  expect(changeTable(editor, 'row_before', 'row')).toBe(true)
  expect(() => validateKnowledge(readTree(editor))).not.toThrow()
  expect(printXml(readTree(editor))).toContain('<tr><th><p /></th></tr><tr><td><p>Header</p></td></tr>')
  expect(changeTable(editor, 'delete_row', 'row')).toBe(true)
  expect(printXml(readTree(editor))).toContain('<tr><th><p>Header</p></th></tr>')
  expect(editableTable(editor.state)?.map.height).toBe(3)
  expect(changeTable(editor, 'merge', 'table')).toBe(false)
})
