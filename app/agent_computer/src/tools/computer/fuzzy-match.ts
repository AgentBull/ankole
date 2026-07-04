/**
 * Locates where a search string sits inside a file so a patch hunk can be applied
 * there. The model gives us the text it expects to find, but that text often drifts
 * from the file in harmless ways (re-indentation, trailing whitespace, a formatter
 * run). This module finds the intended location despite that drift — while refusing
 * to guess when more than one location is plausible.
 *
 * The whole design is a single tradeoff: tolerant matching lets a slightly-stale
 * hunk still apply, but applying to the WRONG place silently corrupts a file. So
 * every path here is biased toward "no match" over "an ambiguous match": as soon as
 * a strategy finds two candidates, it returns nothing rather than picking one.
 */

/** A located span in the haystack: [start, end) char offsets, plus how it was found. */
export interface FuzzyMatch {
  end: number
  exact: boolean
  start: number
  /** Which normalization let it match (`exact`, or a strategy name). Diagnostic only. */
  strategy: string
}

export interface ScopedFuzzyMatchOptions {
  context?: string
  endOfFile?: boolean
  start?: number
}

export interface ClosestLineMatch {
  lineNumber: number
  score: number
  snippet: Array<{ lineNumber: number; text: string }>
}

/** One source line and the char offsets it occupies in the original text. */
interface LineSpan {
  end: number
  start: number
  text: string
}

// Progressively more forgiving line normalizers, tried in order from strictest to
// loosest. The earlier a strategy is, the closer its match is to the literal text, so
// the first strategy that yields exactly one match wins. Ordering matters: a stricter
// strategy that resolves to a single location should be preferred over a looser one
// that might collapse distinct lines together.
const STRATEGIES: Array<{ name: string; normalize: (line: string) => string }> = [
  // Only trailing spaces/tabs differ — the most common and safest drift.
  { name: 'trim_trailing_whitespace', normalize: line => line.replace(/[ \t]+$/g, '') },
  // Leading and trailing whitespace differ — tolerates a re-indent of the block.
  { name: 'trim_line_edges', normalize: line => line.trim() },
  // Also collapse runs of interior spaces/tabs — tolerates reflowed/reformatted spacing.
  { name: 'normalize_horizontal_whitespace', normalize: line => line.trim().replace(/[ \t]+/g, ' ') },
  // Common model/editor Unicode drift: smart quotes, dash variants, NBSPs/full-width spaces.
  { name: 'normalize_unicode_punctuation', normalize: normalizeUnicodePunctuation }
]

const SCOPED_STRATEGIES: Array<{
  acceptFirst: boolean
  name: string
  normalize: (line: string) => string
}> = [
  { acceptFirst: true, name: 'exact', normalize: line => line },
  { acceptFirst: true, name: 'trim_trailing_whitespace', normalize: line => line.replace(/[ \t]+$/g, '') },
  { acceptFirst: true, name: 'trim_line_edges', normalize: line => line.trim() },
  {
    acceptFirst: false,
    name: 'normalize_horizontal_whitespace',
    normalize: line => line.trim().replace(/[ \t]+/g, ' ')
  },
  { acceptFirst: false, name: 'normalize_unicode_punctuation', normalize: normalizeUnicodePunctuation }
]

/**
 * Finds the single location of `needle` in `haystack`, returning its char range, or
 * `undefined` when there is no match or the match is ambiguous.
 *
 * Resolution order, stopping at the first conclusive answer:
 *   1. Exact substring, and only if it occurs exactly once (a literal but repeated
 *      match is ambiguous, so it is rejected — the caller must add more context).
 *   2. Otherwise, line-window matching under each normalization strategy in turn.
 *
 * Returning `undefined` is a deliberate, safe outcome: the patch tool turns it into a
 * "did not match uniquely" error rather than editing the wrong span. Callers should
 * treat "no answer" as expected, not exceptional.
 */
