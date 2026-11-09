import { parseXml } from '@ankole/block-editor/document'
import type { TFunction } from 'i18next'
import type { PageSearchTarget } from './content-api'
import type { FileCommentAnchor } from './file-comment-anchors'

export type ParsedSearchTarget =
  | { kind: 'file_anchor'; anchor: FileCommentAnchor }
  | { kind: 'heading'; heading: string }
  | { kind: 'page'; page: number }
  | { kind: 'sheet'; sheet: string }
  | { kind: 'table'; tableID: string; viewID?: string }

export type DocumentPreviewHeading = {
  level: number
  text: string
}

export type DocumentPreviewBlock = {
  kind: 'heading' | 'paragraph' | 'code' | 'quote'
  level?: number
  text: string
}

export type DocumentPreview = {
  headings: DocumentPreviewHeading[]
  blocks: DocumentPreviewBlock[]
  excerptSkippedBefore?: boolean
}

export type NormalizedSearchText = {
  text: string
  rawStart: Uint32Array
  rawEnd: Uint32Array
}

const graphemeSegmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' })

function isAsciiOnly(input: string): boolean {
  for (let i = 0; i < input.length; i++) {
    if (input.charCodeAt(i) > 0x7f) return false
  }
  return true
}

/** Normalizes a search string with full NFKC + lowercase to match backend indexing semantics. */
export function normalizeSearchQuery(input: string): string {
  return isAsciiOnly(input) ? input.toLowerCase() : input.normalize('NFKC').toLowerCase()
}

/**
 * Normalizes `raw` with full NFKC + lowercase while recording the exact UTF-16 `[rawStart, rawEnd)`
 * span in `raw` for every UTF-16 code unit of `text`, handling length-changing expansions (`ﬃ` -> `ffi`),
 * contractions (`ｶﾞ` -> `ガ`, `e\u0301` -> `é`), and compatibility forms (`①` -> `1`, `Ｑ` -> `q`).
 */
export function normalizeSearchText(raw: string): NormalizedSearchText {
  const len = raw.length
  if (len === 0) {
    return { text: '', rawStart: new Uint32Array(0), rawEnd: new Uint32Array(0) }
  }
  if (isAsciiOnly(raw)) {
    const rawStart = new Uint32Array(len)
    const rawEnd = new Uint32Array(len)
    for (let i = 0; i < len; i++) {
      rawStart[i] = i
      rawEnd[i] = i + 1
    }
    return { text: raw.toLowerCase(), rawStart, rawEnd }
  }

  let text = ''
  const starts: number[] = []
  const ends: number[] = []
  for (const { segment, index } of graphemeSegmenter.segment(raw)) {
    const folded = segment.normalize('NFKC').toLowerCase()
    if (!folded) continue
    const segEnd = index + segment.length
    text += folded
    for (let k = 0; k < folded.length; k++) {
      starts.push(index)
      ends.push(segEnd)
    }
  }
  return {
    text,
    rawStart: Uint32Array.from(starts),
    rawEnd: Uint32Array.from(ends)
  }
}

/** Parses quoted phrases and unquoted tokens using the same rules as `Ankole.Pod.Pages.Search.parse_query/1`. */
export function parseSearchQueryTerms(rawQuery: string): string[] {
  const normalized = rawQuery.normalize('NFKC').trim()
  if (!normalized) return []
  const terms: string[] = []
  for (const quotedMatch of normalized.matchAll(/"([^"]+)"/g)) {
    const phrase = quotedMatch[1]?.trim()
    if (phrase) terms.push(phrase)
  }
  const rest = normalized.replace(/"[^"]*"/g, ' ')
  for (const token of rest.split(/\s+/)) {
    const clean = token.replace(/^"+|"+$/g, '').trim()
    if (clean) terms.push(clean)
  }
  return [...new Set(terms)]
}

/**
 * Returns primary and fallback NFKC-normalized needles for DOM in-page find (`PageFindBar` / `SessionFindBar`).
 * Manual `Cmd/Ctrl+F` (`searchSyntax = false`, default) matches the literal contiguous string;
 * full-text search arrivals (`?find=...`, `searchSyntax = true`) honor quoted phrases and fall back
 * to individual terms when the contiguous string has zero matches.
 */
export function resolveFindNeedleSets(
  rawQuery: string,
  options?: { searchSyntax?: boolean }
): {
  primary: string[]
  fallback: string[]
} {
  const trimmed = rawQuery.normalize('NFKC').trim()
  if (!trimmed) return { primary: [], fallback: [] }
  const contiguous = normalizeSearchQuery(trimmed)
  if (!options?.searchSyntax) {
    return { primary: [contiguous], fallback: [] }
  }
  const terms = parseSearchQueryTerms(trimmed)
    .map(term => normalizeSearchQuery(term))
    .filter(Boolean)
    .sort((a, b) => b.length - a.length)
  if (trimmed.includes('"')) {
    return { primary: terms.length > 0 ? terms : [contiguous], fallback: [] }
  }
  const fallback = terms.length > 1 ? terms : []
  return { primary: [contiguous], fallback }
}

