import { expect, test } from 'bun:test'
import { insertText } from '../src/core/command/commands'
import { parse as parseDOM, serialize, type Leaf } from '../src/core/doc'
import type { Wordgard } from '../src/core/editor'
import { eventHandler } from '../src/core/editor/input'
import { undo } from '../src/core/history'
import { GardSelection, GardState, Transaction } from '../src/core/state'
import { printMarkdown } from '../src/document/markdown'
import { parseXml, printXml } from '../src/document/xml'
import { readTree } from '../src/editor/convert'
import { headlessState } from '../src/editor/extension'
import { addressLink, linkAt, removeLink, setLink } from '../src/editor/links'
import { fenceShortcut } from '../src/editor/markdown-shortcuts'
import { Link, safeLinkHref, schema } from '../src/editor/schema'
import { open, openWithHost } from './helpers'

const markdown = (state: GardState) => printMarkdown(readTree(state.doc))
const xml = (state: GardState) => printXml(readTree(state.doc))

function position(state: GardState, text: string, offset: number | 'end' = 0) {
  let found = -1
  state.doc.iterate((node, pos) => {
    if (found < 0 && node.isText && (node as Leaf<string>).param === text) {
      found = pos + (offset === 'end' ? text.length : offset)
    }
  })
  if (found < 0) throw new Error(`No text ${text}`)
  return found
}

const at = (source: string, pos: number) => headlessState(source).update({ selection: GardSelection.cursor(pos) }).state

/** Type `text` one character at a time, as the editor does: each key is a transaction, then the appenders run. */
function type(state: GardState, text: string) {
  for (const char of text) {
    const { from, to } = state.selection
    const spec = insertText({ state }, { from, to, insert: char, userEvent: 'input.type' })
    if (!spec) throw new Error('Typing failed')
    state = Transaction.append(state.update(spec)).at(-1)!.state
  }
  return state
}

const undone = (state: GardState) => state.update(undo({ state }, null) as Transaction.Spec).state

// An empty paragraph between "s" and "e": the caret is at 4.
const empty = () => at('s\n\n<p />\n\ne', 4)

test.each([
  ['[] ', 's\n\n<ul>\n  <li task="todo" />\n</ul>\n\ne'],
  ['[x] ', 's\n\n<ul>\n  <li task="done" />\n</ul>\n\ne'],
  ['---', 's\n\n---\n\n<p />\n\ne'],
  ['---abc', 's\n\n---\n\nabc\n\ne'],
  ['" q', 's\n\n> q\n\ne'],
  ['| q', 's\n\n> q\n\ne'],
  ['> q', 's\n\n> q\n\ne'],
  ['# q', 's\n\n# q\n\ne'],
  ['### q', 's\n\n### q\n\ne'],
  ['- q', 's\n\n- q\n\ne'],
  ['* q', 's\n\n- q\n\ne'],
  ['1. q', 's\n\n1. q\n\ne'],
  ['3) q', 's\n\n3. q\n\ne'],
  ['- [ ] q', 's\n\n- [ ] q\n\ne'],
  ['- [x] q', 's\n\n- [x] q\n\ne'],
  ['#q ', 's\n\n\\#q&#x20;\n\ne'],
  ['a[] ', 's\n\na\\[]&#x20;\n\ne']
])('typing %p in an empty paragraph', (typed, expected) => {
  expect(markdown(type(empty(), typed))).toBe(expected)
})

test('a checkbox typed in a bullet item makes it a to-do item', () => {
  expect(markdown(type(empty(), '- [ ] '))).toBe('s\n\n<ul>\n  <li task="todo" />\n</ul>\n\ne')
  expect(markdown(type(at('- a\n- b', 8), '[x] '))).toBe('- a\n- [x] b')
  expect(markdown(type(at('1. b', 3), '[ ] '))).toBe('1. \\[ ] b')
})

test('undo right after a conversion gives back the typed characters', () => {
  expect(markdown(undone(type(empty(), '[] ')))).toBe('s\n\n\\[]&#x20;\n\ne')
  expect(markdown(undone(type(empty(), '## ')))).toBe('s\n\n\\##&#x20;\n\ne')
})

