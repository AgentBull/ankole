import type { Nodes, Parent, Root } from 'mdast'
import { fromMarkdown } from 'mdast-util-from-markdown'
import remarkGfm from 'remark-gfm'
import remarkMath from 'remark-math'

type Range = [start: number, end: number]
type TextEdit = [start: number, end: number, replacement: string]

const PROTECTED_NODE_TYPES = new Set([
  'code',
  'inlineCode',
  'math',
  'inlineMath',
  'link',
  'image',
  'html',
  'linkReference',
  'imageReference',
  'definition'
])

const PARSE_OPTIONS = (() => {
  const data: {
    micromarkExtensions?: NonNullable<Parameters<typeof fromMarkdown>[1]>['extensions']
    fromMarkdownExtensions?: NonNullable<Parameters<typeof fromMarkdown>[1]>['mdastExtensions']
  } = {}
  const processor = { data: () => data }
  remarkGfm.call(processor as never)
  remarkMath.call(processor as never)
  return {
    extensions: data.micromarkExtensions ?? [],
    mdastExtensions: data.fromMarkdownExtensions ?? []
  }
})()

function parseMdast(source: string): Root {
  return fromMarkdown(source, PARSE_OPTIONS)
}

/**
 * Remark plugin placed after `remarkMath` for Assistant-generated Markdown (`generated === true`).
 */
export function repairGeneratedMarkdown() {
  return (tree: Root, file: { value: unknown }) => {
    const source = String(file.value ?? '')
    if (!source) return
    const repaired = repairGeneratedMarkdownFromTree(source, tree)
    if (repaired === source) return
    file.value = repaired
    const nextTree = parseMdast(repaired)
    tree.children = nextTree.children
  }
}

function repairGeneratedMarkdownFromTree(source: string, initialTree: Root): string {
  const initialProtected = collectProtectedRanges(source, initialTree)
  const step1 = applyStep1ToText(source, initialTree, initialProtected)
  const tree = step1 === source ? initialTree : parseMdast(step1)
  const protectedRanges = step1 === source ? initialProtected : collectProtectedRanges(step1, tree)
  return applySteps2And3(step1, tree, protectedRanges)
}

function isParent(node: Nodes): node is Parent & Nodes {
  return 'children' in node && Array.isArray(node.children)
}

function nodeRange(source: string, node: Nodes): Range | null {
  const start = node.position?.start.offset
  const end = node.position?.end.offset
  if (typeof start !== 'number' || typeof end !== 'number') return null
  const clampedStart = Math.max(0, Math.min(start, source.length))
  const clampedEnd = Math.max(0, Math.min(end, source.length))
  return clampedStart < clampedEnd ? [clampedStart, clampedEnd] : null
}

function mergeRanges(ranges: Range[]): Range[] {
  if (ranges.length === 0) return []
  const sorted = [...ranges].sort((a, b) => a[0] - b[0] || a[1] - b[1])
  const merged: Range[] = []
  for (const [start, end] of sorted) {
    const prev = merged.at(-1)
    if (prev && start <= prev[1]) {
      prev[1] = Math.max(prev[1], end)
    } else {
      merged.push([start, end])
    }
  }
  return merged
}

function collectProtectedRanges(source: string, root: Root): Range[] {
  const baseRanges: Range[] = []
  const visit = (node: Nodes) => {
    if (PROTECTED_NODE_TYPES.has(node.type)) {
      const range = nodeRange(source, node)
      if (range) baseRanges.push(range)
      return
    }
    if (isParent(node)) {
      for (const child of node.children as Nodes[]) visit(child)
    }
  }
  visit(root)

  const mergedBase = mergeRanges(baseRanges)
  const wikiRanges = collectWikiLinkRanges(source, mergedBase)
  return wikiRanges.length > 0 ? mergeRanges([...mergedBase, ...wikiRanges]) : mergedBase
}

function collectWikiLinkRanges(source: string, protectedRanges: Range[]): Range[] {
  const ranges: Range[] = []
  let cursor = 0
  for (const [start, end] of protectedRanges) {
    if (cursor < start) scanWikiLinksInSlice(source, cursor, start, ranges)
    cursor = end
  }
  if (cursor < source.length) scanWikiLinksInSlice(source, cursor, source.length, ranges)
  return ranges
}

function scanWikiLinksInSlice(source: string, sliceStart: number, sliceEnd: number, out: Range[]): void {
  const re = /\[\[[^\][\r\n]+\]\]/g
  const text = source.slice(sliceStart, sliceEnd)
  for (const match of text.matchAll(re)) {
    const absStart = sliceStart + (match.index ?? 0)
    if (trailingBackslashes(source, absStart) % 2 === 0) {
      out.push([absStart, absStart + match[0].length])
    }
  }
}

function isRangeOverlapping(start: number, end: number, protectedRanges: Range[]): boolean {
  for (const [pStart, pEnd] of protectedRanges) {
    if (pEnd <= start) continue
    if (pStart >= end) return false
    return true
  }
  return false
}

function subtractProtected(range: Range, protectedRanges: Range[]): Range[] {
  const [, end] = range
  let [cursor] = range
  const out: Range[] = []
  for (const [pStart, pEnd] of protectedRanges) {
    if (pEnd <= cursor) continue
    if (pStart >= end) break
    if (cursor < pStart) out.push([cursor, pStart])
    cursor = Math.max(cursor, pEnd)
    if (cursor >= end) break
  }
  if (cursor < end) out.push([cursor, end])
  return out
}