/** Collects non-overlapping `[start, end)` UTF-16 spans inside an already normalized haystack. */
export function collectNormalizedSpanOffsets(
  normalizedHaystack: string,
  needles: readonly string[]
): Array<{ start: number; end: number }> {
  const active = needles.filter(needle => needle.length > 0)
  if (!normalizedHaystack || active.length === 0) return []
  if (active.length === 1) {
    const needle = active[0]!
    const spans: Array<{ start: number; end: number }> = []
    let from = 0
    while (from <= normalizedHaystack.length - needle.length) {
      const idx = normalizedHaystack.indexOf(needle, from)
      if (idx < 0) break
      spans.push({ start: idx, end: idx + needle.length })
      from = idx + needle.length
    }
    return spans
  }
  const candidates: Array<{ start: number; end: number }> = []
  for (const needle of active) {
    let from = 0
    while (from <= normalizedHaystack.length - needle.length) {
      const idx = normalizedHaystack.indexOf(needle, from)
      if (idx < 0) break
      candidates.push({ start: idx, end: idx + needle.length })
      from = idx + 1
    }
  }
  candidates.sort((a, b) => a.start - b.start || b.end - b.start - (a.end - a.start))
  const merged: Array<{ start: number; end: number }> = []
  let cursor = 0
  for (const span of candidates) {
    if (span.start < cursor) continue
    merged.push(span)
    cursor = span.end
  }
  return merged
}

/** Maps normalized match spans back to disjoint `[start, end)` UTF-16 code-unit spans in the raw source string. */
export function collectRawMatchSpans(
  normalized: NormalizedSearchText,
  needles: readonly string[]
): Array<{ start: number; end: number }> {
  const normSpans = collectNormalizedSpanOffsets(normalized.text, needles)
  if (normSpans.length === 0) return []
  const rawSpans: Array<{ start: number; end: number }> = []
  for (const span of normSpans) {
    if (span.end <= span.start) continue
    const start = normalized.rawStart[span.start]
    const end = normalized.rawEnd[span.end - 1]
    if (start === undefined || end === undefined || end <= start) continue
    const prev = rawSpans[rawSpans.length - 1]
    if (prev && start < prev.end) {
      prev.end = Math.max(prev.end, end)
    } else {
      rawSpans.push({ start, end })
    }
  }
  return rawSpans
}

export function encodeSearchTarget(target: PageSearchTarget | null | undefined): {
  at?: string
  view?: string
} {
  if (!target) return {}
  switch (target.kind) {
    case 'doc_section': {
      const heading = target.heading.trim()
      return heading ? { at: `heading:${heading}` } : {}
    }
    case 'md_section': {
      const heading = target.heading.trim()
      if (!heading) return {}
      const start = target.start_line && target.start_line > 0 ? String(target.start_line) : ''
      return { at: `md:${target.level}:${start}:${heading}` }
    }
    case 'lines': {
      if (target.start_line <= 0) return {}
      const end = Math.max(target.start_line, target.end_line)
      return { at: end > target.start_line ? `lines:${target.start_line}-${end}` : `line:${target.start_line}` }
    }
    case 'csv_rows': {
      if (target.start_row <= 0) return {}
      const end = Math.max(target.start_row, target.end_row)
      return { at: end > target.start_row ? `rows:${target.start_row}-${end}` : `row:${target.start_row}` }
    }
    case 'page_number':
      return target.page > 0 ? { at: `page:${target.page}` } : {}
    case 'spreadsheet_cell': {
      const sheet = target.sheet_name.trim()
      return sheet ? { at: `sheet:${sheet}` } : {}
    }
    case 'base_table': {
      const tableID = target.table_id.trim()
      if (!tableID) return {}
      const view = target.view_id?.trim() || undefined
      return { at: `table:${tableID}`, ...(view ? { view } : {}) }
    }
  }
}

function parsePositiveRange(raw: string): { start: number; end: number } | undefined {
  const dash = raw.indexOf('-')
  if (dash < 0) {
    const single = Number.parseInt(raw, 10)
    return Number.isSafeInteger(single) && single >= 1 ? { start: single, end: single } : undefined
  }
  const start = Number.parseInt(raw.slice(0, dash), 10)
  const end = Number.parseInt(raw.slice(dash + 1), 10)
  if (!Number.isSafeInteger(start) || start < 1 || !Number.isSafeInteger(end) || end < start) return undefined
  return { start, end }
}