test('typing the table shortcut creates editable header cells and undo restores the marker', () => {
  const state = type(empty(), '|--')
  const tree = readTree(state.doc)
  const table = tree.children.find(node => node.type === 'element' && node.name === 'table')
  expect(table?.type === 'element' && table.children.length).toBe(3)
  expect(xml(type(state, 'Name'))).toContain('<th><p>Name</p></th>')
  expect(xml(undone(state))).toBe('<page><p>s</p><p>|--</p><p>e</p></page>')
})

test('a block marker typed before existing text converts the paragraph and keeps the caret', () => {
  const state = at('hello', 1)
  const result = type(state, '## ')
  expect(markdown(result)).toBe('## hello')
  expect(type(result, 'x').doc.textContent()).toBe('xhello')
})

test('block markers do not convert in headings, list items and code', () => {
  expect(markdown(type(at('# h', 1), '- '))).toBe('# - h')
  expect(markdown(type(at('- a', 3), '> '))).toBe('- \\> a')
  expect(markdown(type(at('```\n\n```', 1), '# '))).toBe('```\n# \n```')
})

test.each([
  ['**bold**', '**bold**', 'strong'],
  ['__bold__', '**bold**', 'strong'],
  ['*em*', '*em*', 'em'],
  ['_em_', '*em*', 'em'],
  ['~~gone~~', '~~gone~~', 's'],
  ['~gone~', '~~gone~~', 's'],
  ['`code`', '`code`', 'code'],
  ['[text](https://example.com)', '[text](https://example.com)', 'a'],
  ['[text](https://example.com "Title")', '[text](https://example.com "Title")', 'a']
])('typing %p formats it', (typed, expected) => {
  expect(markdown(type(at('<p />', 1), `a ${typed}`))).toBe(`a ${expected}`)
})

test('text typed after a format does not take the format', () => {
  expect(markdown(type(at('<p />', 1), '**bold**x'))).toBe('**bold**x')
  expect(markdown(type(at('<p />', 1), '**bold** x'))).toBe('**bold** x')
})

test('an inline format waits for the longer marker, and stays text in code', () => {
  expect(markdown(type(at('<p />', 1), '**bold*'))).toBe('\\*\\*bold\\*')
  expect(markdown(type(at('`code`', 3), '**b**'))).toBe('`co**b**de`')
  expect(markdown(type(at('```\n\n```', 1), '**b**'))).toBe('```\n**b**\n```')
  expect(markdown(type(at('<p />', 1), '2 * 3 * 4'))).toBe('2 \\* 3 \\* 4')
})

test('a code fence converts on Enter', () => {
  const state = type(at('<p />', 1), '```js title=x')
  const result = state.update(fenceShortcut(state)!).state
  expect(markdown(result)).toBe('```js title=x\n```')
  expect(result.doc.resolve(result.selection.head).parent.node.name).toBe('CodeBlock')
  expect(fenceShortcut(type(at('<p />', 1), 'a ```'))).toBeNull()
  expect(fenceShortcut(type(at('- a', 3), '```'))).toBeNull()
})

test('a typed address becomes a link after a space', () => {
  expect(xml(type(at('<p />', 1), 'see www.example.com '))).toBe(
    '<page><p>see <a href="http://www.example.com">www.example.com</a> </p></page>'
  )
  const link = type(at('<p />', 1), 'see https://example.com/a?b=1 ')
  expect(linkAt(link.update({ selection: GardSelection.cursor(8) }).state)?.href).toBe('https://example.com/a?b=1')
  expect(xml(type(at('<p />', 1), 'see https://example.com. '))).toBe('<page><p>see https://example.com. </p></page>')
  expect(xml(type(at('<p />', 1), 'xwww.example.com '))).toBe('<page><p>xwww.example.com </p></page>')
  expect(xml(type(at('```\n\n```', 1), 'www.example.com '))).toBe('<page><pre>www.example.com </pre></page>')
  expect(xml(type(at('`x`', 2), 'www.example.com '))).toBe('<page><p><code>xwww.example.com </code></p></page>')
})

