/**
 * Formula editing in the spreadsheet editor: the references a formula names, the function call
 * around the caret, the function name being typed, where a clicked cell goes, and F4.
 *
 * Every function here reads the formula text as typed, so the cell editor and the formula bar
 * answer while the author types, without a round trip to the worker. Text inside string literals
 * never counts as a reference or a call.
 */
import { columnName, parseRange, type Rect } from './spreadsheet-grid'

export type FormulaReference = {
  /** Offsets of the reference text, `sheet!` prefix included. */
  start: number
  end: number
  /** The sheet the reference names, or `undefined` for the formula's own sheet. */
  sheet?: string
  rect: Rect
}

export type FunctionCall = { name: string; argument: number; start: number }

const SHEET = String.raw`(?:'(?:[^']|'')+'|[\p{L}_][\p{L}\p{N}_.]*)!`
const CELL = String.raw`\$?[A-Za-z]{1,3}\$?\d{1,7}`
const BODY = String.raw`${CELL}(?::${CELL})?|\$?[A-Za-z]{1,3}:\$?[A-Za-z]{1,3}|\$?\d{1,7}:\$?\d{1,7}`
const REFERENCE = new RegExp(String.raw`(?<![\p{L}\p{N}_.$'!])(${SHEET})?(${BODY})(?![\p{L}\p{N}_(!])`, 'gu')
const NAME = /[\p{L}_][\p{L}\p{N}_.]*$/u
/** Characters after which an operand starts, so a name or a clicked reference may follow. */
const OPERAND_START = new Set(['=', '(', ',', ';', '+', '-', '*', '/', '^', '&', '<', '>', ':', '%'])

export function isFormula(text: string): boolean {
  return text.startsWith('=')
}

/** The text with every string literal blanked out, so offsets stay put and literals never match. */
function withoutStrings(text: string): string {
  return text.replace(/"(?:[^"]|"")*"?/g, literal => ' '.repeat(literal.length))
}

/** Whether `offset` lies inside a string literal (or an unterminated one). */
function insideString(text: string, offset: number): boolean {
  let open = false
  for (let index = 0; index < offset; index++) if (text[index] === '"') open = !open
  return open
}

/** The cell and range references of a formula, in order. */
export function formulaReferences(text: string): FormulaReference[] {
  if (!isFormula(text)) return []
  const references: FormulaReference[] = []
  for (const match of withoutStrings(text).matchAll(REFERENCE)) {
    const rect = parseRange(match[2]!.replaceAll('$', ''))
    if (!rect) continue
    const prefix = match[1]
    const sheet = prefix
      ? prefix
          .slice(0, -1)
          .replace(/^'(.*)'$/s, '$1')
          .replaceAll("''", "'")
      : undefined
    references.push({ start: match.index, end: match.index + match[0].length, sheet, rect })
  }
  return references
}

/** The innermost named function call that the caret sits in, and which argument it is on. */
export function functionContext(text: string, caret: number): FunctionCall | undefined {
  if (!isFormula(text)) return undefined
  const source = withoutStrings(text.slice(0, caret))
  const stack: FunctionCall[] = []
  for (let index = 0; index < source.length; index++) {
    const char = source[index]
    if (char === '(') {
      const name = NAME.exec(source.slice(0, index))?.[0] ?? ''
      stack.push({ name: name.toUpperCase(), argument: 0, start: index - name.length })
    } else if (char === '{') stack.push({ name: '', argument: 0, start: index })
    else if (char === ')' || char === '}') stack.pop()
    else if (char === ',' && stack.length) stack.at(-1)!.argument++
  }
  return stack.findLast(call => call.name !== '')
}

/** Whether an operand may start at `offset`: right after `=`, an opening parenthesis, a separator, or an operator. */
function operandStarts(text: string, offset: number): boolean {
  const before = text.slice(0, offset).trimEnd()
  return OPERAND_START.has(before.at(-1) ?? '')
}

