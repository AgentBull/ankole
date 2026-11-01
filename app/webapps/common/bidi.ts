const BIDI_CODEPOINTS_RE = /[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/gu
const CONTROL_OR_LINE_SEPARATOR_RE = /[\p{Cc}\u2028\u2029]/gu
const UNSAFE_FILENAME_RUN_RE = /[\p{Cc}\u2028\u2029/\\]+/gu

/** Returns true when `value` contains any Unicode bidirectional override, embedding, mark, or isolate codepoint. */
export function containsBidi(value: string | null | undefined): boolean {
  if (!value) return false
  BIDI_CODEPOINTS_RE.lastIndex = 0
  return BIDI_CODEPOINTS_RE.test(value)
}

/** Normalizes `value` to NFC and strips all Unicode bidirectional control codepoints while preserving `U+200D` ZWJ. */
export function stripBidi(value: string | null | undefined): string {
  if (!value) return ''
  return value.normalize('NFC').replace(BIDI_CODEPOINTS_RE, '')
}

/** Produces a clean single-line rename prefill free of Bidi overrides and control characters. */
export function sanitizeRenameValue(value: string | null | undefined): string {
  if (!value) return ''
  return stripBidi(value).replace(CONTROL_OR_LINE_SEPARATOR_RE, ' ').trim()
}

/** Sanitizes an untrusted filename into a safe single path segment matching `Ankole.Files.Path.file_name/1`. */
export function sanitizeFileName(value: string | null | undefined): string {
  if (!value) return 'file'
  const cleaned = stripBidi(value).replace(UNSAFE_FILENAME_RUN_RE, '_').trim()
  if (cleaned === '' || cleaned === '.' || cleaned === '..') return 'file'
  const encoder = new TextEncoder()
  if (encoder.encode(cleaned).length <= 255) return cleaned
  let acc = ''
  for (const ch of cleaned) {
    if (encoder.encode(acc + ch).length > 255) break
    acc += ch
  }
  return acc === '' || acc === '.' || acc === '..' ? 'file' : acc
}
