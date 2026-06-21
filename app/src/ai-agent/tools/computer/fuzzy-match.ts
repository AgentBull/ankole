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
  { name: 'normalize_horizontal_whitespace', normalize: line => line.trim().replace(/[ \t]+/g, ' ') }
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
  // Single-line needles get no fuzzy fallback: one short line normalizes to something
  // that recurs all over a file, so whitespace-tolerant matching would be far too
  // likely to land on the wrong line. Fuzzy matching is reserved for multi-line blocks,
  // whose combined context makes a unique location realistic.
  if (!needle.includes('\n')) return undefined

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

/** Exact substring match, but only when it is unique; a second occurrence makes it ambiguous. */
function uniqueExactMatch(haystack: string, needle: string): FuzzyMatch | undefined {
  const start = haystack.indexOf(needle)
  if (start === -1) return undefined
  // Look for a second occurrence past the first. If one exists the match is not unique,
  // so reject it rather than silently editing the first hit.
  if (haystack.indexOf(needle, start + needle.length) !== -1) return undefined
  return { start, end: start + needle.length, exact: true, strategy: 'exact' }
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
