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
