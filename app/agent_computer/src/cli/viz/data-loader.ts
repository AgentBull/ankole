import { isRecord } from '@agentbull/active-support'
import { readFile } from 'node:fs/promises'
import { extname, resolve } from 'node:path'

const ISO_DATE_OR_PERIOD_RE = /^(?:\d{4}-\d{2}-\d{2}(?:[T\s].*)?|\d{4}-\d{2}|\d{4}-Q[1-4]|\d{4}-W\d{2})$/i
const LEADING_ZERO_CODE_RE = /^-?0\d/
const NUMERIC_LITERAL_RE = /^-?\d+(?:\.\d+)?$/

/**
 * Coerces a trimmed CSV/TSV cell to a finite JavaScript number when appropriate while
 * preserving ISO date/period strings (`YYYY-MM-DD`, `YYYY-MM`, `YYYY-QN`) and
 * leading-zero security/category codes (`000001`, `00700`) as strings.
 */
export function coerceTabularCell(raw: string): string | number {
  const trimmed = raw.trim()
  if (trimmed === '') return ''
  if (ISO_DATE_OR_PERIOD_RE.test(trimmed)) return trimmed
  if (LEADING_ZERO_CODE_RE.test(trimmed)) return trimmed
  if (NUMERIC_LITERAL_RE.test(trimmed)) {
    const parsed = Number(trimmed)
    if (!Number.isFinite(parsed)) return trimmed
    if (!trimmed.includes('.') && !Number.isSafeInteger(parsed)) return trimmed
    return Object.is(parsed, -0) ? 0 : parsed
  }
  return trimmed
}

/**
 * Parses RFC-4180 CSV or TSV text (supporting quoted fields, embedded newlines/delimiters,
 * and escaped `""` quotes) into an array of row objects keyed by header names.
 */
export function parseDelimitedRecords(text: string, delimiter: ',' | '\t'): Record<string, string | number>[] {
  const clean = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text
  const rows: string[][] = []
  let currentRow: string[] = []
  let currentCell = ''
  let inQuotes = false

  for (let i = 0; i < clean.length; i += 1) {
    const ch = clean[i]!
    if (inQuotes) {
      if (ch === '"') {
        if (clean[i + 1] === '"') {
          currentCell += '"'
          i += 1
        } else {
          inQuotes = false
        }
      } else {
        currentCell += ch
      }
      continue
    }

    if (ch === '"' && currentCell === '') {
      inQuotes = true
      continue
    }

    if (ch === delimiter) {
      currentRow.push(currentCell)
      currentCell = ''
      continue
    }

    if (ch === '\r' || ch === '\n') {
      if (ch === '\r' && clean[i + 1] === '\n') {
        i += 1
      }
      currentRow.push(currentCell)
      currentCell = ''
      if (currentRow.length > 1 || currentRow[0]?.trim() !== '') {
        rows.push(currentRow)
      }
      currentRow = []
      continue
    }

    currentCell += ch
  }

  if (inQuotes) {
    throw new Error('Unterminated quoted field in delimited data file.')
  }

  if (currentCell !== '' || currentRow.length > 0) {
    currentRow.push(currentCell)
    if (currentRow.length > 1 || currentRow[0]?.trim() !== '') {
      rows.push(currentRow)
    }
  }

  if (rows.length === 0) return []
  const headers = rows[0]!.map(h => h.trim())
  if (headers.every(h => h === '')) return []

  const records: Record<string, string | number>[] = []
  for (let rowIndex = 1; rowIndex < rows.length; rowIndex += 1) {
    const values = rows[rowIndex]!
    if (values.every(v => v.trim() === '')) continue
    const record: Record<string, string | number> = {}
    for (let colIndex = 0; colIndex < headers.length; colIndex += 1) {
      const key = headers[colIndex]!
      if (!key) continue
      record[key] = coerceTabularCell(values[colIndex] ?? '')
    }
    records.push(record)
  }
  return records
}

function parseJsonLines(text: string, sourceLabel: string): unknown[] {
  const clean = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text
  const items: unknown[] = []
  const lines = clean.split(/\r?\n/)
  for (let idx = 0; idx < lines.length; idx += 1) {
    const trimmed = lines[idx]!.trim()
    if (!trimmed) continue
    try {
      items.push(JSON.parse(trimmed))
    } catch (error) {
      throw new Error(
        `Invalid JSONL at ${sourceLabel}:${idx + 1}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  }
  return items
}

/**
 * Loads tabular or graph data from `.csv`, `.tsv`, `.json`, or `.jsonl` on disk.
 */
export async function loadDataFile(dataPath: string, cwd = process.cwd()): Promise<unknown> {
  const resolvedPath = resolve(cwd, dataPath)
  const raw = await readFile(resolvedPath, 'utf8')
  const ext = extname(resolvedPath).toLowerCase()

  if (ext === '.csv') {
    return parseDelimitedRecords(raw, ',')
  }
  if (ext === '.tsv' || ext === '.tab') {
    return parseDelimitedRecords(raw, '\t')
  }
  if (ext === '.jsonl' || ext === '.ndjson') {
    return parseJsonLines(raw, dataPath)
  }
  if (ext === '.json') {
    try {
      return JSON.parse(raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw)
    } catch (error) {
      throw new Error(`Invalid JSON in ${dataPath}: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  const trimmed = raw.trim()
  if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
    try {
      return JSON.parse(trimmed)
    } catch {
      return parseJsonLines(raw, dataPath)
    }
  }
  const firstLine = trimmed.split(/\r?\n/, 1)[0] ?? ''
  return parseDelimitedRecords(raw, firstLine.includes('\t') ? '\t' : ',')
}

/**
 * Injects loaded `--data` records or topology structures into a visualization spec object.
 */
export function injectDataIntoSpec(
  kind: 'chart' | 'kline' | 'graph',
  spec: Record<string, unknown>,
  loaded: unknown
): Record<string, unknown> {
  if (kind === 'graph') {
    if (isRecord(loaded)) {
      return {
        ...spec,
        ...(Array.isArray(loaded.nodes) ? { nodes: loaded.nodes } : {}),
        ...(Array.isArray(loaded.edges) ? { edges: loaded.edges } : {}),
        ...(Array.isArray(loaded.combos) ? { combos: loaded.combos } : {})
      }
    }
    if (Array.isArray(loaded)) {
      return { ...spec, nodes: loaded }
    }
    return spec
  }

  if (kind === 'kline' && isRecord(loaded)) {
    const bars = Array.isArray(loaded.data) ? loaded.data : Array.isArray(loaded.bars) ? loaded.bars : undefined
    return {
      ...spec,
      ...(bars ? { data: bars } : {}),
      ...(Array.isArray(loaded.volume) && !Array.isArray(spec.volume) ? { volume: loaded.volume } : {})
    }
  }

  if (isRecord(loaded) && Array.isArray(loaded.data) && !('children' in loaded) && !('links' in loaded)) {
    return { ...spec, data: loaded.data }
  }

  return { ...spec, data: loaded }
}
