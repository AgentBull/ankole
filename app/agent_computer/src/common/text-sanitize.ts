const utf8Encoder = new TextEncoder()

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
 * Renders third-party catalog text as one bounded, prompt-safe line.
 *
 * Catalog entries (skill descriptions, plugin template descriptions) come from
 * installed third-party packages and are injected into model-visible prompts.
 * The producer is asked to keep them short and plain, but the host does not
 * trust that: this strips hidden and control characters through
 * `sanitizeBinaryOutput`, collapses all whitespace to single spaces, and caps
 * the length so one oversized entry cannot starve the rest of its catalog.
 */
export function sanitizeCatalogLine(text: string, maxChars: number): string {
  const cleaned = sanitizeBinaryOutput(text).replace(/\s+/g, ' ').trim()
  return truncateUtf16Safe(cleaned, maxChars)
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

/**
 * Keeps at most `maxChars` UTF-16 code units from the end of the text without
 * slicing through a surrogate pair.
 *
 * The tail counterpart of `truncateUtf16Safe`. A cut that lands between the two
 * halves of an astral character leaves a lone low surrogate at the front of the
 * result, which renders as a replacement glyph, so the orphan half is dropped.
 */
export function truncateUtf16SafeTail(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text
  if (maxChars <= 0) return ''
  const start = text.length - maxChars
  const first = text.charCodeAt(start)
  return first >= 0xdc00 && first <= 0xdfff ? text.slice(start + 1) : text.slice(start)
}

/** Returns the UTF-8 byte length used by JSON-RPC and durable text payloads. */
export function utf8ByteLength(text: string): number {
  return utf8Encoder.encode(text).byteLength
}

/** Truncates to the largest UTF-16-safe prefix whose UTF-8 encoding fits. */
export function truncateUTF8Safe(text: string, maxBytes: number): string {
  if (maxBytes <= 0) return ''
  if (utf8ByteLength(text) <= maxBytes) return text

  let low = 0
  let high = text.length
  let best = ''

  while (low <= high) {
    const middle = Math.floor((low + high) / 2)
    const candidate = truncateUtf16Safe(text, middle)
    if (utf8ByteLength(candidate) <= maxBytes) {
      best = candidate
      low = middle + 1
    } else {
      high = middle - 1
    }
  }

  return best
}
