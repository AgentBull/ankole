import type { Heading, Nodes } from 'mdast'
import { fromMarkdown } from 'mdast-util-from-markdown'

export type FileCommentAnchor =
  | { kind: 'lines'; start_line: number; end_line: number; object_id?: string }
  | { kind: 'csv_rows'; start_row: number; end_row: number; column?: string; object_id?: string }
  | { kind: 'md_section'; heading: string; level: number; start_line?: number; object_id?: string }
  | { kind: 'media_timestamp'; time_sec: number; end_time_sec?: number; object_id?: string }

export type FileCommentSelection = {
  anchor: FileCommentAnchor
  quote: string
}

export type FilePreviewHandle = {
  currentSelection(): FileCommentSelection | null
  revealAnchor(anchor: FileCommentAnchor): HTMLElement | null
}

const MAX_QUOTE_CHARS = 1000
const MAX_QUOTE_BYTES = 4096

export function clampCommentQuote(text: string): string {
  const normalized = text.replace(/\r\n?/g, '\n').trim()
  if (!normalized) return ''
  let chars = Array.from(normalized).slice(0, MAX_QUOTE_CHARS)
  const encoder = new TextEncoder()
  while (chars.length > 0 && encoder.encode(chars.join('')).byteLength > MAX_QUOTE_BYTES) {
    chars = chars.slice(0, Math.max(0, chars.length - 32))
  }
  return chars.join('')
}

export function parseFileCommentAnchor(raw: Record<string, unknown> | null | undefined): FileCommentAnchor | null {
  if (!raw || typeof raw !== 'object') return null
  const kind = raw.kind
  const object_id = typeof raw.object_id === 'string' ? raw.object_id : undefined
  if (kind === 'lines') {
    const start_line = Number(raw.start_line)
    const end_line = Number(raw.end_line)
    if (
      Number.isSafeInteger(start_line) &&
      start_line >= 1 &&
      Number.isSafeInteger(end_line) &&
      end_line >= start_line
    ) {
      return { kind: 'lines', start_line, end_line, ...(object_id ? { object_id } : {}) }
    }
    return null
  }
  if (kind === 'csv_rows') {
    const start_row = Number(raw.start_row)
    const end_row = Number(raw.end_row)
    const column = typeof raw.column === 'string' && raw.column.trim() ? raw.column.trim() : undefined
    if (Number.isSafeInteger(start_row) && start_row >= 1 && Number.isSafeInteger(end_row) && end_row >= start_row) {
      return {
        kind: 'csv_rows',
        start_row,
        end_row,
        ...(column ? { column } : {}),
        ...(object_id ? { object_id } : {})
      }
    }
    return null
  }
  if (kind === 'md_section') {
    const heading = typeof raw.heading === 'string' ? raw.heading.trim() : ''
    const level = Number(raw.level ?? 1)
    const start_line = raw.start_line != null ? Number(raw.start_line) : undefined
    if (heading && Number.isSafeInteger(level) && level >= 1 && level <= 6) {
      return {
        kind: 'md_section',
        heading,
        level,
        ...(start_line !== undefined && Number.isSafeInteger(start_line) && start_line >= 1 ? { start_line } : {}),
        ...(object_id ? { object_id } : {})
      }
    }
    return null
  }
  if (kind === 'media_timestamp') {
    const time_sec = Number(raw.time_sec)
    const end_time_sec = raw.end_time_sec != null ? Number(raw.end_time_sec) : undefined
    if (Number.isFinite(time_sec) && time_sec >= 0) {
      return {
        kind: 'media_timestamp',
        time_sec,
        ...(end_time_sec !== undefined && Number.isFinite(end_time_sec) && end_time_sec >= time_sec
          ? { end_time_sec }
          : {}),
        ...(object_id ? { object_id } : {})
      }
    }
    return null
  }
  return null
}

export function formatMediaTimestamp(seconds: number): string {
  const clamped = Math.max(0, Math.floor(seconds))
  const hours = Math.floor(clamped / 3600)
  const minutes = Math.floor((clamped % 3600) / 60)
  const secs = clamped % 60
  const mm = String(minutes).padStart(2, '0')
  const ss = String(secs).padStart(2, '0')
  return hours > 0 ? `${hours}:${mm}:${ss}` : `${mm}:${ss}`
}

export function formatFileAnchorLabel(anchor: FileCommentAnchor): string {
  switch (anchor.kind) {
    case 'lines':
      return anchor.start_line === anchor.end_line
        ? `L${anchor.start_line}`
        : `L${anchor.start_line}–L${anchor.end_line}`
    case 'csv_rows': {
      const range =
        anchor.start_row === anchor.end_row ? `Row ${anchor.start_row}` : `Rows ${anchor.start_row}–${anchor.end_row}`
      return anchor.column ? `${range} · ${anchor.column}` : range
    }
    case 'md_section':
      return `${'#'.repeat(Math.min(6, Math.max(1, anchor.level)))} ${anchor.heading}`
    case 'media_timestamp': {
      const start = formatMediaTimestamp(anchor.time_sec)
      return anchor.end_time_sec !== undefined && anchor.end_time_sec > anchor.time_sec
        ? `${start}–${formatMediaTimestamp(anchor.end_time_sec)}`
        : start
    }
  }
}

export type MarkdownSectionItem = {
  heading: string
  level: number
  start_line: number
  excerpt: string
}

export function extractMarkdownSections(markdown: string): MarkdownSectionItem[] {
  const source = markdown.replace(/\r\n?/g, '\n')
  const lines = source.split('\n')
  const headings: Heading[] = []
  const visit = (node: Nodes) => {
    if (node.type === 'heading') headings.push(node)
    if ('children' in node) for (const child of node.children) visit(child)
  }
  visit(fromMarkdown(source))

  return headings.flatMap((node, index) => {
    const first = node.children[0]?.position?.start.offset
    const last = node.children.at(-1)?.position?.end.offset
    if (first === undefined || last === undefined) return []

    const startLine = node.position!.start.line
    const nextLine = headings[index + 1]?.position?.start.line ?? lines.length + 1
    return [
      {
        heading: source.slice(first, last),
        level: node.depth,
        start_line: startLine,
        excerpt: clampCommentQuote(lines.slice(startLine - 1, Math.min(startLine + 5, nextLine - 1)).join('\n'))
      }
    ]
  })
}

export function parseDelimitedTable(
  text: string,
  delimiter: ',' | '\t' = ','
): { headers: string[]; rows: string[][] } {
  const normalized = text.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n')
  const parsed: string[][] = []
  let row: string[] = []
  let cell = ''
  let inQuotes = false

  for (let i = 0; i < normalized.length; i++) {
    const ch = normalized[i]!
    if (inQuotes) {
      if (ch === '"') {
        if (normalized[i + 1] === '"') {
          cell += '"'
          i++
        } else {
          inQuotes = false
        }
      } else {
        cell += ch
      }
    } else if (ch === '"') {
      inQuotes = true
    } else if (ch === delimiter) {
      row.push(cell)
      cell = ''
    } else if (ch === '\n') {
      row.push(cell)
      parsed.push(row)
      row = []
      cell = ''
    } else {
      cell += ch
    }
  }
  if (cell.length > 0 || row.length > 0) {
    row.push(cell)
    parsed.push(row)
  }

  while (parsed.length > 0 && parsed.at(-1)!.every(value => value === '')) {
    parsed.pop()
  }

  if (parsed.length === 0) return { headers: [], rows: [] }
  const [first, ...rest] = parsed
  return { headers: first ?? [], rows: rest }
}
