import type { Nodes } from 'mdast'
import { fromMarkdown } from 'mdast-util-from-markdown'
import { mdxMd } from 'micromark-extension-mdx-md'
import { DocumentError } from './tree'

export type PreparedSource = {
  source: string
  /** Map an offset in the prepared source to the offset in the original source. */
  original(offset: number): number
}

type Edit = { at: number; length: number; insert: string }
type Scan =
  | { kind: 'text' }
  | { kind: 'tag'; end: number; edits: Edit[] }
  | { kind: 'error'; end: number; reason: string; fix: string }

const voidElements = new Set([
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr'
])
const nameStart = /[\p{L}_$]/u
const nameCharacter = /[\p{L}\p{N}_$.:-]/u
const autolink =
  /^<(?:[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*|[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*)>/

/**
 * Tags follow MDX, which rejects `a<b`, `<br>` and unquoted attribute values.
 * Rewrite the accepted forms to canonical tags before the tag parser reads
 * the source: a `<` that cannot start a tag becomes `&lt;`, an unquoted value
 * gets quotes and an HTML void element gets its slash. Code and escaped `<`
 * keep their text. Comments, processing instructions and angle-bracket
 * autolinks are rejected with a repair.
 */
export function prepareTags(source: string): PreparedSource {
  const code = codeRanges(source)
  const edits: Edit[] = []
  let range = 0
  for (let index = source.indexOf('<'); index !== -1; index = source.indexOf('<', index)) {
    while (range < code.length && code[range]![1] <= index) range++
    const current = code[range]
    if (current && current[0] <= index) {
      index = current[1]
      continue
    }
    if (escaped(source, index) || destination(source, index)) {
      index++
      continue
    }
    const result = scan(source, index)
    if (result.kind === 'error') {
      throw new DocumentError('markdown', result.reason, index, result.end, result.fix, source)
    }
    if (result.kind === 'text') {
      edits.push({ at: index, length: 1, insert: '&lt;' })
      index++
    } else {
      edits.push(...result.edits)
      index = result.end
    }
  }
  let prepared = ''
  let last = 0
  for (const edit of edits) {
    prepared += source.slice(last, edit.at) + edit.insert
    last = edit.at + edit.length
  }
  prepared += source.slice(last)
  return {
    source: prepared,
    original(offset) {
      let shift = 0
      for (const edit of edits) {
        const start = edit.at + shift
        if (offset < start) break
        if (offset < start + edit.insert.length) return edit.at
        shift += edit.insert.length - edit.length
      }
      return offset - shift
    }
  }
}

function codeRanges(source: string): [number, number][] {
  const ranges: [number, number][] = []
  function visit(node: Nodes) {
    if ((node.type === 'code' || node.type === 'inlineCode') && node.position) {
      ranges.push([node.position.start.offset!, node.position.end.offset!])
    }
    if ('children' in node) for (const child of node.children) visit(child)
  }
  // GFM is left out: a bare URL inside a tag attribute could swallow the backtick of a code span.
  visit(fromMarkdown(source, { extensions: [mdxMd()] }))
  return ranges.sort((a, b) => a[0] - b[0])
}

function escaped(source: string, index: number) {
  let slashes = 0
  while (source[index - 1 - slashes] === '\\') slashes++
  return slashes % 2 === 1
}

// `[text](<destination>)` uses angle brackets for a link destination.
const destination = (source: string, index: number) =>
  /\]\([ \t]*(?:\r?\n[ \t]*)?$/.test(source.slice(Math.max(0, index - 64), index))

function scan(source: string, index: number): Scan {
  const rest = source.slice(index, index + 4096)
  const error = (reason: string, terminator: string, fix: string): Scan => {
    const end = source.indexOf(terminator, index)
    return { kind: 'error', end: end === -1 ? source.length : end + terminator.length, reason, fix }
  }
  if (rest.startsWith('<!--')) return error('页面没有注释节点', '-->', '请删除这段注释。')
  if (rest.startsWith('<![CDATA[')) return error('页面不支持 CDATA', ']]>', '请直接写文字。')
  if (rest.startsWith('<?')) return error('页面不支持处理指令', '?>', '请删除这段指令。')
  if (rest.startsWith('<!')) return error('页面不支持 <!…> 声明', '>', '请删除这段声明。')
  const link = autolink.exec(rest)
  if (link) {
    return {
      kind: 'error',
      end: index + link[0].length,
      reason: '页面不支持尖括号自动链接',
      fix: '请改用 [文字](网址)，或直接写网址。'
    }
  }
  return tag(source, index)
}

function characterAt(source: string, index: number) {
  const code = source.codePointAt(index)
  return code === undefined ? '' : String.fromCodePoint(code)
}

function readName(source: string, index: number) {
  if (!nameStart.test(characterAt(source, index))) return index
  let end = index
  for (let character = characterAt(source, end); nameCharacter.test(character); character = characterAt(source, end)) {
    end += character.length
  }
  return end
}

function skipSpace(source: string, index: number) {
  const space = /^[ \t]*(?:\r?\n[ \t]*)?/.exec(source.slice(index, index + 256))![0]
  return index + space.length
}

function closingBrace(source: string, index: number) {
  let depth = 0
  for (let end = index; end < source.length; end++) {
    if (source[end] === '{') depth++
    else if (source[end] === '}' && --depth === 0) return end + 1
  }
  return -1
}

/** Read one tag with the accepted forms. Anything that is not a tag is text. */
function tag(source: string, index: number): Scan {
  const text: Scan = { kind: 'text' }
  const closing = source[index + 1] === '/'
  const nameIndex = index + (closing ? 2 : 1)
  const nameEnd = readName(source, nameIndex)
  if (nameEnd === nameIndex) return text
  const name = source.slice(nameIndex, nameEnd)
  const edits: Edit[] = []
  for (let position = nameEnd; ;) {
    const next = skipSpace(source, position)
    const spaced = next > position
    position = next
    const character = source[position]
    if (character === undefined) return text
    if (character === '>') {
      if (!closing && voidElements.has(name)) edits.push({ at: position, length: 0, insert: ' /' })
      return { kind: 'tag', end: position + 1, edits }
    }
    if (character === '/' && source[position + 1] === '>' && !closing) return { kind: 'tag', end: position + 2, edits }
    if (closing || !spaced) return text
    if (character === '{') {
      position = closingBrace(source, position)
      if (position === -1) return text
      continue
    }
    const attributeEnd = readName(source, position)
    if (attributeEnd === position) return text
    position = attributeEnd
    const equals = /^[ \t]*=[ \t]*/.exec(source.slice(position, position + 64))
    if (!equals) continue
    position += equals[0].length
    const quote = source[position]
    if (quote === '"' || quote === "'") {
      const end = source.indexOf(quote, position + 1)
      if (end === -1 || /\n[ \t]*\r?\n/.test(source.slice(position, end))) return text
      position = end + 1
    } else if (quote === '{') {
      position = closingBrace(source, position)
      if (position === -1) return text
    } else {
      const value = /^[^\s"'=<>`{}]+/.exec(source.slice(position, position + 4096))?.[0]
      if (!value) return text
      edits.push({ at: position, length: value.length, insert: `"${value}"` })
      position += value.length
    }
  }
}