export function parseSearchTarget(at?: string | null, view?: string | null): ParsedSearchTarget | undefined {
  if (!at) return undefined
  const colon = at.indexOf(':')
  if (colon <= 0) return undefined
  const prefix = at.slice(0, colon)
  const raw = at.slice(colon + 1)
  if (!raw) return undefined
  switch (prefix) {
    case 'heading':
      return { kind: 'heading', heading: raw }
    case 'md': {
      const firstSep = raw.indexOf(':')
      const secondSep = firstSep >= 0 ? raw.indexOf(':', firstSep + 1) : -1
      if (firstSep <= 0 || secondSep < 0) return undefined
      const level = Number.parseInt(raw.slice(0, firstSep), 10)
      const lineRaw = raw.slice(firstSep + 1, secondSep)
      const heading = raw.slice(secondSep + 1).trim()
      if (!heading || !Number.isSafeInteger(level) || level < 1 || level > 6) return undefined
      const startLine = lineRaw ? Number.parseInt(lineRaw, 10) : undefined
      return {
        kind: 'file_anchor',
        anchor: {
          kind: 'md_section',
          heading,
          level,
          ...(startLine && Number.isSafeInteger(startLine) && startLine >= 1 ? { start_line: startLine } : {})
        }
      }
    }
    case 'line':
    case 'lines': {
      const range = parsePositiveRange(raw)
      return range
        ? { kind: 'file_anchor', anchor: { kind: 'lines', start_line: range.start, end_line: range.end } }
        : undefined
    }
    case 'row':
    case 'rows': {
      const range = parsePositiveRange(raw)
      return range
        ? { kind: 'file_anchor', anchor: { kind: 'csv_rows', start_row: range.start, end_row: range.end } }
        : undefined
    }
    case 'page': {
      const page = Number.parseInt(raw, 10)
      return Number.isSafeInteger(page) && page >= 1 ? { kind: 'page', page } : undefined
    }
    case 'sheet':
      return { kind: 'sheet', sheet: raw }
    case 'table':
      return { kind: 'table', tableID: raw, ...(view?.trim() ? { viewID: view.trim() } : {}) }
    default:
      return undefined
  }
}

export function buildSearchResultHref(
  baseHref: string,
  query: string,
  target?: PageSearchTarget | null,
  matchFields?: readonly string[]
): string {
  const cleanQuery = query.trim()
  const encoded = encodeSearchTarget(target)
  const includeFind =
    target?.kind === 'base_table'
      ? false
      : matchFields
        ? matchFields.some(field => field !== 'title') || Boolean(target)
        : Boolean(cleanQuery)
  if ((!includeFind || !cleanQuery) && !encoded.at && !encoded.view) return baseHref
  const hashIndex = baseHref.indexOf('#')
  const withoutHash = hashIndex >= 0 ? baseHref.slice(0, hashIndex) : baseHref
  const hash = hashIndex >= 0 ? baseHref.slice(hashIndex) : ''
  const qIndex = withoutHash.indexOf('?')
  const pathname = qIndex >= 0 ? withoutHash.slice(0, qIndex) : withoutHash
  const params = new URLSearchParams(qIndex >= 0 ? withoutHash.slice(qIndex + 1) : '')
  if (includeFind && cleanQuery) params.set('find', cleanQuery)
  if (encoded.at) params.set('at', encoded.at)
  if (encoded.view) params.set('view', encoded.view)
  const search = params.toString()
  return `${pathname}${search ? `?${search}` : ''}${hash}`
}

export function splitHighlightSegments(text: string, rawQuery: string): Array<{ text: string; hit: boolean }> {
  if (!text) return []
  const needles = parseSearchQueryTerms(rawQuery)
    .map(term => normalizeSearchQuery(term))
    .filter(Boolean)
    .sort((a, b) => b.length - a.length)
  if (needles.length === 0) return [{ text, hit: false }]
  const spans = collectRawMatchSpans(normalizeSearchText(text), needles)
  if (spans.length === 0) return [{ text, hit: false }]
  const segments: Array<{ text: string; hit: boolean }> = []
  let lastIndex = 0
  for (const span of spans) {
    if (span.start > lastIndex) {
      segments.push({ text: text.slice(lastIndex, span.start), hit: false })
    }
    segments.push({ text: text.slice(span.start, span.end), hit: true })
    lastIndex = span.end
  }
  if (lastIndex < text.length) {
    segments.push({ text: text.slice(lastIndex), hit: false })
  }
  return segments
}

