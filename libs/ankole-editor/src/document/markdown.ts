import type {
  BlockContent,
  Code,
  Definition,
  List,
  ListItem,
  Nodes,
  Paragraph,
  PhrasingContent,
  Root,
  RootContent,
  Table
} from 'mdast'
import { fromMarkdown } from 'mdast-util-from-markdown'
import { gfmFromMarkdown, gfmToMarkdown } from 'mdast-util-gfm'
import {
  mdxJsxFromMarkdown,
  mdxJsxToMarkdown,
  type MdxJsxAttribute,
  type MdxJsxFlowElement,
  type MdxJsxTextElement
} from 'mdast-util-mdx-jsx'
import { toMarkdown, type Options } from 'mdast-util-to-markdown'
import { gfm } from 'micromark-extension-gfm'
import { mdxJsx } from 'micromark-extension-mdx-jsx'
import { mdxMd } from 'micromark-extension-mdx-md'
import { normalizeTree } from './normalize'
import { prepareTags, type PreparedSource } from './tags'
import { checkSource, DocumentError, element, text, textOf, TreeError, type Element, type Node } from './tree'
import { ruleOf } from './vocabulary'

const syntax = [gfm(), mdxJsx(), mdxMd(), { disable: { null: ['gfmFootnoteDefinition', 'gfmFootnoteCall'] } }]
// Bare URLs become links while the source is tokenized. The extra GFM pass would also link escaped text.
const trees = [...gfmFromMarkdown().map(extension => ({ ...extension, transforms: [] })), mdxJsxFromMarkdown()]

const read = (source: string) => fromMarkdown(source, { extensions: syntax, mdastExtensions: trees })

export function parseMarkdown(source: string): Element {
  checkSource(source, 'markdown')
  let prepared: PreparedSource = { source, original: offset => offset }
  let root: Root
  try {
    root = read(source)
  } catch {
    // Rewrite the accepted forms that MDX rejects, such as `a<b` or `<br>`, and read again.
    prepared = prepareTags(source)
    try {
      root = read(prepared.source)
    } catch (error) {
      throw syntaxError(error, prepared, source)
    }
  }
  const positions = new WeakMap<Node, [number, number]>()
  try {
    return normalizeTree(readMdast(root, positions))
  } catch (error) {
    if (!(error instanceof TreeError)) throw error
    const range = (error.node && positions.get(error.node)) ?? [0, prepared.source.length]
    throw new DocumentError(
      'markdown',
      error.message,
      prepared.original(range[0]),
      prepared.original(range[1]),
      error.fix,
      source
    )
  }
}

type Message = { reason?: string; ruleId?: string; place?: { offset?: number; start?: { offset?: number } } }