function applyStep1ToText(source: string, root: Root, protectedRanges: Range[]): string {
  const ranges: Range[] = []
  const visit = (node: Nodes) => {
    if (PROTECTED_NODE_TYPES.has(node.type)) return
    if (node.type === 'text') {
      const range = nodeRange(source, node)
      if (range) ranges.push(...subtractProtected(range, protectedRanges))
    }
    if (isParent(node)) {
      for (const child of node.children as Nodes[]) visit(child)
    }
  }
  visit(root)

  let out = ''
  let cursor = 0
  for (const [start, end] of mergeRanges(ranges)) {
    out += source.slice(cursor, start)
    out += recoverStructuralNewlines(source.slice(start, end))
    cursor = end
  }
  out += source.slice(cursor)
  return out
}

function recoverStructuralNewlines(segment: string): string {
  let out = ''
  let index = 0
  while (index < segment.length) {
    if (segment[index] === '\\' && segment[index + 1] === '\\') {
      out += '\\\\'
      index += 2
      continue
    }

    if (segment[index] === '\\' && segment[index + 1] === 'n') {
      let run = 0
      while (segment[index + run * 2] === '\\' && segment[index + run * 2 + 1] === 'n') {
        run += 1
      }
      if (run >= 2) {
        out += '\n'.repeat(run)
        index += run * 2
        continue
      }
      if (startsStructuralMarker(segment.slice(index + 2))) {
        out += '\n'
        index += 2
        continue
      }
    }

    out += segment[index]!
    index += 1
  }
  return out
}

function startsStructuralMarker(rest: string): boolean {
  let spaces = 0
  while (spaces < 3 && rest[spaces] === ' ') spaces += 1
  const trimmed = rest.slice(spaces)
  if (trimmed.length < 2) return false

  const first = trimmed[0]!
  if ((first === '-' || first === '*' || first === '+') && trimmed[1] === ' ') {
    return true
  }

  if (first === '#') {
    let hashes = 0
    while (hashes < 6 && trimmed[hashes] === '#') hashes += 1
    return trimmed[hashes] === ' '
  }

  if (first >= '0' && first <= '9') {
    let digits = 0
    while (digits < 9 && trimmed[digits] !== undefined && trimmed[digits]! >= '0' && trimmed[digits]! <= '9') {
      digits += 1
    }
    return trimmed[digits] === '.' && trimmed[digits + 1] === ' '
  }

  return false
}

function applySteps2And3(source: string, root: Root, protectedRanges: Range[]): string {
  const edits: TextEdit[] = []
  const textRanges: Range[] = []

  const visit = (node: Nodes) => {
    if (PROTECTED_NODE_TYPES.has(node.type)) return
    const range = nodeRange(source, node)

    if (node.type === 'delete' && range && !isRangeOverlapping(range[0], range[1], protectedRanges)) {
      const [start, end] = range
      const raw = source.slice(start, end)
      if (raw.length >= 3 && raw.startsWith('~') && !raw.startsWith('~~') && raw.endsWith('~') && !raw.endsWith('~~')) {
        edits.push([start, start + 1, '\\~'], [end - 1, end, '\\~'])
      }
    } else if (node.type === 'text' && range) {
      for (const clean of subtractProtected(range, protectedRanges)) {
        textRanges.push(clean)
      }
    }

    if (isParent(node)) {
      for (const child of node.children as Nodes[]) visit(child)
    }
  }
  visit(root)

  textRanges.sort((a, b) => a[0] - b[0] || a[1] - b[1])
  const mergedText: Range[] = []
  for (const [start, end] of textRanges) {
    const prev = mergedText.at(-1)
    if (prev && prev[1] === start) {
      prev[1] = end
    } else if (!prev || start >= prev[1]) {
      mergedText.push([start, end])
    }
  }

  for (const [start, end] of mergedText) {
    collectStrongWhitespaceEdits(source.slice(start, end), start, edits)
  }

  if (edits.length === 0) return source
  edits.sort((a, b) => a[0] - b[0] || a[1] - b[1])

  let out = ''
  let cursor = 0
  for (const [start, end, replacement] of edits) {
    if (start < cursor || end > source.length) continue
    out += source.slice(cursor, start) + replacement
    cursor = end
  }
  out += source.slice(cursor)
  return out
}

function collectStrongWhitespaceEdits(segment: string, baseOffset: number, edits: TextEdit[]): void {
  let index = 0
  while (index < segment.length) {
    const canOpen =
      index + 1 < segment.length &&
      segment[index] === '*' &&
      segment[index + 1] === '*' &&
      (index === 0 || segment[index - 1] !== '*') &&
      (index + 2 >= segment.length || segment[index + 2] !== '*') &&
      trailingBackslashes(segment, index) % 2 === 0

    if (canOpen) {
      let close = index + 2
      while (close < segment.length && segment[close] !== '*' && segment[close] !== '\n' && segment[close] !== '\r') {
        close += 1
      }

      if (
        close + 1 < segment.length &&
        segment[close] === '*' &&
        segment[close + 1] === '*' &&
        (close + 2 >= segment.length || segment[close + 2] !== '*')
      ) {
        const inner = segment.slice(index + 2, close)
        let wsStart = inner.length
        while (wsStart > 0 && (inner[wsStart - 1] === ' ' || inner[wsStart - 1] === '\t')) {
          wsStart -= 1
        }
        const content = inner.slice(0, wsStart)
        const ws = inner.slice(wsStart)
        if (
          ws.length > 0 &&
          content.length > 0 &&
          content[0] !== ' ' &&
          content[0] !== '\t' &&
          trailingBackslashes(content, content.length) % 2 === 0
        ) {
          edits.push([baseOffset + index, baseOffset + close + 2, `**${content}**${ws}`])
          index = close + 2
          continue
        }
      }
    }

    index += 1
  }
}

function trailingBackslashes(text: string, endIndex: number): number {
  let count = 0
  for (let i = endIndex - 1; i >= 0 && text[i] === '\\'; i -= 1) {
    count += 1
  }
  return count
}