export function findUniqueFuzzyMatch(haystack: string, needle: string): FuzzyMatch | undefined {
  if (!needle) return undefined
  const exact = uniqueExactMatch(haystack, needle)
  if (exact) return exact

  const haystackLines = lineSpans(haystack)
  const needleLines = splitLines(needle)
  // Can't fit, or nothing to match — bail before the window scan.
  if (needleLines.length === 0 || needleLines.length > haystackLines.length) return undefined

  for (const strategy of STRATEGIES) {
    const normalizedNeedle = needleLines.map(strategy.normalize).join('\n')
    const matches: FuzzyMatch[] = []
    // Slide a window the height of the needle down the file and compare both sides
    // under the same normalization. Offsets reported are the ORIGINAL char spans
    // (window[0].start … last.end), so the eventual replacement uses the file's real
    // text, not the normalized form.
    for (let startLine = 0; startLine <= haystackLines.length - needleLines.length; startLine++) {
      const window = haystackLines.slice(startLine, startLine + needleLines.length)
      const normalizedWindow = window.map(line => strategy.normalize(line.text)).join('\n')
      if (normalizedWindow !== normalizedNeedle) continue
      matches.push({
        start: window[0]!.start,
        end: window[window.length - 1]!.end,
        exact: false,
        strategy: strategy.name
      })
      // A second hit under this strategy already makes it ambiguous; stop scanning.
      if (matches.length > 1) break
    }
    // Exactly one hit: accept it. Two or more: this needle is ambiguous, so do NOT fall
    // through to a looser strategy (which could only be more ambiguous) — give up now.
    if (matches.length === 1) return matches[0]
    if (matches.length > 1) return undefined
  }

  return undefined
}

export function findScopedFuzzyMatch(
  haystack: string,
  needle: string,
  options: ScopedFuzzyMatchOptions = {}
): FuzzyMatch | undefined {
  const haystackLines = lineSpans(haystack)
  let startLine = lineIndexAtOffset(haystackLines, options.start ?? 0)

  if (options.context !== undefined && options.context.length > 0) {
    const contextMatch = findLineSequence(haystackLines, [options.context], startLine, false, SCOPED_STRATEGIES)
    if (!contextMatch) return undefined
    startLine = contextMatch.startLine + 1
  }

  const needleLines = splitLines(needle)
  if (needleLines.length === 0) {
    const insertionLine = options.endOfFile ? haystackLines.length : Math.min(startLine, haystackLines.length)
    const offset = insertionLine >= haystackLines.length ? haystack.length : haystackLines[insertionLine]!.start
    return { end: offset, exact: false, start: offset, strategy: 'scoped_insert' }
  }

  const match = findLineSequence(haystackLines, needleLines, startLine, options.endOfFile === true, SCOPED_STRATEGIES)
  if (!match) return undefined
  return {
    end: haystackLines[match.endLine - 1]!.end,
    exact: match.strategy === 'exact',
    start: haystackLines[match.startLine]!.start,
    strategy: match.strategy
  }
}

export function findClosestLineMatches(
  haystack: string,
  needle: string,
  options: { contextLines?: number; limit?: number; minScore?: number } = {}
): ClosestLineMatch[] {
  const anchor = splitLines(needle)
    .map(line => line.trim())
    .find(line => line.length > 0)
  if (!anchor) return []

  const contextLines = options.contextLines ?? 2
  const limit = options.limit ?? 3
  const minScore = options.minScore ?? 0.25
  const lines = splitLines(haystack)
  const normalizedAnchor = normalizeForSimilarity(anchor)
  const scored = lines
    .map((line, index) => ({
      index,
      score: lineSimilarity(normalizeForSimilarity(line), normalizedAnchor)
    }))
    .filter(match => match.score >= minScore)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .slice(0, limit)

  return scored.map(match => {
    const start = Math.max(0, match.index - contextLines)
    const end = Math.min(lines.length, match.index + contextLines + 1)
    return {
      lineNumber: match.index + 1,
      score: match.score,
      snippet: lines.slice(start, end).map((text, offset) => ({ lineNumber: start + offset + 1, text }))
    }
  })
}

/** Exact substring match, but only when it is unique; a second occurrence makes it ambiguous. */
function uniqueExactMatch(haystack: string, needle: string): FuzzyMatch | undefined {
  const start = haystack.indexOf(needle)
  if (start === -1) return undefined
  // Look for a second occurrence past the first. If one exists the match is not unique,
  // so reject it rather than silently editing the first hit.
  if (haystack.indexOf(needle, start + needle.length) !== -1) return undefined
  return { start, end: start + needle.length, exact: true, strategy: 'exact' }
}