function syntaxError(error: unknown, prepared: PreparedSource, source: string) {
  const message = error as Message
  if (!message || typeof message.reason !== 'string') return error
  const reason = message.reason
  const unclosed = /^Expected a closing tag for `<([^>]*)>`/.exec(reason)
  // For an unclosed tag the place is its paragraph; the reason names the tag as (line:column-line:column).
  const tag = unclosed && /\((\d+):(\d+)-\d+:\d+\)/.exec(reason)
  const offset = tag
    ? offsetAt(prepared.source, Number(tag[1]), Number(tag[2]))
    : (message.place?.start?.offset ?? message.place?.offset ?? 0)
  const at = prepared.original(offset)
  if (unclosed) {
    return new DocumentError(
      'markdown',
      `标签 <${unclosed[1]}> 没有闭合`,
      at,
      at,
      // A tag that opens inside a paragraph must close in the same paragraph.
      /before the end of `paragraph`/.test(reason)
        ? `请在同一段里写 </${unclosed[1]}>：开始和结束标签之间不能有空行，也不能有单独成行的标签。如果这里是文字，请把 < 写成 &lt;。`
        : `请在内容后写 </${unclosed[1]}>；如果这里是文字，请把 < 写成 &lt;。`,
      source
    )
  }
  const mismatch = /^Unexpected closing tag `<\/([^>]*)>`, expected corresponding closing tag for `<([^>]*)>`/.exec(
    reason
  )
  if (mismatch) {
    return new DocumentError(
      'markdown',
      `结束标签 </${mismatch[1]}> 与开始标签 <${mismatch[2]}> 不匹配`,
      at,
      at,
      `请把它改成 </${mismatch[2]}>。`,
      source
    )
  }
  if (message.ruleId === 'unexpected-closing-slash') {
    return new DocumentError('markdown', '结束标签前没有对应的开始标签', at, at, '请删除它，或补上开始标签。', source)
  }
  const level = /^Expected the closing tag `<\/([^>]*)>` either after the end of/.exec(reason)
  if (level) {
    return new DocumentError(
      'markdown',
      `结束标签 </${level[1]}> 和开始标签不在同一层`,
      at,
      at,
      '开始标签单独成行时，结束标签也要单独成行；否则把两个标签写在同一段里。',
      source
    )
  }
  const character = /^Unexpected character .*? \(U\+([0-9A-F]+)\)/.exec(reason)
  if (character || message.ruleId === 'unexpected-eof') {
    return new DocumentError(
      'markdown',
      character ? `标签中不能有字符 ${String.fromCodePoint(parseInt(character[1]!, 16))}` : '标签没有写完',
      at,
      at,
      '请检查标签名和属性的写法；如果这里是文字，请把 < 写成 &lt;。',
      source
    )
  }
  return new DocumentError('markdown', `标签语法错误（${reason}）`, at, at, '请检查这个标签的写法。', source)
}

function offsetAt(source: string, line: number, column: number) {
  let offset = 0
  for (let current = 1; current < line; current++) {
    const next = source.indexOf('\n', offset)
    if (next === -1) break
    offset = next + 1
  }
  return offset + column - 1
}

