import { expect, test } from 'bun:test'
import { parseMarkdown, printMarkdown } from '../../src/document/markdown'
import { readTree } from '../../src/editor/convert'
import { headlessState } from '../../src/editor/extension'
import { editorFixture } from '../editor-fixture'
import fixtures from '../fixtures/tiptap-serialization.json'
import { editorContent, tiptapContent, type TiptapNode } from '../semantic'

for (const fixture of fixtures) {
  test(`${fixture.id} ${fixture.name} [semantic serialization]`, () => {
    const json = fixture.json as TiptapNode
    const expected = tiptapContent(json)
    const doc = editorFixture(json)
    expect(editorContent(doc)).toEqual(expected)
    let markdown = printMarkdown(readTree(doc))
    for (let cycle = 0; cycle < 3; cycle++) {
      const rebuilt = headlessState(markdown).doc
      expect(editorContent(rebuilt)).toEqual(expected)
      expect(readTree(rebuilt)).toEqual(parseMarkdown(markdown))
      const next = printMarkdown(readTree(rebuilt))
      if (fixture.id.endsWith(':600') || fixture.id.endsWith(':632')) expect(next).toBe(markdown)
      markdown = next
    }
  })
}
