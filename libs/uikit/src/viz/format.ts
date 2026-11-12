/** Parses a finite number from a numeric value or a numeric string, otherwise `null`. */
export function toFiniteNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value)
    if (Number.isFinite(parsed)) return parsed
  }
  return null
}

/** Formats a raw metric with the shared fallback rules: number, string, or an em dash. */
export function formatFallbackNumeric(raw: unknown): string {
  const num = toFiniteNumber(raw)
  if (num !== null) {
    return new Intl.NumberFormat(undefined, { maximumFractionDigits: 4 }).format(num)
  }
  if (raw === null || raw === undefined || raw === '') return '—'
  return String(raw)
}