/** Read Markdown syntax into a page tree. Tags written alone in a paragraph become block elements. */
function readMdast(root: Root, positions: WeakMap<Node, [number, number]>): Element {
  const definitions = new Map<string, Definition>()
  ;(function collect(node: Nodes) {
    if (node.type === 'definition' && !definitions.has(node.identifier)) definitions.set(node.identifier, node)
    if ('children' in node) node.children.forEach(child => collect(child as Nodes))
  })(root)

  function at<T extends Node>(created: T, source: Nodes): T {
    const start = source.position?.start.offset
    const end = source.position?.end.offset
    if (start !== undefined && end !== undefined) positions.set(created, [start, end])
    return created
  }

  function blocks(nodes: Nodes[]): Node[] {
    return nodes.flatMap(block)
  }

  function block(node: Nodes): Node[] {
    switch (node.type) {
      case 'paragraph':
        return paragraph(node)
      case 'heading':
        return [at(element(`h${node.depth}`, {}, inline(node.children)), node)]
      case 'thematicBreak':
        return [at(element('hr'), node)]
      case 'blockquote':
        return [at(element('blockquote', {}, blocks(node.children)), node)]
      case 'list':
        return [
          at(
            element(
              node.ordered ? 'ol' : 'ul',
              node.ordered && node.start != null ? { start: String(node.start) } : {},
              node.children.map(listItem)
            ),
            node
          )
        ]
      case 'code':
        return [at(codeBlock(node), node)]
      case 'table':
        return [table(node)]
      case 'definition':
        return []
      case 'mdxJsxFlowElement': {
        const created = jsx(node)
        // An inline element written as a block tag stays inline in its own paragraph.
        return [ruleOf(created.name)?.kind === 'inline' ? at(element('p', {}, [created]), node) : created]
      }
      default:
        throw new TreeError(`不支持的 Markdown 结构 ${node.type}`, at(element('unsupported'), node))
    }
  }

  function codeBlock(node: Code): Element {
    return element(
      'pre',
      { ...(node.lang != null ? { lang: node.lang } : {}), ...(node.meta != null ? { meta: node.meta } : {}) },
      node.value ? [text(node.value)] : []
    )
  }

  function listItem(item: ListItem): Element {
    return at(
      element('li', item.checked == null ? {} : { task: item.checked ? 'done' : 'todo' }, blocks(item.children)),
      item
    )
  }

  function paragraph(node: Paragraph): Node[] {
    const [only, ...rest] = node.children
    if (
      !rest.length &&
      only?.type === 'mdxJsxTextElement' &&
      only.name !== null &&
      ruleOf(only.name)?.kind !== 'inline'
    ) {
      return [jsx(only)]
    }
    // Known block elements written one per line join one paragraph in Markdown. Each of them is a block.
    const tags = node.children.filter((child): child is MdxJsxTextElement => child.type === 'mdxJsxTextElement')
    if (
      tags.length > 1 &&
      node.children.every(child =>
        child.type === 'text'
          ? /^\s*$/u.test(child.value)
          : child.type === 'mdxJsxTextElement' && child.name !== null && ruleOf(child.name)?.kind === 'block'
      )
    ) {
      return tags.map(tag => jsx(tag))
    }
    return [at(element('p', {}, inline(node.children)), node)]
  }

  function table(node: Table): Element {
    return at(
      element(
        'table',
        {},
        node.children.map((row, index) =>
          at(
            element(
              'tr',
              {},
              row.children.map((cell, column) =>
                at(
                  element(index === 0 ? 'th' : 'td', node.align?.[column] ? { align: node.align[column]! } : {}, [
                    at(element('p', {}, inline(cell.children)), cell)
                  ]),
                  cell
                )
              )
            ),
            row
          )
        )
      ),
      node
    )
  }

  function inline(nodes: PhrasingContent[]): Node[] {
    return nodes.flatMap((node): Node[] => {
      switch (node.type) {
        case 'text':
          return [at(text(node.value), node)]
        case 'strong':
        case 'emphasis':
        case 'delete':
          return [
            at(element({ strong: 'strong', emphasis: 'em', delete: 's' }[node.type], {}, inline(node.children)), node)
          ]
        case 'inlineCode':
          return [at(element('code', {}, [text(node.value)]), node)]
        case 'break':
          return [at(element('br'), node)]
        case 'link':
          return [at(element('a', link(node.url, node.title), inline(node.children)), node)]
        case 'image':
          return [at(element('img', image(node.url, node.alt, node.title)), node)]
        case 'linkReference':
        case 'imageReference': {
          const target = definitions.get(node.identifier)!
          return [
            node.type === 'linkReference'
              ? at(element('a', link(target.url, target.title), inline(node.children)), node)
              : at(element('img', image(target.url, node.alt, target.title)), node)
          ]
        }
        case 'mdxJsxTextElement':
          return [jsx(node)]
        default:
          throw new TreeError(`不支持的 Markdown 结构 ${node.type}`, at(element('unsupported'), node))
      }
    })
  }

  const link = (url: string, title?: string | null) => ({ href: url, ...(title != null ? { title } : {}) })
  const image = (url: string, alt?: string | null, title?: string | null) => ({
    src: url,
    ...(alt != null ? { alt } : {}),
    ...(title != null ? { title } : {})
  })

  function jsx(node: MdxJsxFlowElement | MdxJsxTextElement): Element {
    const created = at(element(node.name ?? '', {}), node)
    if (node.name === null) throw new TreeError('页面不支持片段 <>…</>', created, '请写出元素名。')
    created.attrs = attributes(node, created)
    const rule = ruleOf(node.name)
    if (node.type === 'mdxJsxTextElement') {
      created.children = inline(node.children)
      // A block element written on one line holds its inline content in a paragraph.
      if (rule?.content === 'blocks' && created.children.length) created.children = [element('p', {}, created.children)]
    } else if (rule?.content === 'text') created.children = codeTag(node, created)
    else if ((rule && (rule.content === 'inline' || rule.content === 'empty')) || (!rule && inlineTags(node))) {
      created.children = inlineTag(node, created)
    } else created.children = blocks(node.children)
    return created
  }

  // A line of tags is a block in MDX. An unknown element holding inline tags keeps them inline.
  function inlineTags(node: MdxJsxFlowElement) {
    const kinds = node.children.map(child =>
      child.type === 'mdxJsxFlowElement' ? (ruleOf(child.name ?? '')?.kind ?? 'unknown') : 'block'
    )
    return kinds.includes('inline') && !kinds.includes('block')
  }

  // A block tag of an element with inline content holds at most one paragraph and inline tags.
  function inlineTag(node: MdxJsxFlowElement, created: Element): Node[] {
    let paragraphs = 0
    return node.children.flatMap(child => {
      if (child.type === 'paragraph') {
        if (++paragraphs > 1) {
          throw new TreeError(`<${created.name}> 只能包含一段行内内容`, created, '请删除多余的空行，或拆成多个元素。')
        }
        return inline(child.children)
      }
      if (child.type === 'mdxJsxFlowElement') return [jsx(child)]
      throw new TreeError(`<${created.name}> 只能包含行内内容`, created, '请把块内容移到元素外面。')
    })
  }

  // A block tag of <pre> holds one code fence. The tag adds attributes the fence cannot carry.
  function codeTag(node: MdxJsxFlowElement, created: Element): Node[] {
    if (!node.children.length) return []
    const [fence, ...rest] = node.children
    if (rest.length || fence?.type !== 'code') {
      throw new TreeError(`<${created.name}> 只能包含一个代码围栏`, created, '请把代码写在 ``` 围栏里。')
    }
    const code = codeBlock(fence)
    for (const [key, value] of Object.entries(code.attrs)) {
      if (Object.hasOwn(created.attrs, key)) {
        throw new TreeError(`<${created.name}> 的 ${key} 写了两次`, created, `请只在标签或围栏中写 ${key}。`)
      }
      created.attrs = { ...created.attrs, [key]: value }
    }
    return code.children
  }

  function attributes(node: MdxJsxFlowElement | MdxJsxTextElement, created: Element): Record<string, string> {
    const entries: [string, string][] = []
    for (const attribute of node.attributes) {
      if (attribute.type === 'mdxJsxExpressionAttribute') {
        throw new TreeError('属性不能写成 {…} 表达式', created, '请写成 name="value"。')
      }
      if (attribute.value !== null && typeof attribute.value === 'object') {
        throw new TreeError(`属性 ${attribute.name} 的值不能写成 {…} 表达式`, created, `请写成 ${attribute.name}="…"。`)
      }
      if (entries.some(([name]) => name === attribute.name)) {
        throw new TreeError(`重复属性 ${attribute.name}`, created, '请只保留一个。')
      }
      // An attribute without a value means its own name, as in HTML.
      entries.push([attribute.name, attribute.value ?? attribute.name])
    }
    return Object.fromEntries(entries)
  }

  return element('page', {}, blocks(root.children))
}