/** The function name the author is typing at the caret, for suggestions. */
export function namePrefix(text: string, caret: number): { start: number; prefix: string } | undefined {
  if (!isFormula(text) || insideString(text, caret)) return undefined
  const match = NAME.exec(text.slice(0, caret))
  if (!match || !operandStarts(text, match.index)) return undefined
  if (/^[\p{L}\p{N}_.(]/u.test(text.slice(caret))) return undefined
  return { start: match.index, prefix: match[0] }
}

/** Whether clicking a cell while the caret is at `caret` inserts that cell's reference. */
export function acceptsReference(text: string, caret: number): boolean {
  return isFormula(text) && !insideString(text, caret) && operandStarts(text, caret)
}

/** A reference as a formula writes it: `B2`, `B2:D5`, or with a quoted sheet name when needed. */
export function referenceText(rect: Rect, sheet?: string): string {
  const single = rect.r0 === rect.r1 && rect.c0 === rect.c1
  const cell = (row: number, col: number) => `${columnName(col)}${row + 1}`
  const body = single ? cell(rect.r0, rect.c0) : `${cell(rect.r0, rect.c0)}:${cell(rect.r1, rect.c1)}`
  if (sheet === undefined) return body
  const plain = /^[\p{L}_][\p{L}\p{N}_.]*$/u.test(sheet) && !/^[A-Za-z]{1,3}\d+$/.test(sheet)
  return `${plain ? sheet : `'${sheet.replaceAll("'", "''")}'`}!${body}`
}

/** Replaces `text[start..end]` with `insert` and puts the caret after it. */
export function splice(text: string, start: number, end: number, insert: string): { text: string; caret: number } {
  return { text: text.slice(0, start) + insert + text.slice(end), caret: start + insert.length }
}

/**
 * F4: cycles the reference at the caret through `A1`, `$A$1`, `A$1`, and `$A1`. A range takes the
 * next form of its first cell for both ends.
 */
export function toggleAbsolute(text: string, caret: number): { text: string; caret: number } | undefined {
  const reference = formulaReferences(text).find(found => found.start <= caret && caret <= found.end)
  if (!reference) return undefined
  const raw = text.slice(reference.start, reference.end)
  const bang = raw.lastIndexOf('!')
  const prefix = raw.slice(0, bang + 1)
  const parts = raw.slice(bang + 1).split(':')
  const first = /^(\$?)([A-Za-z]*)(\$?)(\d*)$/.exec(parts[0]!)
  if (!first) return undefined
  const state = `${first[1]}|${first[3]}`
  const next = { '|': ['$', '$'], '$|$': ['', '$'], '|$': ['$', ''], '$|': ['', ''] }[state] ?? ['', '']
  const toggled = parts.map(part => {
    const match = /^\$?([A-Za-z]*)\$?(\d*)$/.exec(part)
    if (!match) return part
    const [, letters = '', digits = ''] = match
    return `${letters ? next[0] + letters : ''}${digits ? next[1] + digits : ''}`
  })
  return splice(text, reference.start, reference.end, prefix + toggled.join(':'))
}

/** Functions whose names start with `prefix`, the common ones first, at most `limit` of them. */
export function suggestFunctions<T extends { name: string }>(functions: readonly T[], prefix: string, limit = 8): T[] {
  const wanted = prefix.toUpperCase()
  const rank = (name: string) => {
    const common = COMMON_FUNCTIONS.indexOf(name)
    return common === -1 ? COMMON_FUNCTIONS.length : common
  }
  return functions
    .filter(fn => fn.name.startsWith(wanted))
    .sort((a, b) => rank(a.name) - rank(b.name) || a.name.localeCompare(b.name))
    .slice(0, limit)
}

/**
 * The functions an author reaches for most, in the order suggestions list them. The function list
 * shows them as their own category, with translated descriptions.
 */
export const COMMON_FUNCTIONS = [
  'SUM',
  'AVERAGE',
  'COUNT',
  'COUNTA',
  'MAX',
  'MIN',
  'IF',
  'IFS',
  'IFERROR',
  'AND',
  'OR',
  'SUMIF',
  'SUMIFS',
  'COUNTIF',
  'COUNTIFS',
  'AVERAGEIF',
  'VLOOKUP',
  'XLOOKUP',
  'INDEX',
  'MATCH',
  'ROUND',
  'ABS',
  'TODAY',
  'NOW',
  'DATE',
  'YEAR',
  'MONTH',
  'DAY',
  'TEXT',
  'LEFT',
  'RIGHT',
  'MID',
  'LEN',
  'CONCAT',
  'TEXTJOIN',
  'TRIM',
  'SUBSTITUTE',
  'UNIQUE',
  'FILTER',
  'SORT',
  'RANK'
]
