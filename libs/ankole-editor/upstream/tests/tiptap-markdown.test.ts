import { expect, test } from 'bun:test'
import { Parser } from 'commonmark'
import { parseMarkdown, printMarkdown } from '../../src/document/markdown'
import { readTree } from '../../src/editor/convert'
import { headlessState } from '../../src/editor/extension'
import fixtures from '../fixtures/tiptap-markdown.json'
import differences from '../fixtures/tiptap-dialect.json'
import { commonmarkContent, editorContent, tiptapContent, type TiptapNode } from '../semantic'

for (const fixture of fixtures) {
  test(`${fixture.ids.join(' ')} ${fixture.name}`, () => {
    const adaptation = (differences as Record<string, { markdown: string; reason: string }>)[
      fixture.sourceFixture ?? ''
    ]
    let markdown = adaptation?.markdown ?? fixture.markdown
    const expected = fixture.expected
      ? tiptapContent(fixture.expected as TiptapNode)
      : commonmarkContent(new Parser().parse(markdown))
    for (let cycle = 0; cycle < 2; cycle++) {
      const { doc } = headlessState(markdown)
      expect(editorContent(doc)).toEqual(expected)
      expect(readTree(doc)).toEqual(parseMarkdown(markdown))
      markdown = printMarkdown(readTree(doc))
      if (fixture.exactExport) expect(markdown).toBe(fixture.exactExport)
    }
  })
}
