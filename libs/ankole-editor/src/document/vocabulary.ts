import type { Element } from './tree'

/** What an element may contain: block elements, inline content, plain text, nothing, or named children. */
export type Content = 'blocks' | 'inline' | 'text' | 'empty' | readonly string[]

export type ElementRule = {
  kind: 'block' | 'inline'
  content: Content
  /** Known attributes. A pattern restricts the value; `null` accepts any string. */
  attributes: Readonly<Record<string, RegExp | null>>
  required?: readonly string[]
  /** Structural elements that exist only inside these parents. */
  parents?: readonly string[]
}

const align = /^(left|center|right|justify)$/
const textBlock: ElementRule = {
  kind: 'block',
  content: 'inline',
  attributes: { align, indent: /^[1-9][0-9]{0,2}$/, style: null }
}
const cell: ElementRule = {
  kind: 'block',
  content: 'blocks',
  attributes: { align, background: /^#[0-9a-fA-F]{6}$/, colspan: /^[1-9][0-9]{0,3}$/, rowspan: /^[1-9][0-9]{0,3}$/ },
  parents: ['tr']
}
const mark: ElementRule = { kind: 'inline', content: 'inline', attributes: {} }

/** Text formats in nesting order. `code` is always innermost. */
export const marks = ['strong', 'em', 's', 'u', 'mark', 'sub', 'sup', 'code'] as const
export type Mark = (typeof marks)[number]

/** The element vocabulary of a page. Names outside it are unknown elements and are kept as written. */
export const vocabulary: Readonly<Record<string, ElementRule>> = {
  page: { kind: 'block', content: 'blocks', attributes: {} },
  block: { kind: 'block', content: 'blocks', attributes: {} },
  columns: { kind: 'block', content: ['column'], attributes: {} },
  column: { kind: 'block', content: 'blocks', attributes: { width: /^[1-9][0-9]{0,3}$/ }, parents: ['columns'] },
  p: textBlock,
  h1: textBlock,
  h2: textBlock,
  h3: textBlock,
  h4: textBlock,
  h5: textBlock,
  h6: textBlock,
  blockquote: { kind: 'block', content: 'blocks', attributes: {} },
  ul: { kind: 'block', content: ['li'], attributes: {} },
  ol: { kind: 'block', content: ['li'], attributes: { start: /^(0|[1-9][0-9]{0,8})$/ } },
  li: { kind: 'block', content: 'blocks', attributes: { task: /^(todo|done)$/ }, parents: ['ul', 'ol'] },
  pre: { kind: 'block', content: 'text', attributes: { lang: null, meta: null, wrap: /^true$/ } },
  math: { kind: 'block', content: 'text', attributes: {} },
  mermaid: {
    kind: 'block',
    content: 'text',
    attributes: { view: /^(both|code|diagram)$/, theme: /^(auto|light|dark)$/ }
  },
  hr: { kind: 'block', content: 'empty', attributes: {} },
  table: {
    kind: 'block',
    content: ['tr'],
    attributes: { widths: /^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3})*$/, layout: /^full$/ }
  },
  tr: { kind: 'block', content: ['th', 'td'], attributes: {}, parents: ['table'] },
  th: cell,
  td: cell,
  callout: {
    kind: 'block',
    content: 'blocks',
    attributes: { tone: /^(info|warning|success|danger|neutral)$/, icon: null }
  },
  embed: {
    kind: 'block',
    content: 'empty',
    attributes: { ref: null, table: null, view: null, href: null, title: null }
  },
  ...Object.fromEntries(
    ['media', 'bookmark'].map(name => [
      name,
      {
        kind: 'block',
        content: 'empty',
        attributes: {
          src: null,
          title: null,
          description: null,
          image: null,
          mime: null,
          size: null,
          kind: /^(image|video)$/,
          view: /^(link|title|card|preview)$/
        }
      } as ElementRule
    ])
  ),
  a: { kind: 'inline', content: 'inline', attributes: { href: null, title: null }, required: ['href'] },
  img: { kind: 'inline', content: 'empty', attributes: { src: null, alt: null, title: null }, required: ['src'] },
  br: { kind: 'inline', content: 'empty', attributes: {} },
  mention: { kind: 'inline', content: 'empty', attributes: { page: /^[\s\S]+$/, principal: /^[\s\S]+$/ } },
  span: { kind: 'inline', content: 'inline', attributes: { style: null } },
  comment: { kind: 'inline', content: 'inline', attributes: { ids: null }, required: ['ids'] },
  ...Object.fromEntries(marks.map(name => [name, mark]))
}

export const ruleOf = (name: string): ElementRule | undefined =>
  Object.hasOwn(vocabulary, name) ? vocabulary[name] : undefined

/** Element and attribute names outside the vocabulary. They are kept and reported to the writer. */
export function unknownNames(root: Element): string[] {
  const found = new Set<string>()
  function visit(node: Element) {
    const rule = ruleOf(node.name)
    if (!rule) found.add(`未知元素 <${node.name}>`)
    else {
      for (const key of Object.keys(node.attrs)) {
        if (!Object.hasOwn(rule.attributes, key)) found.add(`<${node.name}> 的未知属性 ${key}`)
      }
    }
    for (const child of node.children) if (child.type === 'element') visit(child)
  }
  visit(root)
  return [...found]
}
