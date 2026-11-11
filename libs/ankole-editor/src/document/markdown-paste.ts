import type { Nodes } from 'mdast'
import { fromMarkdown } from 'mdast-util-from-markdown'
import { mathFromMarkdown } from 'mdast-util-math'
import { math } from 'micromark-extension-math'
import { mdxMd } from 'micromark-extension-mdx-md'
import { knowledgeAttributes, validateKnowledge } from './knowledge'
import { readMarkdownTree, type MarkdownMode } from './markdown'
import { normalizeTree } from './normalize'
import { safeLinkHref } from './resources'
import { applySourceEdits, codeRanges, isEscaped, isLinkDestination, scanTag, type SourceEdit } from './tags'
import { element, removeInvalidCharacters, text, textOf, type Element, type Node } from './tree'
import { ruleOf } from './vocabulary'

const frontmatterPattern = /^\uFEFF?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/
const yamlTopKey = /^([A-Za-z_][A-Za-z0-9_.-]*)[ \t]*:(?:[ \t]*(.*))?$/
const httpAutolink = /^<(https?:\/\/[^\s<>]+)>/i
const emailAutolink =
  /^<([A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+)>/
const genericAutolink = /^<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*>/

const htmlInlineAliases: Readonly<Record<string, string>> = {
  b: 'strong',
  i: 'em',
  del: 's',
  strike: 's',
  kbd: 'code',
  ins: 'u'
}

const transparentWrappers = new Set(['details', 'summary', 'center'])

/** Extract leading YAML frontmatter when every line inside the `---` block has YAML structure. */
function extractYamlFrontmatter(source: string): { body: string; title?: string } {
  const withoutBom = source.startsWith('\uFEFF') ? source.slice(1) : source
  const match = frontmatterPattern.exec(source)
  if (!match) return { body: withoutBom }
  const inner = match[1]!
  if (inner.length > 8192) return { body: withoutBom }
  const lines = inner.split(/\r?\n/)
  if (!lines.length || lines.length > 80) return { body: withoutBom }
  let hasKey = false
  let title: string | undefined
  for (const line of lines) {
    if (!/\S/.test(line) || /^[ \t]*#/.test(line)) continue
    const keyMatch = yamlTopKey.exec(line)
    if (keyMatch) {
      hasKey = true
      if (keyMatch[1]!.toLowerCase() === 'title' && keyMatch[2]) {
        const rawVal = keyMatch[2].trim()
        if (rawVal && rawVal !== '|' && rawVal !== '>') {
          title = unquoteYamlScalar(rawVal)
        }
      }
      continue
    }
    if (/^[ \t]+\S/.test(line) || /^-[ \t]+\S/.test(line)) continue
    return { body: withoutBom }
  }
  return hasKey ? { body: source.slice(match[0].length), ...(title ? { title } : {}) } : { body: withoutBom }
}

function unquoteYamlScalar(value: string): string {
  if (
    (value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
    (value.startsWith("'") && value.endsWith("'") && value.length >= 2)
  ) {
    return value.slice(1, -1).trim()
  }
  return value
}

function offsetInsideRanges(ranges: readonly [number, number][], offset: number): boolean {
  for (const [start, end] of ranges) {
    if (start > offset) return false
    if (offset < end) return true
  }
  return false
}

function escapeDoubleDollarRuns(value: string): string {
  return value.replace(/\${2,}/g, match => '\\$'.repeat(match.length))
}

function preprocessMarkdown(source: string): string {
  const protectedRanges: [number, number][] = []
  const inlineMathRanges: { start: number; end: number; value: string }[] = []

  function visit(node: Nodes) {
    if ((node.type === 'code' || node.type === 'inlineCode' || node.type === 'math') && node.position) {
      protectedRanges.push([node.position.start.offset!, node.position.end.offset!])
      return
    }
    if (node.type === 'inlineMath' && node.position) {
      inlineMathRanges.push({
        start: node.position.start.offset!,
        end: node.position.end.offset!,
        value: node.value
      })
      return
    }
    if ('children' in node) {
      for (const child of node.children) visit(child)
    }
  }

  visit(
    fromMarkdown(source, {
      extensions: [math({ singleDollarTextMath: false }), mdxMd()],
      mdastExtensions: [mathFromMarkdown()]
    })
  )
  protectedRanges.sort((a, b) => a[0] - b[0])

  const edits: SourceEdit[] = []

  for (let lineStart = 0; lineStart <= source.length;) {
    const lf = source.indexOf('\n', lineStart)
    const rawEnd = lf === -1 ? source.length : lf
    const lineEnd = rawEnd > lineStart && source[rawEnd - 1] === '\r' ? rawEnd - 1 : rawEnd
    const line = source.slice(lineStart, lineEnd)
    const taskMatch = /^([ \t]*)\[([ xX])\]([ \t]+\S)/.exec(line)
    if (taskMatch) {
      const bracketOffset = lineStart + taskMatch[1]!.length
      if (!offsetInsideRanges(protectedRanges, bracketOffset)) {
        edits.push({ at: bracketOffset, length: 0, insert: '- ' })
      }
    }
    if (lf === -1) break
    lineStart = lf + 1
  }

  for (const item of inlineMathRanges) {
    const raw = source.slice(item.start, item.end)
    const lineStart = source.lastIndexOf('\n', item.start - 1) + 1
    const lf = source.indexOf('\n', item.end)
    const rawEnd = lf === -1 ? source.length : lf
    const lineEnd = rawEnd > lineStart && source[rawEnd - 1] === '\r' ? rawEnd - 1 : rawEnd
    const prefix = source.slice(lineStart, item.start)
    const suffix = source.slice(item.end, lineEnd)
    const trimmedValue = item.value.trim()
    if (
      !/[\r\n]/.test(raw) &&
      raw.startsWith('$$') &&
      !raw.startsWith('$$$') &&
      !raw.slice(2, -2).includes('$') &&
      trimmedValue &&
      /^[ \t]{0,3}$/.test(prefix) &&
      /^[ \t]*$/.test(suffix)
    ) {
      edits.push({
        at: lineStart,
        length: lineEnd - lineStart,
        insert: `${prefix}$$\n${trimmedValue}\n${prefix}$$`
      })
    } else {
      edits.push({
        at: item.start,
        length: item.end - item.start,
        insert: escapeDoubleDollarRuns(raw)
      })
    }
  }

  edits.sort((a, b) => a.at - b.at)
  return applySourceEdits(source, edits)
}

const escapeLinkLabel = (label: string) => label.replace(/([\\[\]])/g, '\\$1')

function isStandaloneLineTag(source: string, start: number, end: number): boolean {
  const lineStart = source.lastIndexOf('\n', start - 1) + 1
  const nextNewline = source.indexOf('\n', end)
  const lineEnd = nextNewline === -1 ? source.length : nextNewline
  return /^[ \t]*$/.test(source.slice(lineStart, start)) && /^[ \t\r]*$/.test(source.slice(end, lineEnd))
}

function rewritePastedMarkup(source: string): string {
  const code = codeRanges(source)
  const edits: SourceEdit[] = []
  let range = 0
  for (let index = source.indexOf('<'); index !== -1; index = source.indexOf('<', index)) {
    while (range < code.length && code[range]![1] <= index) range++
    const current = code[range]
    if (current && current[0] <= index) {
      index = current[1]
      continue
    }
    if (isEscaped(source, index) || isLinkDestination(source, index)) {
      index++
      continue
    }
    const rest = source.slice(index, index + 4096)
    if (rest.startsWith('<!--')) {
      const close = source.indexOf('-->', index + 4)
      const end = close === -1 ? source.length : close + 3
      edits.push({ at: index, length: end - index, insert: '' })
      index = end
      continue
    }
    if (rest.startsWith('<![CDATA[')) {
      const close = source.indexOf(']]>', index + 9)
      const inner = close === -1 ? source.slice(index + 9) : source.slice(index + 9, close)
      const end = close === -1 ? source.length : close + 3
      edits.push({
        at: index,
        length: end - index,
        insert: inner.replaceAll('&', '&amp;').replaceAll('<', '&lt;')
      })
      index = end
      continue
    }
    if (rest.startsWith('<?')) {
      const close = source.indexOf('?>', index + 2)
      const end = close === -1 ? source.length : close + 2
      edits.push({ at: index, length: end - index, insert: '' })
      index = end
      continue
    }
    if (rest.startsWith('<!')) {
      const close = source.indexOf('>', index + 2)
      const end = close === -1 ? source.length : close + 1
      edits.push({ at: index, length: end - index, insert: '' })
      index = end
      continue
    }
    const urlMatch = httpAutolink.exec(rest)
    if (urlMatch) {
      const url = urlMatch[1]!
      edits.push({ at: index, length: urlMatch[0].length, insert: `[${escapeLinkLabel(url)}](<${url}>)` })
      index += urlMatch[0].length
      continue
    }
    const mailMatch = emailAutolink.exec(rest)
    if (mailMatch) {
      const email = mailMatch[1]!
      edits.push({ at: index, length: mailMatch[0].length, insert: `[${escapeLinkLabel(email)}](<mailto:${email}>)` })
      index += mailMatch[0].length
      continue
    }
    if (genericAutolink.test(rest)) {
      edits.push({ at: index, length: 1, insert: '&lt;' })
      index++
      continue
    }
    const bounds = scanTag(source, index)
    if (!bounds) {
      edits.push({ at: index, length: 1, insert: '&lt;' })
      index++
      continue
    }
    const rawName = source.slice(bounds.nameIndex, bounds.nameEnd)
    const lower = /^[A-Za-z][A-Za-z0-9-]*$/.test(rawName) ? rawName.toLowerCase() : rawName
    if (transparentWrappers.has(lower)) {
      const standalone = isStandaloneLineTag(source, index, bounds.end)
      edits.push({ at: index, length: bounds.end - index, insert: standalone ? '\n\n' : '' })
      index = bounds.end
      continue
    }
    const canonical = htmlInlineAliases[lower] ?? lower
    if (!ruleOf(canonical)) {
      edits.push({ at: index, length: 1, insert: '&lt;' })
      index++
      continue
    }
    if (canonical !== rawName) {
      edits.push({ at: bounds.nameIndex, length: bounds.nameEnd - bounds.nameIndex, insert: canonical })
    }
    index = bounds.end
  }
  return applySourceEdits(source, edits)
}

function escapeAllTagsOutsideCode(source: string): string {
  const code = codeRanges(source)
  const edits: SourceEdit[] = []
  let range = 0
  for (let index = source.indexOf('<'); index !== -1; index = source.indexOf('<', index)) {
    while (range < code.length && code[range]![1] <= index) range++
    const current = code[range]
    if (current && current[0] <= index) {
      index = current[1]
      continue
    }
    if (isEscaped(source, index) || isLinkDestination(source, index)) {
      index++
      continue
    }
    edits.push({ at: index, length: 1, insert: '&lt;' })
    index++
  }
  return applySourceEdits(source, edits)
}

function cleanNode(node: Node, mode: MarkdownMode): Node[] {
  if (node.type === 'text') return [node]
  if (node.name === 'comment') return node.children.flatMap(child => cleanNode(child, mode))
  if (mode === 'knowledge') {
    if (node.name === 'infographic' || node.name === 'math') {
      const content = textOf(node)
      return [element('pre', { lang: node.name }, content ? [text(content)] : [])]
    }
    if (
      node.name === 'u' ||
      node.name === 'mark' ||
      node.name === 'sub' ||
      node.name === 'sup' ||
      node.name === 'span'
    ) {
      return node.children.flatMap(child => cleanNode(child, mode))
    }
    if (node.name === 'columns' || node.name === 'column' || node.name === 'block') {
      return node.children.flatMap(child => cleanNode(child, mode))
    }
    if (node.name === 'embed') {
      const safeHref = node.attrs.href ? safeLinkHref(node.attrs.href) : null
      if (!safeHref) return []
      const label = node.attrs.title?.trim() || safeHref
      return [element('p', {}, [element('a', { href: safeHref }, [text(label)])])]
    }
    if (node.name === 'media' && node.attrs.kind && node.attrs.kind !== 'image') {
      const safeSrc = node.attrs.src ? safeLinkHref(node.attrs.src) : null
      if (!safeSrc) return []
      const label = node.attrs.title?.trim() || safeSrc
      return [element('p', {}, [element('a', { href: safeSrc }, [text(label)])])]
    }
  }

  const rule = ruleOf(node.name)
  if (!rule) {
    const content = textOf(node)
    return content ? [text(content)] : []
  }

  const knowledgeAllowed = mode === 'knowledge' ? knowledgeAttributes[node.name] : undefined
  const attrs: Record<string, string> = {}
  for (const [key, val] of Object.entries(node.attrs)) {
    if (!Object.hasOwn(rule.attributes, key)) continue
    if (knowledgeAllowed && !knowledgeAllowed.includes(key)) continue
    const pattern = rule.attributes[key]
    if (pattern && !pattern.test(val)) continue
    attrs[key] = val
  }

  const children = node.children.flatMap(child => cleanNode(child, mode))

  if (node.name === 'a') {
    const safeHref = attrs.href ? safeLinkHref(attrs.href) : null
    if (!safeHref) return children
    attrs.href = safeHref
  }
  if (node.name === 'embed' && attrs.href) {
    const safeHref = safeLinkHref(attrs.href)
    if (safeHref) attrs.href = safeHref
    else delete attrs.href
  }
  if ((node.name === 'img' || node.name === 'media') && attrs.src) {
    const safeSrc = safeLinkHref(attrs.src)
    if (safeSrc) attrs.src = safeSrc
    else delete attrs.src
  }
  if (node.name === 'img' && !attrs.src?.trim()) return []
  if (node.name === 'media' && !attrs.src?.trim()) return []
  if (node.name === 'embed' && !attrs.ref?.trim() && !attrs.href?.trim()) return []
  if (node.name === 'mention' && !attrs.page?.trim() && !attrs.principal?.trim()) return []

  return [element(node.name, attrs, children)]
}

function cleanPastedPage(page: Element, mode: MarkdownMode): Element {
  const cleanedChildren = page.children.flatMap(child => cleanNode(child, mode))
  const normalized = normalizeTree(element('page', {}, cleanedChildren))
  return mode === 'knowledge' ? validateKnowledge(normalized) : normalized
}

/**
 * Parse pasted Markdown leniently, tolerating YAML frontmatter, HTML comments, angle-bracket
 * autolinks, standalone task checkboxes, HTML inline aliases, and unquoted placeholder tags.
 */
export function parsePastedMarkdown(raw: string, mode: MarkdownMode = 'doc'): Element | null {
  const cleaned = removeInvalidCharacters(raw)
  if (!cleaned.trim()) return null
  const prepped = preprocessMarkdown(extractYamlFrontmatter(cleaned).body)
  try {
    return readMarkdownTree(rewritePastedMarkup(prepped), mode, tree => cleanPastedPage(tree, mode))
  } catch {
    try {
      return readMarkdownTree(escapeAllTagsOutsideCode(prepped), mode, tree => cleanPastedPage(tree, mode))
    } catch {
      return null
    }
  }
}

/**
 * Heuristic check for whether clipboard text carries Markdown structure worth parsing over a
 * non-semantic HTML wrapper (such as IDE, terminal, or chat plain-text wrappers).
 */
export function looksLikeMarkdown(source: string, options?: { fromPreWrapper?: boolean }): boolean {
  const trimmed = source.trim()
  if (!trimmed) return false

  let signals = 0
  const lines = trimmed.split(/\r?\n/).length
  const baseMin = Math.min(3, Math.floor(lines / 5))
  const minConfidence = options?.fromPreWrapper ? Math.max(2, Math.min(4, Math.floor(lines / 5))) : baseMin

  // Paired code fences (``` or ~~~)
  const backtickFences = trimmed.match(/^[ \t]{0,3}`{3,}/gm)
  if (backtickFences && backtickFences.length >= 2) signals += backtickFences.length * 2
  const tildeFences = trimmed.match(/^[ \t]{0,3}~{3,}/gm)
  if (tildeFences && tildeFences.length >= 2) signals += tildeFences.length * 2

  // Display math blocks (`$$`)
  const blockMath = trimmed.match(/^[ \t]{0,3}\$\$[ \t]*$/gm)
  if (blockMath && blockMath.length >= 2) signals += blockMath.length * 2
  const singleLineBlockMath = trimmed.match(/^[ \t]{0,3}\$\$[^$\r\n]+\$\$[ \t]*$/gm)
  if (singleLineBlockMath) signals += singleLineBlockMath.length * 2

  // Markdown links & images (`[label](url)` / `![alt](url)`)
  const links = trimmed.match(/!?\[[^\]\r\n]+\]\((?:https?:\/\/|\/|mailto:|#)[^\s)]+\)/g)
  if (links) signals += links.length * 2

  // ATX headings: subheadings (`##`..`######`) and `# Heading` separated by blank lines are stronger signals than shell comments
  const subheadings = trimmed.match(/^[ \t]{0,3}#{2,6}[ \t]+\S/gm)
  if (subheadings) signals += subheadings.length * 2
  const h1WithBlank = trimmed.match(/^[ \t]{0,3}#[ \t]+\S[^\r\n]*(?:\r?\n[ \t]*\r?\n|$)/gm)
  if (h1WithBlank) signals += h1WithBlank.length * 2
  else {
    const anyH1 = trimmed.match(/^[ \t]{0,3}#[ \t]+\S/gm)
    if (anyH1) signals += anyH1.length
  }

  // Lists & task items (requires whitespace after marker so `-$187.55` currency never matches)
  const lists = trimmed.match(/^[ \t]*(?:[-*+]|\d+\.)[ \t]+\S/gm)
  if (lists) signals += lists.length
  const standaloneTasks = trimmed.match(/^[ \t]*\[[ xX]\][ \t]+\S/gm)
  if (standaloneTasks) signals += standaloneTasks.length * 2

  // Blockquotes & horizontal rules
  const quotes = trimmed.match(/^[ \t]{0,3}>[ \t]+\S/gm)
  if (quotes) signals += quotes.length
  const rules = trimmed.match(/^(?:---|\*\*\*|___)[ \t]*$/gm)
  if (rules) signals += rules.length

  // GFM table delimiter row
  const tables = trimmed.match(/^[ \t]*\|?(?:[ \t]*:?-+:?[ \t]*\|)+[ \t]*:?-+:?[ \t]*\|?[ \t]*$/gm)
  if (tables) signals += tables.length * 3

  // Inline emphasis / strikethrough / code spans
  const strong = trimmed.match(/\*\*[^*\s][^*\r\n]*\*\*/g)
  if (strong) signals += strong.length
  const strike = trimmed.match(/~~[^~\s][^~\r\n]*~~/g)
  if (strike) signals += strike.length
  const inlineCode = trimmed.match(/`[^`\s][^`\r\n]*`/g)
  if (inlineCode) signals += inlineCode.length

  // Ankole block tags
  const blockTags = trimmed.match(/^<(?:callout|embed|media|columns|math|mermaid|infographic)\b/gm)
  if (blockTags) signals += blockTags.length * 3

  return signals > minConfidence
}

const structuralFirstLine =
  /^[ \t]{0,3}(?:`{3,}|~{3,}|\$\$|\|.+\||<(?:callout|embed|media|columns|table|ul|ol|pre|mermaid|infographic|math|hr|blockquote)\b|(?:---|\*\*\*|___)[ \t]*$|(?:[-*+]|\d+\.)[ \t]+\S|\[[ xX]\][ \t]+\S|>[ \t])/

function cleanTitleHeading(line: string, stripAtxPrefix: boolean): string {
  let cleaned = line.trim()
  if (stripAtxPrefix) {
    cleaned = cleaned.replace(/^#{1,6}[ \t]+/, '').replace(/[ \t]+#+[ \t]*$/, '')
  }
  if (
    cleaned.startsWith('**') &&
    cleaned.endsWith('**') &&
    cleaned.length > 4 &&
    !cleaned.slice(2, -2).includes('**')
  ) {
    cleaned = cleaned.slice(2, -2)
  } else if (
    cleaned.startsWith('`') &&
    cleaned.endsWith('`') &&
    cleaned.length > 2 &&
    !cleaned.slice(1, -1).includes('`')
  ) {
    cleaned = cleaned.slice(1, -1)
  }
  return cleaned.trim()
}

/**
 * Split text pasted into a document title field into a single-line title and optional body
 * Markdown overflow. Returns `null` when default single-line `<textarea>` paste should run.
 */
export function splitPastedDocumentTitle(
  rawText: string,
  options?: { replaceAllTitle?: boolean }
): { title: string; body: string } | null {
  const replaceAll = options?.replaceAllTitle === true
  if (!replaceAll) return null
  const cleaned = removeInvalidCharacters(rawText)
  if (!cleaned) return null

  if (!/\r|\n/.test(cleaned)) {
    if (/^[ \t]*#{1,6}[ \t]+\S/.test(cleaned)) {
      return { title: cleanTitleHeading(cleaned, true), body: '' }
    }
    return null
  }

  const { body: withoutFrontmatter, title: frontmatterTitle } = extractYamlFrontmatter(cleaned)
  const trimmedLeading = withoutFrontmatter.replace(/^(?:[ \t]*\r?\n)+/, '')
  if (!trimmedLeading) {
    return frontmatterTitle && replaceAll ? { title: frontmatterTitle, body: '' } : { title: '', body: '' }
  }

  const newlineMatch = /\r?\n/.exec(trimmedLeading)
  const firstLine = newlineMatch ? trimmedLeading.slice(0, newlineMatch.index) : trimmedLeading
  const rest = newlineMatch
    ? trimmedLeading.slice(newlineMatch.index + newlineMatch[0].length).replace(/^(?:[ \t]*\r?\n)+/, '')
    : ''

  // If YAML frontmatter supplied a `title:` and the body does not begin with an H1, keep the frontmatter title
  // and send the entire body into the document editor.
  if (frontmatterTitle && replaceAll && !/^[ \t]{0,3}#[ \t]+\S/.test(firstLine)) {
    return { title: frontmatterTitle, body: trimmedLeading }
  }

  // Structural blocks (fences, diagrams, tables, lists, blockquotes) belong in the document body, not the title.
  if (structuralFirstLine.test(firstLine)) {
    return { title: '', body: trimmedLeading }
  }

  return {
    title: cleanTitleHeading(firstLine, replaceAll || /^[ \t]*#{1,6}[ \t]+\S/.test(firstLine)),
    body: rest
  }
}
