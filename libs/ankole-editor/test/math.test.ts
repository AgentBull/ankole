import { expect, test } from 'bun:test'
import { readTree } from '../src/editor/convert'
import { headlessState } from '../src/editor/extension'
import { parseMarkdown, printMarkdown } from '../src/document/markdown'
import { normalizeTree } from '../src/document/normalize'
import { parseXml, printXml } from '../src/document/xml'
import { element, text } from '../src/document/tree'
import { Leaf } from '../src/core/doc'
import {
  closeMathEditor,
  mathEditorField,
  mathEditorOpenKey,
  mathSourceChange,
  openMathEditor
} from '../src/blocks/math'

const page = (...children: ReturnType<typeof element>[]) => element('page', {}, children)

test('a formula block round-trips between Markdown, XML, and the editor', () => {
  const source = '$$\n\\frac{a}{b} = c^2\n$$'
  const tree = parseMarkdown(source)
  expect(tree).toEqual(page(element('math', {}, [text('\\frac{a}{b} = c^2')])))
  expect(printMarkdown(tree)).toBe(source)
  expect(printXml(tree)).toBe('<page><math>\\frac{a}{b} = c^2</math></page>')
  expect(printMarkdown(parseXml(printXml(tree)))).toBe(source)

  const editor = readTree(headlessState(source).doc)
  expect(editor).toEqual(tree)
})

test('an empty formula block stays empty', () => {
  const source = '$$\n$$'
  const tree = parseMarkdown(source)
  expect(tree).toEqual(page(element('math', {})))
  expect(printMarkdown(tree)).toBe(source)
})

test('a single-line formula stays a formula block when written as a tag', () => {
  const tree = parseMarkdown('<math>E=mc^2</math>')
  expect(tree).toEqual(page(element('math', {}, [text('E=mc^2')])))
  expect(printMarkdown(tree)).toBe('$$\nE=mc^2\n$$')
})

test('an inline formula asks the writer to put it on its own line', () => {
  expect(() => parseMarkdown('before $$E=mc^2$$ after')).toThrow('行内公式暂不支持')
})

test('unknown attributes on a formula block survive the editor', () => {
  const tree = parseMarkdown('<math source="x">E=mc^2</math>')
  expect(printXml(readTree(headlessState(tree).doc))).toBe('<page><math source="x">E=mc^2</math></page>')
})

test('editing a formula keeps its extension attributes', () => {
  const state = headlessState(parseXml('<page><math source="x">E=mc^2</math></page>'))
  const change = mathSourceChange(state, 0, 'a=b')
  expect(change).not.toBeNull()
  const edited = state.update(change!).state
  expect(printXml(readTree(edited.doc))).toBe('<page><math source="x">a=b</math></page>')
  expect(printMarkdown(parseXml(printXml(readTree(edited.doc))))).toBe('<math source="x">\n  $$\n  a=b\n  $$\n</math>')
})

test('a formula block holds text only', () => {
  expect(() => normalizeTree(page(element('math', {}, [element('strong', {}, [text('E')])])))).toThrow(
    '<math> 只能包含文字'
  )
})

test('a wrapped code block keeps the wrap attribute', () => {
  const tree = parseMarkdown('<pre lang="js" wrap="true">const x = 1</pre>')
  expect(printXml(tree)).toBe('<page><pre lang="js" wrap="true">const x = 1</pre></page>')
  expect(readTree(headlessState(tree).doc)).toEqual(tree)
})

test('mathEditorOpenKey increments only when opening or switching formulas, not on position mapping', () => {
  const state0 = headlessState(parseMarkdown('Before\n\n$$\na=b\n$$\n\n$$\nc=d\n$$'))
  expect(state0.field(mathEditorField)).toBeNull()
  expect(state0.field(mathEditorOpenKey)).toBe(0)

  const state1 = state0.update({ effects: openMathEditor.of(8) }).state
  expect(state1.field(mathEditorField)).toBe(8)
  expect(state1.field(mathEditorOpenKey)).toBe(1)

  const mapped = state1.update({ changes: { from: 1, insert: [Leaf.text('Prefix ')] } }).state
  expect(mapped.field(mathEditorField)).toBe(15)
  expect(mapped.field(mathEditorOpenKey)).toBe(1)

  const switched = mapped.update({ effects: openMathEditor.of(16) }).state
  expect(switched.field(mathEditorField)).toBe(16)
  expect(switched.field(mathEditorOpenKey)).toBe(2)

  const closed = switched.update({ effects: closeMathEditor.of(null) }).state
  expect(closed.field(mathEditorField)).toBeNull()
  expect(closed.field(mathEditorOpenKey)).toBe(0)
})