const verbatim = (node: { value: string }) => node.value

const printOptions: Options = {
  bullet: '-',
  emphasis: '*',
  strong: '*',
  fence: '`',
  fences: true,
  incrementListMarker: true,
  listItemIndent: 'one',
  resourceLink: true,
  rule: '-',
  extensions: [
    gfmToMarkdown(),
    mdxJsxToMarkdown({ quote: '"' }),
    { handlers: { bareUrl: verbatim, raw: verbatim } as Options['handlers'] }
  ]
}

/** Print the canonical Markdown of a page. The result reads back as the same page. */
export function printMarkdown(tree: Element): string {
  const page = normalizeTree(tree)
  const source = toMarkdown(toMdast(page), printOptions).replace(/\n+$/, '')
  let reread: Element | undefined
  try {
    reread = parseMarkdown(source)
  } catch (error) {
    throw new Error(`规范 Markdown 无法读回：${error instanceof Error ? error.message : String(error)}`)
  }
  if (JSON.stringify(reread) !== JSON.stringify(page)) throw new Error('规范 Markdown 读回后得到不同的页面')
  return source
}

/** Choose Markdown syntax where it holds the element exactly, and a tag everywhere else. */
export function toMdast(page: Element): Root {
  return { type: 'root', children: page.children.map(block) }
}

