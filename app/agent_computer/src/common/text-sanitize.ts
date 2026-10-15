const utf8Encoder = new TextEncoder()

/** Format characters include bidi overrides that can hide tool output from a reviewer. */
export function sanitizeBinaryOutput(text: string): string {
  const scrubbed = text.replace(/[\p{Format}\p{Surrogate}]/gu, '')
  if (!scrubbed) return scrubbed
  const chunks: string[] = []
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

export function truncateUtf16Safe(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text
  if (maxChars <= 0) return ''
  let end = maxChars
  const previous = text.charCodeAt(end - 1)
  const next = text.charCodeAt(end)
  if (previous >= 0xd800 && previous <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) end--
  return text.slice(0, end)
}

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
