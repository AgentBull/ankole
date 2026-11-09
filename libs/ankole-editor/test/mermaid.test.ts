import { expect, test } from 'bun:test'
import { readTree } from '../src/editor/convert'
import { headlessState } from '../src/editor/extension'
import { parseMarkdown, printMarkdown } from '../src/document/markdown'
import { normalizeTree } from '../src/document/normalize'
import { parseXml, printXml } from '../src/document/xml'
import { element, text } from '../src/document/tree'
import { Leaf } from '../src/core/doc'
import { GardSelection } from '../src/core/state'
import * as T from '../src/core/types'
import { markSet } from '../src/editor/attributes'
import { BlockSelection } from '../src/editor/block-selection'
import {
  applyMermaidTemplate,
  mermaidTemplates,
  MermaidTheme,
  MermaidView,
  setMermaidView
} from '../src/blocks/mermaid'
import { open } from './helpers'

const page = (...children: ReturnType<typeof element>[]) => element('page', {}, children)
const source = 'flowchart TD\n  A[开始] --> B{是否继续?}'
const fence = (value: string) => `\`\`\`mermaid\n${value}\n\`\`\``

test('a Mermaid fence becomes a Mermaid block and round-trips', () => {
  const tree = parseMarkdown(fence(source))
  expect(tree).toEqual(page(element('mermaid', {}, [text(source)])))
  expect(printMarkdown(tree)).toBe(fence(source))
  expect(printXml(tree)).toBe('<page><mermaid>flowchart TD\n  A[开始] --&gt; B{是否继续?}</mermaid></page>')
  expect(printMarkdown(parseXml(printXml(tree)))).toBe(fence(source))
  expect(readTree(headlessState(tree).doc)).toEqual(tree)
})

test('a Mermaid block carries view and theme through the editor and Markdown tags', () => {
  const tree = parseMarkdown('<mermaid view="code" theme="dark">\n```mermaid\nflowchart LR\n  X --> Y\n```\n</mermaid>')
  expect(tree).toEqual(page(element('mermaid', { theme: 'dark', view: 'code' }, [text('flowchart LR\n  X --> Y')])))
  expect(printXml(tree)).toBe('<page><mermaid theme="dark" view="code">flowchart LR\n  X --&gt; Y</mermaid></page>')
  const editor = headlessState(tree)
  const node = editor.doc.content[0]!
  expect(node.mark(MermaidView)).toBe('code')
  expect(node.mark(MermaidTheme)).toBe('dark')
  expect(readTree(editor.doc)).toEqual(tree)
})

test('default view and theme are omitted from canonical pages', () => {
  const tree = normalizeTree(page(element('mermaid', { view: 'both', theme: 'auto' }, [text(source)])))
  expect(tree).toEqual(page(element('mermaid', {}, [text(source)])))
})

test('an empty Mermaid block stays empty', () => {
  const tree = parseMarkdown('```mermaid\n```')
  expect(tree).toEqual(page(element('mermaid', {})))
  expect(printMarkdown(tree)).toBe('```mermaid\n```')
  expect(readTree(headlessState(tree).doc)).toEqual(tree)
})

test('Mermaid content loses inline marks added by formatting and paste', () => {
  const state = headlessState(parseXml('<page><mermaid>flowchart LR</mermaid></page>'))
  const marked = state.update({ changes: { from: 1, to: 5, add: T.Strong } }).state
  expect(printXml(readTree(marked.doc))).toBe('<page><mermaid>flowchart LR</mermaid></page>')
  const marks = markSet([T.Strong, T.Emphasis])
  const inserted = state.update({
    changes: { from: 1, to: 13, insert: [Leaf.text('flowchart LR', marks)] }
  }).state
  expect(printXml(readTree(inserted.doc))).toBe('<page><mermaid>flowchart LR</mermaid></page>')
})

test('a Mermaid block holds text only', () => {
  expect(() => normalizeTree(page(element('mermaid', {}, [element('strong', {}, [text('x')])])))).toThrow(
    '<mermaid> 只能包含文字'
  )
})

test('carriage returns inside Mermaid XML survive editor round-trips', () => {
  const xml = '<page><mermaid>flowchart LR&#13;\n  A --&gt; B</mermaid></page>'
  const state = headlessState(parseXml(xml))
  expect(printXml(readTree(state.doc))).toBe(xml)
})

test('applying a Mermaid template focuses the block and switching to or from diagram-only view keeps selection valid', () => {
  const editor = open('Intro\n\n```mermaid\n```')
  editor.dispatch({ selection: GardSelection.cursor(1) })
  const mermaidPos = editor.state.doc.content[0]!.length
  const template = mermaidTemplates[0]!.source
  applyMermaidTemplate(editor, mermaidPos, template)

  const afterTemplate = editor.state.doc.resolvePlot(mermaidPos)!
  expect(afterTemplate.node.textContent()).toBe(template)
  expect(editor.state.selection).toBeInstanceOf(GardSelection.Text)
  expect(editor.state.selection.head).toBe(afterTemplate.end)

  // Caret inside the Mermaid block switches to whole-block selection when entering diagram-only view.
  setMermaidView(editor, mermaidPos, 'diagram')
  expect(editor.state.selection).toBeInstanceOf(BlockSelection)
  expect((editor.state.selection as BlockSelection).blocks.map(unit => unit.before)).toEqual([mermaidPos])

  // Applying another template while in diagram-only view keeps the whole-block selection on the diagram.
  applyMermaidTemplate(editor, mermaidPos, mermaidTemplates[2]!.source)
  expect(editor.state.selection).toBeInstanceOf(BlockSelection)
  expect((editor.state.selection as BlockSelection).blocks.map(unit => unit.before)).toEqual([mermaidPos])

  // Switching back to source view moves the caret into the source pane.
  setMermaidView(editor, mermaidPos, 'both')
  const restored = editor.state.doc.resolvePlot(mermaidPos)!
  expect(editor.state.selection).toBeInstanceOf(GardSelection.Text)
  expect(editor.state.selection.head).toBe(restored.end)

  // Toggling view when selection is in another block leaves that selection untouched.
  editor.dispatch({ selection: GardSelection.cursor(2) })
  setMermaidView(editor, mermaidPos, 'diagram')
  expect(editor.state.selection).toBeInstanceOf(GardSelection.Text)
  expect(editor.state.selection.head).toBe(2)

  // Initial state on a page ending in a diagram-only Mermaid block stays outside the hidden source pane.
  const initialDiagram = headlessState('<mermaid view="diagram">\n```mermaid\nflowchart LR\n```\n</mermaid>')
  expect(initialDiagram.selection).toBeInstanceOf(GardSelection.Text)
  expect(initialDiagram.selection.head).toBe(initialDiagram.doc.length)
})