const plain = (node: Element) => Object.keys(node.attrs).length === 0
const elements = (node: Element) => node.children as Element[]

function block(node: Node): RootContent {
  if (node.type === 'text') throw new Error('normalized pages have no text at block level')
  switch (node.name) {
    case 'p':
      return paragraph(node)
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      return plain(node)
        ? { type: 'heading', depth: Number(node.name[1]) as 1, children: inline(node.children) }
        : single(node)
    case 'blockquote':
      return plain(node)
        ? { type: 'blockquote', children: node.children.map(block) as BlockContent[] }
        : flow(node, node.children.map(block))
    case 'ul':
    case 'ol':
      return (
        list(node) ??
        flow(
          node,
          elements(node).map(item => flow(item, item.children.map(block)))
        )
      )
    case 'pre':
      return fence(node) ?? flow(node, [{ type: 'code', lang: null, meta: null, value: textOf(node) }])
    case 'hr':
      return plain(node) ? { type: 'thematicBreak' } : flow(node, [])
    case 'table':
      return gfmTable(node) ?? flow(node, elements(node).map(row))
    default:
      return node.children.every(child => child.type === 'element' && ruleOf(child.name)?.kind !== 'inline')
        ? flow(node, node.children.map(block))
        : single(node)
  }
}

// Cells that each hold one Markdown paragraph print one cell per line, as people write HTML tables.
function row(node: Element): MdxJsxFlowElement {
  const cells = elements(node).map(cell => {
    const [content, ...rest] = elements(cell)
    return { cell, line: !rest.length && content?.name === 'p' ? markdownLine(content) : undefined }
  })
  if (cells.some(({ line }) => !line)) {
    return flow(
      node,
      cells.map(({ cell }) => flow(cell, cell.children.map(block)))
    )
  }
  const children: PhrasingContent[] = []
  for (const { cell, line } of cells) {
    if (children.length) children.push({ type: 'text', value: '\n' })
    children.push({ type: 'mdxJsxTextElement', ...tagOf(cell), children: line! })
  }
  return flow(node, [{ type: 'paragraph', children }])
}

function paragraph(node: Element): RootContent {
  const children = markdownLine(node)
  return children ? { type: 'paragraph', children } : single(node)
}

// The content of a paragraph that can print without its tag. Some paragraphs would read
// back as block elements: a single unknown element, or a line that holds only tags.
function markdownLine(node: Element): PhrasingContent[] | undefined {
  const children = line(node.children)
  const [only] = node.children
  const unknownOnly = node.children.length === 1 && only?.type === 'element' && !ruleOf(only.name)
  return plain(node) && children.length && !tagsOnly(children) && !unknownOnly ? children : undefined
}

// A tag on its own line. Without content it is self-closing.
function single(node: Element): RootContent {
  if (!node.children.length) return flow(node, [])
  return { type: 'paragraph', children: [{ type: 'mdxJsxTextElement', ...tagOf(node), children: line(node.children) }] }
}

// MDX reads a line that holds only tags and white space as block tags.
const blankText = (node: PhrasingContent) => node.type === 'text' && /^\s*$/u.test(node.value)
const tagsOnly = (nodes: PhrasingContent[]): boolean =>
  nodes.every(node => blankText(node) || (node.type === 'mdxJsxTextElement' && tagsOnly(node.children)))

