import { expect, test } from 'bun:test'
import { HtmlRenderer, Parser } from 'commonmark'
import { parseMarkdown, printMarkdown } from '../../src/document/markdown'
import { parseXml } from '../../src/document/xml'
import { readTree } from '../../src/editor/convert'
import { headlessState } from '../../src/editor/extension'
import examples from '../fixtures/commonmark-0.31.2.json'
import dialect from '../fixtures/commonmark-dialect.json'
import { commonmarkContent, editorContent, elementContent } from '../semantic'

const reference = new Parser()
const renderer = new HtmlRenderer()
const differences = dialect.examples as Record<string, { reason: string; xml?: string; error?: string }>

for (const example of examples) {
  test(`commonmark:${example.example} ${example.section}`, () => {
    const parsed = reference.parse(example.markdown)
    expect(renderer.render(parsed)).toBe(example.html)
    const difference = differences[example.example]
    expect(difference === undefined || difference.reason in dialect.reasons).toBe(true)
    if (difference?.error) {
      expect(() => parseMarkdown(example.markdown)).toThrow(difference.error)
      return
    }
    const document = parseMarkdown(example.markdown)
    let expected = commonmarkContent(parsed)
    if (difference?.xml) {
      // A recorded difference is exact, and it must still differ from CommonMark.
      expect(document).toEqual(parseXml(difference.xml))
      expect(elementContent(document)[0]).not.toEqual(expected)
      expected = elementContent(document)[0]!
    }
    let markdown = example.markdown
    for (let cycle = 0; cycle < 2; cycle++) {
      const { doc } = headlessState(markdown)
      expect(readTree(doc)).toEqual(document)
      expect(editorContent(doc)).toEqual(expected)
      markdown = printMarkdown(readTree(doc))
    }
  })
}
