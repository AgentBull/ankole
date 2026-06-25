/**
 * Strips characters that make tool/command output unsafe to store and re-display,
 * while leaving ordinary text intact.
 *
 * Two classes are removed. First, Unicode `Format` and `Surrogate` code points:
 * these include zero-width joiners, bidi-override marks, and lone surrogates that
 * can corrupt rendering or be used to hide content from a human reviewer. Second,
 * C0 control characters (below U+0020) — except the three layout-significant ones,
 * tab / line feed / carriage return, which are preserved so multi-line output
 * stays readable.
 *
 * The name reflects the intent: this is for output that may contain stray binary
 * bytes, not for normalizing well-formed prose.
 */
export function sanitizeBinaryOutput(text: string): string {
  const scrubbed = text.replace(/[\p{Format}\p{Surrogate}]/gu, '')
  if (!scrubbed) return scrubbed
  const chunks: string[] = []
  // Iterating with for..of walks by code point, so multi-unit characters are not
  // split; `codePointAt(0)` then yields the full code point for the range checks.
  for (const char of scrubbed) {
    const code = char.codePointAt(0)
    if (code === undefined) continue
    if (code === 0x09 || code === 0x0a || code === 0x0d) {
      chunks.push(char)
      continue
    }
    if (code < 0x20) continue
    chunks.push(char)
  }
  return chunks.join('')
}

/**
 * Truncates to at most `maxChars` UTF-16 code units without slicing through a
 * surrogate pair.
 *
 * A naive `slice(0, maxChars)` can land between the high and low halves of an
 * astral character (emoji, rare CJK), leaving a lone surrogate that renders as a
 * replacement glyph and is invalid when re-encoded. When the cut would fall on
 * that boundary, this backs the cut off by one unit so the whole character is
 * dropped rather than half-kept. `maxChars` is measured in code units (matching
 * `String.length`), not user-perceived characters.
 */
export function truncateUtf16Safe(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text
  if (maxChars <= 0) return ''
  let end = maxChars
  const previous = text.charCodeAt(end - 1)
  const next = text.charCodeAt(end)
  // High surrogate immediately followed by its low surrogate means the cut is mid
  // pair: step back one so the split character is excluded entirely.
  if (previous >= 0xd800 && previous <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) end--
  return text.slice(0, end)
}