// Inline content of one line. White space inside a line of tags is written as
// character references, so the line reads back as text with the same spaces.
function line(nodes: Node[]): PhrasingContent[] {
  const children = inline(nodes)
  if (!tagsOnly(children)) return children
  const encode = (node: PhrasingContent): PhrasingContent =>
    blankText(node)
      ? ({
          type: 'raw',
          value: [...(node as { value: string }).value].map(character => `&#${character.codePointAt(0)};`).join('')
        } as unknown as PhrasingContent)
      : node.type === 'mdxJsxTextElement'
        ? { ...node, children: node.children.map(encode) }
        : node
  return children.map(encode)
}

function flow(node: Element, children: RootContent[]): MdxJsxFlowElement {
  return { type: 'mdxJsxFlowElement', ...tagOf(node), children: children as MdxJsxFlowElement['children'] }
}

const attributeEscapes: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '"': '&quot;',
  '\t': '&#9;',
  '\n': '&#10;',
  '\r': '&#13;'
}

function tagOf(node: Element): { name: string; attributes: MdxJsxAttribute[] } {
  return {
    name: node.name,
    attributes: Object.entries(node.attrs).map(([name, value]) => ({
      type: 'mdxJsxAttribute',
      name,
      value: value.replace(/[&<"\t\n\r]/g, character => attributeEscapes[character]!)
    }))
  }
}

function list(node: Element): List | undefined {
  const ordered = node.name === 'ol'
  if (!node.children.length || Object.keys(node.attrs).some(key => !(ordered && key === 'start'))) return undefined
  const items: ListItem[] = []
  for (const item of elements(node)) {
    if (Object.keys(item.attrs).some(key => key !== 'task')) return undefined
    const [first] = elements(item)
    // A task marker belongs to the first paragraph of an item.
    if (item.attrs.task && !(first?.name === 'p' && plain(first) && first.children.length)) return undefined
    items.push({
      type: 'listItem',
      // A tight item holds a paragraph and a sublist. Other blocks get blank lines,
      // which also keep `---` from turning a paragraph into a heading.
      spread: !tightItem(elements(item)),
      checked: item.attrs.task ? item.attrs.task === 'done' : null,
      children: item.children.map(block) as BlockContent[]
    })
  }
  return {
    type: 'list',
    ordered,
    start: ordered ? Number(node.attrs.start ?? 1) : null,
    spread: false,
    children: items
  }
}

const tightItem = ([first, second, ...rest]: Element[]) =>
  !second || (!rest.length && first?.name === 'p' && (second.name === 'ul' || second.name === 'ol'))

function fence(node: Element): Code | undefined {
  const { lang, meta, ...rest } = node.attrs
  if (Object.keys(rest).length) return undefined
  if (lang !== undefined && !/^[^\s`&\\]+$/.test(lang)) return undefined
  if (meta !== undefined && (lang === undefined || !/^[^\s`&\\\r\n](?:[^`&\\\r\n]*[^\s`&\\\r\n])?$/.test(meta))) {
    return undefined
  }
  return { type: 'code', lang: lang ?? null, meta: meta ?? null, value: textOf(node) }
}

function gfmTable(node: Element): Table | undefined {
  const rows = elements(node)
  const width = rows[0]?.children.length ?? 0
  if (!plain(node) || !width) return undefined
  const align = elements(rows[0]!).map(cell => cell.attrs.align ?? null)
  for (const [index, row] of rows.entries()) {
    if (!plain(row) || row.children.length !== width) return undefined
    for (const [column, cell] of elements(row).entries()) {
      const [content, ...rest] = elements(cell)
      if (
        cell.name !== (index === 0 ? 'th' : 'td') ||
        Object.keys(cell.attrs).some(key => key !== 'align') ||
        (cell.attrs.align ?? null) !== align[column] ||
        cell.attrs.align === 'justify' ||
        rest.length ||
        content?.name !== 'p' ||
        !plain(content) ||
        pipeInAttribute(content) ||
        edgeSpace(content)
      ) {
        return undefined
      }
    }
  }
  return {
    type: 'table',
    align: align as Table['align'],
    children: rows.map(row => ({
      type: 'tableRow',
      children: elements(row).map(cell => ({ type: 'tableCell', children: inline(elements(cell)[0]!.children) }))
    }))
  }
}

// GFM trims the white space at the edges of a cell.
const edgeSpace = (node: Element) => {
  const first = node.children[0]
  const last = node.children.at(-1)
  return (first?.type === 'text' && /^\s/u.test(first.value)) || (last?.type === 'text' && /\s$/u.test(last.value))
}

// GFM splits a row at every pipe before it reads tags, and a tag attribute cannot escape it.
const pipeInAttribute = (node: Node): boolean =>
  node.type === 'element' &&
  (Object.values(node.attrs).some(value => value.includes('|')) || node.children.some(pipeInAttribute))

function inline(nodes: Node[]): PhrasingContent[] {
  const result = nodes.map(phrasing)
  return result.map((node, index) => bareUrl(node, result[index - 1], result[index + 1], result[index + 2]) ?? node)
}

function phrasing(node: Node): PhrasingContent {
  if (node.type === 'text') return { type: 'text', value: node.value }
  if (plain(node)) {
    if (node.name === 'strong') return { type: 'strong', children: inline(node.children) }
    if (node.name === 'em') return { type: 'emphasis', children: inline(node.children) }
    if (node.name === 's') return { type: 'delete', children: inline(node.children) }
    const [only] = node.children
    if (node.name === 'code' && node.children.length === 1 && only?.type === 'text') {
      return { type: 'inlineCode', value: only.value }
    }
  }
  if (node.name === 'a') {
    const { href, title, ...rest } = node.attrs
    if (href !== undefined && !Object.keys(rest).length) {
      return { type: 'link', url: href, title: title ?? null, children: inline(node.children) }
    }
  }
  if (node.name === 'img') {
    const { src, alt, title, ...rest } = node.attrs
    if (src !== undefined && !Object.keys(rest).length) {
      return { type: 'image', url: src, alt: alt ?? '', title: title ?? null }
    }
  }
  return { type: 'mdxJsxTextElement', ...tagOf(node), children: inline(node.children) }
}

// A link whose text is its address reads best as a bare URL, where GFM links it again.
function bareUrl(
  node: PhrasingContent,
  before?: PhrasingContent,
  after?: PhrasingContent,
  next?: PhrasingContent
): PhrasingContent | undefined {
  if (node.type !== 'link' || node.title || node.children.length !== 1 || node.children[0]!.type !== 'text') {
    return undefined
  }
  const label = node.children[0].value
  if (![label, `http://${label}`, `mailto:${label}`].includes(node.url)) return undefined
  if (before && !(before.type === 'text' && /\s$/.test(before.value))) return undefined
  // The address ends at white space or at the end of the content, after optional punctuation.
  let tail = ''
  if (after) {
    if (after.type !== 'text') return undefined
    tail = /^[.,:!?)]*/.exec(after.value)![0]
    const rest = after.value.slice(tail.length)
    // White space at the end of the content is printed as character references, which GFM reads as part of the address.
    if (rest ? !/^\s/.test(rest) || (!next && !/\S/.test(rest)) : next) return undefined
  }
  return readsAsLink(label, tail, node.url)
    ? ({ type: 'bareUrl', value: label } as unknown as PhrasingContent)
    : undefined
}

// GFM must read the address and the punctuation after it as this link followed by the punctuation.
function readsAsLink(label: string, tail: string, url: string) {
  try {
    const [paragraph, ...others] = read(label + tail).children
    if (others.length || paragraph?.type !== 'paragraph') return false
    const [link, punctuation, ...rest] = paragraph.children
    const [content, ...more] = link?.type === 'link' ? link.children : []
    return (
      !rest.length &&
      !more.length &&
      link?.type === 'link' &&
      link.url === url &&
      content?.type === 'text' &&
      content.value === label &&
      (tail ? punctuation?.type === 'text' && punctuation.value === tail : !punctuation)
    )
  } catch {
    return false
  }
}