export function formatSearchTargetBadge(target: PageSearchTarget | null | undefined, t: TFunction): string | undefined {
  if (!target) return undefined
  switch (target.kind) {
    case 'doc_section':
    case 'md_section':
      return target.heading.trim() ? `§ ${target.heading.trim()}` : undefined
    case 'lines':
      return target.end_line > target.start_line
        ? t('pod.command.target_lines', { start: target.start_line, end: target.end_line })
        : t('pod.command.target_line', { line: target.start_line })
    case 'csv_rows':
      return target.end_row > target.start_row
        ? t('pod.command.target_rows', { start: target.start_row, end: target.end_row })
        : t('pod.command.target_row', { row: target.start_row })
    case 'page_number':
      return t('pod.command.target_page', { page: target.page })
    case 'spreadsheet_cell':
      return target.sheet_name.trim() ? t('pod.command.target_sheet', { sheet: target.sheet_name.trim() }) : undefined
    case 'base_table':
      return target.label?.trim() ? t('pod.command.target_table', { table: target.label.trim() }) : undefined
  }
}

type XmlNode = ReturnType<typeof parseXml>['children'][number]

function collectNodeText(node: XmlNode): string {
  if (node.type === 'text') return node.value
  if (node.name === 'media' || node.name === 'embed' || node.name === 'img') {
    const parts = [node.attrs.title, node.attrs.description, node.attrs.alt]
      .map(value => value?.trim())
      .filter((value): value is string => Boolean(value))
    if (parts.length > 0) return parts.join(' — ')
    const address = (node.attrs.href ?? node.attrs.src)?.trim()
    return address && !address.startsWith('ankole:') ? address : ''
  }
  return node.children.map(collectNodeText).join('')
}

const MAX_PREVIEW_SCAN_BLOCKS = 240
const MAX_PREVIEW_WINDOW_BLOCKS = 12

export function extractXmlPreview(xml: string | null | undefined, rawQuery = ''): DocumentPreview {
  if (!xml?.trim()) return { headings: [], blocks: [], excerptSkippedBefore: false }
  try {
    const root = parseXml(xml)
    const headings: DocumentPreviewHeading[] = []
    const allBlocks: DocumentPreviewBlock[] = []
    const visit = (nodes: readonly XmlNode[]) => {
      for (const node of nodes) {
        if (node.type === 'text') continue
        const headingMatch = /^h([1-6])$/.exec(node.name)
        if (headingMatch) {
          const level = Number(headingMatch[1])
          const text = collectNodeText(node).trim()
          if (text) {
            headings.push({ level, text })
            if (allBlocks.length < MAX_PREVIEW_SCAN_BLOCKS) allBlocks.push({ kind: 'heading', level, text })
          }
          continue
        }
        if (node.name === 'p' || node.name === 'li' || node.name === 'callout') {
          const text = collectNodeText(node).trim()
          if (text && allBlocks.length < MAX_PREVIEW_SCAN_BLOCKS) allBlocks.push({ kind: 'paragraph', text })
          if (node.name === 'li' || node.name === 'callout') visit(node.children)
          continue
        }
        if (node.name === 'pre' || node.name === 'codeblock') {
          const text = collectNodeText(node).trim()
          if (text && allBlocks.length < MAX_PREVIEW_SCAN_BLOCKS) allBlocks.push({ kind: 'code', text })
          continue
        }
        if (node.name === 'blockquote') {
          const text = collectNodeText(node).trim()
          if (text && allBlocks.length < MAX_PREVIEW_SCAN_BLOCKS) allBlocks.push({ kind: 'quote', text })
          continue
        }
        if (node.name === 'media' || node.name === 'embed') {
          const text = collectNodeText(node).trim()
          if (text && allBlocks.length < MAX_PREVIEW_SCAN_BLOCKS) allBlocks.push({ kind: 'paragraph', text })
          continue
        }
        visit(node.children)
      }
    }
    visit(root.children)
    const needles = parseSearchQueryTerms(rawQuery)
      .map(term => normalizeSearchQuery(term))
      .filter(Boolean)
    if (needles.length > 0 && allBlocks.length > MAX_PREVIEW_WINDOW_BLOCKS) {
      const hitIndex = allBlocks.findIndex(block => {
        const normalized = normalizeSearchQuery(block.text)
        return needles.some(needle => normalized.includes(needle))
      })
      if (hitIndex >= MAX_PREVIEW_WINDOW_BLOCKS - 2) {
        const start = Math.min(Math.max(0, hitIndex - 2), allBlocks.length - MAX_PREVIEW_WINDOW_BLOCKS)
        return {
          headings,
          blocks: allBlocks.slice(start, start + MAX_PREVIEW_WINDOW_BLOCKS),
          excerptSkippedBefore: start > 0
        }
      }
    }
    return {
      headings,
      blocks: allBlocks.slice(0, MAX_PREVIEW_WINDOW_BLOCKS),
      excerptSkippedBefore: false
    }
  } catch {
    return { headings: [], blocks: [], excerptSkippedBefore: false }
  }
}
