function isEscapedAt(text: string, index: number): boolean {
  let slashes = 0
  while (index - 1 - slashes >= 0 && text[index - 1 - slashes] === '\\') slashes++
  return slashes % 2 === 1
}

function hasUnescapedDollar(text: string): boolean {
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '$' && !isEscapedAt(text, i)) return true
  }
  return false
}

function hasUnescapedSequence(text: string, sequence: string): boolean {
  for (let index = text.indexOf(sequence); index !== -1; index = text.indexOf(sequence, index + 1)) {
    if (!isEscapedAt(text, index)) return true
  }
  return false
}

/**
 * Strip outer math-mode delimiters (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`) when a writer or pasted
 * snippet wraps a single non-empty formula in them. Leaves multiple formulas (`$a$ + $b$`),
 * lone delimiters (`$`), and unclosed delimiters untouched so real syntax errors remain visible.
 */
export function unwrapMathDelimiters(source: string): string {
  const trimmed = source.trim()
  if (
    trimmed.length > 4 &&
    trimmed.startsWith('$$') &&
    !trimmed.startsWith('$$$') &&
    trimmed.endsWith('$$') &&
    !isEscapedAt(trimmed, trimmed.length - 2)
  ) {
    const inner = trimmed.slice(2, -2).trim()
    if (inner.length > 0 && !hasUnescapedDollar(inner)) return inner
  }
  if (
    trimmed.length > 2 &&
    trimmed.startsWith('$') &&
    !trimmed.startsWith('$$') &&
    trimmed.endsWith('$') &&
    !isEscapedAt(trimmed, trimmed.length - 1)
  ) {
    const inner = trimmed.slice(1, -1).trim()
    if (inner.length > 0 && !hasUnescapedDollar(inner)) return inner
  }
  if (
    trimmed.length > 4 &&
    trimmed.startsWith('\\(') &&
    trimmed.endsWith('\\)') &&
    !isEscapedAt(trimmed, trimmed.length - 2)
  ) {
    const inner = trimmed.slice(2, -2).trim()
    if (inner.length > 0 && !hasUnescapedSequence(inner, '\\(') && !hasUnescapedSequence(inner, '\\)')) return inner
  }
  if (
    trimmed.length > 4 &&
    trimmed.startsWith('\\[') &&
    trimmed.endsWith('\\]') &&
    !isEscapedAt(trimmed, trimmed.length - 2)
  ) {
    const inner = trimmed.slice(2, -2).trim()
    if (inner.length > 0 && !hasUnescapedSequence(inner, '\\[') && !hasUnescapedSequence(inner, '\\]')) return inner
  }
  return source
}