test('a typed address becomes a link on Enter', () => {
  const state = type(at('<p />', 1), 'go www.example.com')
  const result = state.update(addressLink(state, state.selection.head)!).state
  expect(xml(result)).toBe('<page><p>go <a href="http://www.example.com">www.example.com</a></p></page>')
})

test('imported text does not become a link', () => {
  expect(markdown(headlessState('Visit www\\.example.com'))).toBe('Visit www\\.example.com')
})

test('the link form reads, changes and removes links', () => {
  const state = headlessState('a [link](https://a.example "T") b')
  const inLink = state.update({ selection: GardSelection.cursor(position(state, 'link', 2)) }).state
  expect(linkAt(inLink)).toEqual({ href: 'https://a.example', title: 'T', from: 3, to: 7 })
  const changed = inLink.update(setLink({ state: inLink }, { href: 'https://b.example' }) as Transaction.Spec).state
  expect(markdown(changed)).toBe('a [link](https://b.example "T") b')
  const untitled = inLink.update(setLink({ state: inLink }, { href: '/x', title: '' }) as Transaction.Spec).state
  expect(markdown(untitled)).toBe('a [link](/x) b')
  const removed = inLink.update(removeLink({ state: inLink }, null) as Transaction.Spec).state
  expect(markdown(removed)).toBe('a link b')
  const plain = state.update({ selection: GardSelection.range(1, 2) }).state
  expect(linkAt(plain)).toBeNull()
  expect(setLink({ state: plain.update({ selection: GardSelection.cursor(1) }).state }, { href: '/x' })).toBe(false)
  const linked = plain.update(
    setLink({ state: plain }, { href: 'https://c.example', title: 'C' }) as Transaction.Spec
  ).state
  expect(markdown(linked)).toBe('[a](https://c.example "C") [link](https://a.example "T") b')
  expect(setLink({ state: plain }, { href: 'javascript:alert(1)' })).toBe(false)
  expect(setLink({ state: plain }, { href: 'data:text/html,<script>alert(1)</script>' })).toBe(false)
})

function mockLinkContainer(href: string, label: string, title?: string): Element {
  const textNode = {
    nodeType: 3,
    nodeValue: label,
    firstChild: null,
    nextSibling: null
  }
  const attrs = new Map<string, string>([['href', href]])
  if (title !== undefined) attrs.set('title', title)
  const anchor = {
    nodeType: 1,
    nodeName: 'A',
    firstChild: textNode,
    nextSibling: null,
    attributes: [...attrs.entries()].map(([name, value]) => ({ name, value })),
    getAttribute: (name: string) => attrs.get(name) ?? null,
    hasAttribute: (name: string) => attrs.has(name),
    matches: (selector: string) => selector === 'a' || (selector === 'a[href]' && attrs.has('href')),
    style: {}
  }
  const paragraph = {
    nodeType: 1,
    nodeName: 'P',
    firstChild: anchor,
    nextSibling: null,
    attributes: [],
    getAttribute: () => null,
    hasAttribute: () => false,
    matches: (selector: string) => selector === 'p',
    style: {}
  }
  return {
    nodeType: 1,
    nodeName: 'DIV',
    firstChild: paragraph,
    nextSibling: null,
    attributes: [],
    getAttribute: () => null,
    hasAttribute: () => false,
    matches: () => false,
    style: {}
  } as unknown as Element
}

function dispatchAnchorClick(
  editor: Wordgard,
  href: string,
  options: { metaKey?: boolean; ctrlKey?: boolean } = {}
): boolean {
  let prevented = false
  const anchor = {
    getAttribute: (name: string) => (name === 'href' ? href : null),
    closest(selector: string) {
      return selector === 'a[href]' ? anchor : null
    }
  }
  const event = {
    button: 0,
    metaKey: options.metaKey ?? false,
    ctrlKey: options.ctrlKey ?? false,
    target: anchor,
    get defaultPrevented() {
      return prevented
    },
    preventDefault() {
      prevented = true
    }
  } as unknown as Event
  for (const handler of editor.state.facet(eventHandler)['click'] ?? []) {
    if (handler(event, editor)) break
  }
  return prevented
}