function findLineSequence(
  haystackLines: LineSpan[],
  needleLines: string[],
  startLine: number,
  endOfFile: boolean,
  strategies: Array<{ acceptFirst: boolean; name: string; normalize: (line: string) => string }>
): { endLine: number; startLine: number; strategy: string } | undefined {
  if (needleLines.length === 0) return { endLine: startLine, startLine, strategy: 'empty' }
  if (needleLines.length > haystackLines.length) return undefined

  const maxStart = haystackLines.length - needleLines.length
  const firstStart = endOfFile ? maxStart : startLine
  if (firstStart < startLine || firstStart < 0 || firstStart > maxStart) return undefined
  const lastStart = endOfFile ? firstStart : maxStart

  for (const strategy of strategies) {
    const normalizedNeedle = needleLines.map(strategy.normalize)
    const matches: Array<{ endLine: number; startLine: number; strategy: string }> = []
    for (let candidate = firstStart; candidate <= lastStart; candidate++) {
      let matched = true
      for (let offset = 0; offset < needleLines.length; offset++) {
        if (strategy.normalize(haystackLines[candidate + offset]!.text) !== normalizedNeedle[offset]) {
          matched = false
          break
        }
      }
      if (!matched) continue
      const match = {
        endLine: candidate + needleLines.length,
        startLine: candidate,
        strategy: strategy.name
      }
      if (strategy.acceptFirst) return match
      matches.push(match)
      if (matches.length > 1) break
    }
    if (matches.length === 1) return matches[0]
    if (matches.length > 1) return undefined
  }
  return undefined
}

function lineIndexAtOffset(lines: LineSpan[], offset: number): number {
  if (lines.length === 0) return 0
  if (offset <= 0) return 0
  const index = lines.findIndex(line => offset < line.end)
  return index === -1 ? lines.length : index
}

function normalizeUnicodePunctuation(line: string): string {
  return line
    .trim()
    .replace(/[\u2010-\u2015\u2212]/g, '-')
    .replace(/[\u2018\u2019\u201A\u201B]/g, "'")
    .replace(/[\u201C\u201D\u201E\u201F]/g, '"')
    .replace(/[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g, ' ')
}

function normalizeForSimilarity(line: string): string {
  return normalizeUnicodePunctuation(line)
    .replace(/[ \t]+/g, ' ')
    .toLowerCase()
}

function lineSimilarity(line: string, needle: string): number {
  if (line.length === 0 || needle.length === 0) return 0
  if (line === needle) return 1
  if (line.includes(needle) || needle.includes(line)) {
    return Math.min(line.length, needle.length) / Math.max(line.length, needle.length)
  }
  return diceCoefficient(line, needle)
}

function diceCoefficient(left: string, right: string): number {
  const leftBigrams = bigramCounts(left)
  const rightBigrams = bigramCounts(right)
  let overlap = 0
  for (const [bigram, count] of leftBigrams) {
    overlap += Math.min(count, rightBigrams.get(bigram) ?? 0)
  }
  const total =
    Array.from(leftBigrams.values()).reduce((sum, count) => sum + count, 0) +
    Array.from(rightBigrams.values()).reduce((sum, count) => sum + count, 0)
  return total === 0 ? 0 : (2 * overlap) / total
}

function bigramCounts(value: string): Map<string, number> {
  const source = value.length < 2 ? ` ${value} ` : value
  const counts = new Map<string, number>()
  for (let index = 0; index < source.length - 1; index++) {
    const bigram = source.slice(index, index + 2)
    counts.set(bigram, (counts.get(bigram) ?? 0) + 1)
  }
  return counts
}

/**
 * Splits text into lines while recording each line's char offsets in the original.
 * The offsets are what let window matching report a span in the real file even though
 * comparison happens on normalized copies. The `+= 1` steps over the `\n` separator so
 * the next line's start is correct; the final line has no trailing separator.
 */
function lineSpans(value: string): LineSpan[] {
  const lines = splitLines(value)
  const spans: LineSpan[] = []
  let offset = 0
  for (const line of lines) {
    const start = offset
    offset += line.length
    spans.push({ start, end: offset, text: line })
    if (value[offset] === '\n') offset += 1
  }
  return spans
}

/**
 * Splits on `\n`, dropping the empty trailing element a final newline produces, so a
 * block ending in `\n` is not treated as having an extra blank line. This keeps the
 * needle's line count equal to the visible number of lines, which the window scan relies on.
 */
function splitLines(value: string): string[] {
  if (!value) return []
  const lines = value.split('\n')
  if (lines.at(-1) === '') lines.pop()
  return lines
}
