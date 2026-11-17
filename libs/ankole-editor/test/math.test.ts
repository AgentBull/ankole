import { expect, test } from 'bun:test'
import { Leaf } from '../src/core/doc'
import { GardSelection, Transaction } from '../src/core/state'
import {
  InlineMath,
  closeMathEditor,
  insertInlineMathSpec,
  mathEditorField,
  mathEditorOpenKey,
  mathSourceChange,
  openMathEditor
} from '../src/blocks/math'
import { parseMarkdown, printMarkdown } from '../src/document/markdown'
import { unwrapMathDelimiters } from '../src/document/math-delimiters'
import { normalizeTree } from '../src/document/normalize'
import { element, text } from '../src/document/tree'
import { parseXml, printXml } from '../src/document/xml'
import { commentSelection } from '../src/editor/comments'
import { readTree } from '../src/editor/convert'
import { headlessState } from '../src/editor/extension'
import { mathHTML } from '../src/editor/word-lists'

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

test('inline formulas round-trip across Markdown, XML, tables, marks, and the editor', () => {
  const source = 'before $$E=mc^2$$ and $$a < b$$ after'
  const tree = parseMarkdown(source)
  expect(printXml(tree)).toBe(
    '<page><p>before <inline-math>E=mc^2</inline-math> and <inline-math>a &lt; b</inline-math> after</p></page>'
  )
  expect(printMarkdown(tree)).toBe(source)
  expect(readTree(headlessState(source).doc)).toEqual(tree)

  // Standalone single-line $$…$$ in Markdown is a paragraph with one inline formula.
  const standalone = parseMarkdown('$$x^2 + y^2 = z^2$$')
  expect(printXml(standalone)).toBe('<page><p><inline-math>x^2 + y^2 = z^2</inline-math></p></page>')
  expect(printMarkdown(standalone)).toBe('$$x^2 + y^2 = z^2$$')

  // Single `$` currency stays literal prose.
  const currency = parseMarkdown('Prices range from $100 to $200 today.')
  expect(printXml(currency)).toBe('<page><p>Prices range from $100 to $200 today.</p></page>')

  // Empty `<inline-math />` and `<inline-math>` with extension attributes round-trip losslessly.
  const emptyAndAttributed = parseXml(
    '<page><p>Empty <inline-math /> and <a href="https://example.com"><strong><inline-math source="import">x_1</inline-math></strong></a></p></page>'
  )
  const printed = printMarkdown(emptyAndAttributed)
  expect(printed).toBe(
    'Empty <inline-math /> and **[<inline-math source="import">$$x_1$$</inline-math>](https://example.com)**'
  )
  expect(readTree(headlessState(emptyAndAttributed).doc)).toEqual(emptyAndAttributed)

  // Adjacent inline formulas and adjacent literal `$` / `$$` round-trip without merging delimiters.
  for (const trickyXml of [
    '<page><p><inline-math>a</inline-math><inline-math>b</inline-math></p></page>',
    '<page><p>$<inline-math>a</inline-math></p></page>',
    '<page><p><inline-math>a</inline-math>$</p></page>',
    '<page><p>$$<inline-math>a</inline-math></p></page>',
    '<page><p><inline-math>a</inline-math>$$</p></page>'
  ]) {
    const parsed = parseXml(trickyXml)
    expect(parseMarkdown(printMarkdown(parsed))).toEqual(parsed)
  }

  // Pipes inside inline formulas in table cells fall back to lossless HTML table markup.
  const tableWithAbs = parseXml(
    '<page><table><tr><th><p>Norm</p></th></tr><tr><td><p><inline-math>||x||_2</inline-math></p></td></tr></table></page>'
  )
  expect(parseMarkdown(printMarkdown(tableWithAbs))).toEqual(tableWithAbs)

  // Source line breaks inside `<inline-math>` normalize to single spaces.
  const multilineXml = parseXml('<page><p><inline-math>a\r\nb\rc\nd</inline-math></p></page>')
  expect(printXml(multilineXml)).toBe('<page><p><inline-math>a b c d</inline-math></p></page>')
})

