import { NAME_RE } from 'xmlchars/xml/1.0/ed5'

export type Text = { type: 'text'; value: string }
export type Element = { type: 'element'; name: string; attrs: Record<string, string>; children: Node[] }
export type Node = Text | Element
export type SourceFormat = 'markdown' | 'xml'

export const text = (value: string): Text => ({ type: 'text', value })
export const element = (name: string, attrs: Record<string, string> = {}, children: Node[] = []): Element => ({
  type: 'element',
  name,
  attrs,
  children
})

export const limits = { source: 8 * 1024 * 1024, depth: 128, nodes: 100_000 }

/** A tree rule violation. The parser that built `node` reports its source range. */
export class TreeError extends Error {
  constructor(
    message: string,
    public node?: Node,
    public fix = ''
  ) {
    super(message)
  }
}

/** A rejected source with its position, the reason and a concrete repair. */
export class DocumentError extends Error {
  readonly line: number
  readonly column: number
  constructor(
    public format: SourceFormat,
    public reason: string,
    public start: number,
    public end: number,
    public fix: string,
    source = ''
  ) {
    const before = source.slice(0, start)
    const line = before.split(/\r\n|\r|\n/).length
    const column = start - Math.max(before.lastIndexOf('\n'), before.lastIndexOf('\r'))
    super(`${format === 'xml' ? 'XML' : 'Markdown'} 第 ${line} 行第 ${column} 列：${reason}。${fix}`)
    this.line = line
    this.column = column
  }
}

// XML 1.0 allows tab, LF and CR but rejects other control characters.
// eslint-disable-next-line no-control-regex
const invalidCharacter = /[^\u0009\u000a\u000d\u0020-\ud7ff\ue000-\ufffd\u{10000}-\u{10ffff}]/u
const invalidCharacters = new RegExp(invalidCharacter.source, 'gu')

/** Remove the characters that XML 1.0 does not allow, such as control characters and lone surrogates. */
export const removeInvalidCharacters = (value: string) => value.replace(invalidCharacters, '')

export function checkSource(source: string, format: SourceFormat) {
  if (source.length > limits.source) {
    throw new DocumentError(format, `源码超过 ${limits.source} 个 UTF-16 单元`, 0, 0, '请把页面拆小后再写入。')
  }
  const match = invalidCharacter.exec(source)
  if (match) {
    throw new DocumentError(
      format,
      `含有 XML 1.0 不允许的字符 U+${match[0].codePointAt(0)!.toString(16).toUpperCase().padStart(4, '0')}`,
      match.index,
      match.index + match[0].length,
      '请删除这个字符。',
      source
    )
  }
}

export function checkCharacters(value: string, node: Node) {
  if (invalidCharacter.test(value)) {
    throw new TreeError('含有 XML 1.0 不允许的字符或孤立代理项', node, '请删除这个字符。')
  }
}

// Names must be valid in XML and in Markdown tags, without namespaces.
const elementName = /^\p{L}[\p{L}\p{N}_-]*$/u
const attributeName = /^[\p{L}_][\p{L}\p{N}_-]*$/u

export function checkElementName(name: string, node: Node) {
  if (!elementName.test(name) || !NAME_RE.test(name)) {
    throw new TreeError(`元素名 ${JSON.stringify(name)} 不合法`, node, '元素名以字母开头，只能包含字母、数字、- 和 _。')
  }
}

export function checkAttributeName(name: string, node: Node) {
  if (!attributeName.test(name) || !NAME_RE.test(name) || name === 'xmlns') {
    throw new TreeError(
      `属性名 ${JSON.stringify(name)} 不合法`,
      node,
      '属性名以字母或 _ 开头，只能包含字母、数字、- 和 _，不能是 xmlns。'
    )
  }
}

/** Unicode code point order, independent of the locale. */
export function compareNames(a: string, b: string): number {
  const aa = [...a],
    bb = [...b]
  for (let i = 0; i < Math.min(aa.length, bb.length); i++) {
    const difference = aa[i]!.codePointAt(0)! - bb[i]!.codePointAt(0)!
    if (difference) return difference
  }
  return aa.length - bb.length
}

export function textOf(node: Node): string {
  return node.type === 'text' ? node.value : node.children.map(textOf).join('')
}
