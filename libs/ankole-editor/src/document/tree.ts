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

export type DocumentErrorCode =
  | 'source_too_large'
  | 'limit_exceeded'
  | 'invalid_character'
  | 'invalid_element_name'
  | 'invalid_attribute_name'
  | 'unclosed_tag'
  | 'mismatched_closing_tag'
  | 'unexpected_closing_tag'
  | 'misaligned_closing_tag'
  | 'invalid_tag_syntax'
  | 'expression_attribute'
  | 'duplicate_attribute'
  | 'unsupported_syntax'
  | 'unsupported_xml_version'
  | 'invalid_encoding'
  | 'missing_root'
  | 'invalid_root'
  | 'invalid_parent'
  | 'invalid_content'
  | 'invalid_attribute'
  | 'missing_attribute'
  | 'conflicting_list_attribute'
  | 'nested_link'

/** A tree rule violation. The parser that built `node` reports its source range. */
export class TreeError extends Error {
  readonly code: DocumentErrorCode
  constructor(
    message: string,
    public node: Node | undefined,
    public fix: string,
    code: DocumentErrorCode
  ) {
    super(message)
    this.name = 'TreeError'
    this.code = code
  }
}

/** A rejected source with its position, stable error code, reason, and a concrete repair. */
export class DocumentError extends Error {
  readonly line: number
  readonly column: number
  readonly code: DocumentErrorCode
  constructor(
    public format: SourceFormat,
    public reason: string,
    public start: number,
    public end: number,
    public fix: string,
    source: string,
    code: DocumentErrorCode
  ) {
    const before = source.slice(0, start)
    const line = before.split(/\r\n|\r|\n/).length
    const column = start - Math.max(before.lastIndexOf('\n'), before.lastIndexOf('\r'))
    const suffix = fix ? ` ${fix}` : ''
    super(`[${code}] ${format === 'xml' ? 'XML' : 'Markdown'}, line ${line}, column ${column}: ${reason}.${suffix}`)
    this.name = 'DocumentError'
    this.line = line
    this.column = column
    this.code = code
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
    throw new DocumentError(
      format,
      `The source exceeds ${limits.source} UTF-16 code units`,
      0,
      0,
      'Split the page into smaller pages before writing.',
      '',
      'source_too_large'
    )
  }
  const match = invalidCharacter.exec(source)
  if (match) {
    throw new DocumentError(
      format,
      `The source contains U+${match[0].codePointAt(0)!.toString(16).toUpperCase().padStart(4, '0')}, which XML 1.0 does not allow`,
      match.index,
      match.index + match[0].length,
      'Remove this character.',
      source,
      'invalid_character'
    )
  }
}

export function checkCharacters(value: string, node: Node) {
  if (invalidCharacter.test(value)) {
    throw new TreeError(
      'The content contains a character not allowed in XML 1.0 or a lone surrogate',
      node,
      'Remove this character.',
      'invalid_character'
    )
  }
}

// Names must be valid in XML and in Markdown tags, without namespaces.
const elementName = /^\p{L}[\p{L}\p{N}_-]*$/u
const attributeName = /^[\p{L}_][\p{L}\p{N}_-]*$/u

export function checkElementName(name: string, node: Node) {
  if (!elementName.test(name) || !NAME_RE.test(name)) {
    throw new TreeError(
      `The element name ${JSON.stringify(name)} is not valid`,
      node,
      'Start the element name with a letter and use only letters, digits, -, and _.',
      'invalid_element_name'
    )
  }
}

export function checkAttributeName(name: string, node: Node) {
  if (!attributeName.test(name) || !NAME_RE.test(name) || name === 'xmlns') {
    throw new TreeError(
      `The attribute name ${JSON.stringify(name)} is not valid`,
      node,
      'Start the attribute name with a letter or _, use only letters, digits, -, and _, and do not use xmlns.',
      'invalid_attribute_name'
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