test('unwrapMathDelimiters strips matching outer math delimiters without mangling inner or invalid syntax', () => {
  expect(unwrapMathDelimiters('E = mc^2')).toBe('E = mc^2')
  expect(unwrapMathDelimiters('$E = mc^2$')).toBe('E = mc^2')
  expect(unwrapMathDelimiters('  $ E = mc^2 $  ')).toBe('E = mc^2')
  expect(unwrapMathDelimiters('$$E = mc^2$$')).toBe('E = mc^2')
  expect(unwrapMathDelimiters('$$\nE = mc^2\n$$')).toBe('E = mc^2')
  expect(unwrapMathDelimiters('\\(E = mc^2\\)')).toBe('E = mc^2')
  expect(unwrapMathDelimiters('\\[E = mc^2\\]')).toBe('E = mc^2')
  expect(unwrapMathDelimiters('$ \\$100 + x $')).toBe('\\$100 + x')
  expect(unwrapMathDelimiters('$a\\\\$')).toBe('a\\\\')

  // Invalid, empty, escaped-closing, or multi-formula strings stay untouched so errors remain visible.
  expect(unwrapMathDelimiters('$')).toBe('$')
  expect(unwrapMathDelimiters('$$')).toBe('$$')
  expect(unwrapMathDelimiters('$$$')).toBe('$$$')
  expect(unwrapMathDelimiters('$$$$')).toBe('$$$$')
  expect(unwrapMathDelimiters('$   $')).toBe('$   $')
  expect(unwrapMathDelimiters('$x\\$')).toBe('$x\\$')
  expect(unwrapMathDelimiters('$a$ + $b$')).toBe('$a$ + $b$')
  expect(unwrapMathDelimiters('$$a$$ + $$b$$')).toBe('$$a$$ + $$b$$')
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

  const inlineState = headlessState(
    parseXml('<page><p><strong><inline-math source="y">x</inline-math></strong></p></page>')
  )
  const inlineChange = mathSourceChange(inlineState, 1, 'y\nz')
  expect(inlineChange).not.toBeNull()
  const inlineEdited = inlineState.update(inlineChange!).state
  expect(printXml(readTree(inlineEdited.doc))).toBe(
    '<page><p><strong><inline-math source="y">y z</inline-math></strong></p></page>'
  )
})

test('insertInlineMathSpec wraps selected text, strips outer $, supports comments, and tracks insertions at pos', () => {
  const initial = headlessState('Formula $E = mc^2$ here')
  // Select "$E = mc^2$" inside the paragraph (positions 9..19).
  const selected = initial.update({ selection: GardSelection.range(9, 19) }).state
  const spec = insertInlineMathSpec(selected)
  expect(spec).not.toBeNull()
  const inserted = selected.update(spec!).state
  expect(inserted.field(mathEditorField)).toBe(9)
  expect(inserted.doc.nodeAt(9)?.type).toBe(InlineMath)
  expect(printMarkdown(readTree(inserted.doc))).toBe('Formula $$E = mc^2$$ here')

  // Inserting text right AT position 9 keeps mathEditorField pointing to the moved InlineMath leaf.
  const shifted = inserted.update({ changes: { from: 9, to: 9, insert: [Leaf.text('famous ')] } }).state
  expect(shifted.field(mathEditorField)).toBe(16)
  expect(shifted.doc.nodeAt(16)?.type).toBe(InlineMath)

  // Selecting over an inline formula produces a non-empty comment quote.
  const forComment = shifted.update({ selection: GardSelection.range(16, 17) }).state
  expect(commentSelection({ state: forComment })).toEqual({ from: 16, to: 17, quote: 'E = mc^2' })
})

