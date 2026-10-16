import { expect, test } from 'bun:test'
import fc from 'fast-check'
import { Leaf, type Mark, type Node, type Plot } from '../src/core/doc'
import * as T from '../src/core/types'
import { normalizeTree } from '../src/document/normalize'
import { element as e, text as t, textOf, type Element } from '../src/document/tree'
import { markSet } from '../src/editor/attributes'
import { replaceTree } from '../src/editor/convert'
import * as S from '../src/editor/schema'
import { block, page } from './arbitrary'
import { expectReopens, exportMarkdown, open, readTree } from './helpers'

const seed = process.env.FC_SEED ? Number(process.env.FC_SEED) : 20261005
const text = fc
  .array(fc.constantFrom('a', '中', '🙂', '👩‍💻', 'é', 'ع', ' ', '*', '_', '`', '[', ']', ':', '&', '<', '"', '\\'), {
    maxLength: 25
  })
  .map(chars => `A${chars.join('')}Z`)

// Format bits of the generated runs.
const bits: [number, Mark][] = [
  [1, S.formats.strong],
  [2, S.formats.em],
  [4, S.formats.s],
  [8, S.formats.u],
  [16, S.formats.code]
]
const formatOf = (node: Node) => bits.reduce((sum, [bit, mark]) => sum | (mark.isInSet(node.marks) ? bit : 0), 0)

function characters(node: Node): { text: string; format: number }[] {
  if (node.isText) return Array.from(node.param as string, text => ({ text, format: formatOf(node) }))
  return node.isPlot ? node.content.flatMap(characters) : []
}

// Bold and italic white space looks like plain white space and may lose those formats.
const visible = (runs: { text: string; format: number }[]) =>
  runs.map(run => ({ text: run.text, format: /\s/u.test(run.text) ? run.format & ~3 : run.format }))

function assertInline(runs: { text: string; format: number }[]) {
  const editor = open('')
  const leaves = runs.map(run =>
    Leaf.text(run.text, markSet(bits.map(([bit, mark]) => (run.format & bit ? mark : null))))
  )
  editor.dispatch({ changes: { from: 0, to: editor.state.doc.length, insert: [T.Paragraph.create(leaves)] } })
  const expected = visible(characters(editor.state.doc))
  const reopened = open(exportMarkdown(editor))
  expect(visible(characters(reopened.state.doc))).toEqual(expected)
  expectReopens(editor)
}

test.each([
  [[{ text: 'A:中Z', format: 0 }]],
  [[{ text: 'A*:Z', format: 0 }]],
  [
    [
      { text: '\\', format: 4 },
      { text: 'a', format: 0 }
    ]
  ],
  [
    [
      { text: 'AZ', format: 13 },
      { text: 'AZ', format: 1 }
    ]
  ],
  [
    [
      { text: 'A[Z', format: 24 },
      { text: 'AZ', format: 0 }
    ]
  ],
  [
    [
      { text: 'A\\Z', format: 0 },
      { text: 'AZ', format: 17 }
    ]
  ],
  [
    [
      { text: 'A\\`Z', format: 0 },
      { text: 'AZ', format: 0 }
    ]
  ],
  [[{ text: '   ', format: 24 }]],
  [[{ text: ' leading and trailing ', format: 24 }]],
  [
    [
      { text: 'bold ', format: 1 },
      { text: 'after', format: 0 }
    ]
  ]
])('keeps the characters and formats of minimized cases %#', runs => {
  assertInline(runs)
})

test('generated text and overlapping formats keep each visible character', () => {
  fc.assert(
    fc.property(
      fc.array(fc.record({ text, format: fc.integer({ min: 0, max: 31 }) }), { minLength: 1, maxLength: 6 }),
      assertInline
    ),
    { seed, numRuns: 200 }
  )
}, 60_000)

// The text of the leaves in an editor document: text, and the text that read-only elements and line
// breaks give. The `---` that a rule gives as plain text is not page text.
function leafText(doc: Plot.Doc) {
  let value = ''
  doc.iterate(node => {
    if (node.isLeaf && node.type !== T.HorizontalRule.type) {
      value += node.isText ? node.param : (node.type.spec.toText?.(node) ?? '')
    }
  })
  return value
}

/** A page opens, and is written into an editor, as exactly its normal form, with every character. */
function assertPage(tree: Element) {
  const expected = normalizeTree(tree)
  const editor = open(expected)
  expect(readTree(editor)).toEqual(expected)
  // A page write runs the editor's corrections over the whole page. They must find nothing to change.
  const written = open('')
  written.dispatch(replaceTree(written.state, expected))
  expect(readTree(written)).toEqual(expected)
  // Every character of the page is in the editor, as editable text or inside a read-only element.
  expect(leafText(editor.state.doc).replace(/\s/g, '')).toBe(textOf(expected).replace(/\s/g, ''))
}

test('generated pages keep their content and text through the editor', () => {
  fc.assert(fc.property(page, assertPage), { seed, numRuns: 200 })
}, 60_000)

/*
 * Tables in any shape, which the generated pages above do not hold: rows of different lengths, no
 * rows, rows or cells without content, cells with several blocks, header cells in any row, spans
 * up to 9999 columns and attributes outside the vocabulary. Also code with CR line ends and
 * attribute names that `Object.prototype` has.
 */
const extra = fc
  .array(
    fc.tuple(
      fc.constantFrom('data-x', 'constructor', '__proto__', 'toString', '字段'),
      fc.constantFrom('', '1', 'x y', '中')
    ),
    { maxLength: 2 }
  )
  .map(pairs => Object.fromEntries(pairs) as Record<string, string>)
const cell = fc
  .record({
    name: fc.constantFrom('th', 'td'),
    align: fc.constantFrom(undefined, 'left', 'center', 'right', 'justify'),
    colspan: fc.constantFrom(undefined, '1', '2', '9999'),
    rowspan: fc.constantFrom(undefined, '1', '3', '9999'),
    extra,
    content: fc.oneof(fc.constant<Element[]>([]), fc.array(block(1), { minLength: 1, maxLength: 3 }))
  })
  .map(({ name, align, colspan, rowspan, extra, content }) =>
    e(
      name,
      { ...extra, ...(align ? { align } : {}), ...(colspan ? { colspan } : {}), ...(rowspan ? { rowspan } : {}) },
      content
    )
  )
const row = fc.tuple(extra, fc.array(cell, { maxLength: 4 })).map(([attrs, cells]) => e('tr', attrs, cells))
const table = fc.tuple(extra, fc.array(row, { maxLength: 4 })).map(([attrs, rows]) => e('table', attrs, rows))
const code = fc
  .tuple(fc.array(fc.constantFrom('a', '中', '\n', '\r\n', '\r', '\t', ' ', '<', '&'), { maxLength: 10 }), extra)
  .map(([parts, attrs]) => e('pre', attrs, parts.length ? [t(parts.join(''))] : []))
const irregularPage = fc
  .array(fc.oneof(table, table, code, block(1)), { maxLength: 4 })
  .map(blocks => e('page', {}, blocks))

test('generated tables of any shape keep their content and text through the editor', () => {
  fc.assert(fc.property(irregularPage, assertPage), { seed, numRuns: 200 })
}, 60_000)