test('link protocol allowlist protects toDOM, parseDOM, Markdown shortcuts, and activation clicks', () => {
  for (const unsafe of [
    'javascript:alert(1)',
    '  \t\nJaVaScRiPt:alert(1)',
    'java\tscript:alert(1)',
    'vbscript:msgbox(1)',
    'data:text/html,<script>alert(1)</script>',
    'file:///etc/passwd',
    'blob:https://example.com/123'
  ]) {
    expect(safeLinkHref(unsafe)).toBeNull()

    // Stored unsafe links never emit an executable href in DOM serialization.
    const stored = headlessState(
      parseXml(`<page><p><a href="${unsafe.replace(/[<>&"]/g, '')}" title="Note">bad</a></p></page>`)
    )
    const html = serialize(stored.doc).toHTML()
    expect(html).toBe('<p><a rel="noopener noreferrer" title="Note">bad</a></p>')
    expect(html).not.toContain('href=')

    // Pasted HTML with disallowed href rejects the Link mark while preserving text.
    const parsed = parseDOM(schema, mockLinkContainer(unsafe, 'pasted', 'Title'))
    expect(parsed.content[0]!.isPlot && parsed.content[0]!.content[0]?.marks.some(mark => mark.type === Link)).toBe(
      false
    )
    expect(printXml(readTree(parsed))).toBe('<page><p>pasted</p></page>')
  }

  for (const allowed of [
    'https://example.com/path',
    '  http://example.com  ',
    'mailto:alice@example.com',
    'tel:+1234567',
    'ankole:page/019a2b00-0000-7000-8000-000000000001',
    'ankole:asset/hash/report.pdf',
    '/docs/intro',
    '#overview'
  ]) {
    const trimmed = allowed.trim()
    expect(safeLinkHref(allowed)).toBe(trimmed)
    const parsed = parseDOM(schema, mockLinkContainer(allowed, 'ok', 'Safe'))
    expect(printXml(readTree(parsed))).toBe(`<page><p><a href="${trimmed}" title="Safe">ok</a></p></page>`)
  }

  // Markdown inline shortcuts reject javascript: and data: URLs.
  expect(xml(type(at('<p />', 1), '[click](javascript:alert(1))'))).toBe(
    '<page><p>[click](javascript:alert(1))</p></page>'
  )
  expect(xml(type(at('<p />', 1), '[click](data:text/html,hi)'))).toBe('<page><p>[click](data:text/html,hi)</p></page>')
  expect(xml(type(at('<p />', 1), '[click](https://example.com)'))).toBe(
    '<page><p><a href="https://example.com">click</a></p></page>'
  )

  // Activation clicks (readOnly and Mod+Click) always call preventDefault() even on unhandled/unsafe hrefs.
  for (const href of ['javascript:alert(1)', 'data:text/html,hi', 'https://example.com', 'ankole:page/target']) {
    const editable = open('text')
    expect(dispatchAnchorClick(editable, href)).toBe(false)
    expect(dispatchAnchorClick(editable, href, { metaKey: true })).toBe(true)
    expect(dispatchAnchorClick(editable, href, { ctrlKey: true })).toBe(true)

    const readOnlyEditor = open('text')
    readOnlyEditor.dispatch({ effects: GardState.appendConfig.of(GardState.readOnly.of(true)) })
    expect(dispatchAnchorClick(readOnlyEditor, href)).toBe(true)

    const hostedWithoutOpenPage = openWithHost('text', {})
    expect(dispatchAnchorClick(hostedWithoutOpenPage, href, { metaKey: true })).toBe(true)
    const hostedReadOnly = openWithHost('text', {})
    hostedReadOnly.dispatch({ effects: GardState.appendConfig.of(GardState.readOnly.of(true)) })
    expect(dispatchAnchorClick(hostedReadOnly, href)).toBe(true)
  }
})