test('formula elements hold text only', () => {
  expect(() => normalizeTree(page(element('math', {}, [element('strong', {}, [text('E')])])))).toThrow(
    '<math> can contain only text'
  )
  expect(() =>
    normalizeTree(page(element('p', {}, [element('inline-math', {}, [element('strong', {}, [text('E')])])])))
  ).toThrow('<inline-math> can contain only text')
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

test('mathEditorField keeps the open position across mathSourceChange and insertions, and closes on deletion even before a neighbor formula', () => {
  const state0 = headlessState(parseMarkdown('$$a$$<inline-math>$$b$$</inline-math>'))
  // Token 0 is `<p>`, token 1 is InlineMath("a"), token 2 is InlineMath("b").
  const opened = state0.update({ effects: openMathEditor.of(1) }).state
  expect(opened.field(mathEditorField)).toBe(1)

  // Editing the formula via mathSourceChange keeps mathEditorField on token 1 without bumping openKey.
  const edited = opened.update(mathSourceChange(opened, 1, 'a + 1')!).state
  expect(edited.field(mathEditorField)).toBe(1)
  expect(edited.field(mathEditorOpenKey)).toBe(1)

  // Inserting text immediately at `pos` shifts the open inline formula right rather than losing it.
  const shifted = edited.update({ changes: { from: 1, insert: [Leaf.text('x')] } }).state
  expect(shifted.field(mathEditorField)).toBe(2)

  // Deleting the edited formula closes the editor rather than jumping onto the adjacent formula `b`.
  const deleted = shifted.update({ changes: { from: 2, to: 3 } }).state
  expect(deleted.field(mathEditorField)).toBeNull()
})

test('untouched formulas stay unchanged on close, while edited formulas unwrap delimiters on close or formula switch', () => {
  const initialTree = parseXml(
    '<page><p><inline-math source="ref">$x^2$</inline-math><inline-math>b</inline-math></p></page>'
  )
  const state0 = headlessState(initialTree)
  const opened = state0.update({ effects: openMathEditor.of(1) }).state

  // Closing an untouched formula does not strip its original source or mutate the document.
  const untouchedClosed = Transaction.append(opened.update({ effects: closeMathEditor.of(null) })).at(-1)!.state
  expect(untouchedClosed.doc).toBe(state0.doc)

  // Editing formula 1 to `$a + 1$` and switching directly to formula 2 normalizes formula 1 while keeping `source="ref"`.
  const edited = Transaction.append(opened.update(mathSourceChange(opened, 1, '$a + 1$')!)).at(-1)!.state
  const switched = Transaction.append(edited.update({ effects: openMathEditor.of(2) })).at(-1)!.state
  expect(switched.field(mathEditorField)).toBe(2)
  expect(printXml(readTree(switched.doc))).toBe(
    '<page><p><inline-math source="ref">a + 1</inline-math><inline-math>b</inline-math></p></page>'
  )
})

test('insertInlineMathSpec works in empty list items and preserves attributes on single-node text selections', () => {
  // Empty list item (`<ul><li /></ul>`): token 0 is `<ul>`, token 1 is `<li>`, cursor at `li.start` (2).
  const listState = headlessState(parseMarkdown('-')).update({ selection: GardSelection.cursor(2) }).state
  const insertedInList = listState.update(insertInlineMathSpec(listState)!).state
  expect(printXml(readTree(insertedInList.doc))).toBe('<page><ul><li><p><inline-math /></p></li></ul></page>')
  expect(insertedInList.field(mathEditorField)).toBe(3)

  // Single-node text selection `[1, 2]` (e.g. Shift+ArrowRight over `.math-inline`) opens MathEditor without dropping `Attrs`.
  const attrTree = parseXml('<page><p><inline-math id="eq1">x</inline-math></p></page>')
  const textSelected = headlessState(attrTree).update({ selection: GardSelection.range(1, 2) }).state
  const reopened = textSelected.update(insertInlineMathSpec(textSelected)!).state
  expect(reopened.doc).toBe(textSelected.doc)
  expect(reopened.field(mathEditorField)).toBe(1)
})

test('mathHTML safely returns input unchanged when DOMParser is unavailable in headless runtimes', () => {
  const html = '<p><span class="katex"><annotation encoding="application/x-tex">E = mc^2</annotation></span></p>'
  expect(mathHTML(html)).toBe(html)
})
