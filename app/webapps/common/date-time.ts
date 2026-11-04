import i18n from './i18n'

/** Format timestamps in the interface language, using the browser's local timezone. */
export function formatDateTime(
  value?: string | null,
  locale = i18n.language,
  timeStyle: 'short' | 'medium' = 'short'
): string {
  if (!value?.trim()) return '—'
  const date = new Date(value)
  if (!Number.isFinite(date.getTime())) return value
  return new Intl.DateTimeFormat(locale || 'en-US', { dateStyle: 'medium', timeStyle }).format(date)
}

export function formatRelativeTime(iso: string | null | undefined, locale?: string): string {
  if (!iso) return ''
  const time = Date.parse(iso)
  if (Number.isNaN(time)) return ''
  const now = Date.now()
  const diffSeconds = Math.round((time - now) / 1000)
  const absSeconds = Math.abs(diffSeconds)
  try {
    const rtf = new Intl.RelativeTimeFormat(locale || undefined, { numeric: 'auto' })
    if (absSeconds < 60) return rtf.format(0, 'minute')
    if (absSeconds < 3600) return rtf.format(Math.round(diffSeconds / 60), 'minute')
    if (absSeconds < 86400) return rtf.format(Math.round(diffSeconds / 3600), 'hour')
    if (absSeconds < 7 * 86400) return rtf.format(Math.round(diffSeconds / 86400), 'day')
    const date = new Date(time)
    const sameYear = date.getFullYear() === new Date(now).getFullYear()
    return new Intl.DateTimeFormat(locale || undefined, {
      ...(sameYear ? {} : { year: 'numeric' }),
      month: 'short',
      day: 'numeric'
    }).format(date)
  } catch {
    return new Date(time).toLocaleDateString()
  }
}

// The field is a `datetime-local` control, so the draft holds the instant as
// the browser's local wall-clock time without an offset. The control plane
// stores a UTC instant; the two conversions below invert each other at second
// precision.
const dateTimeLocalPattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?$/

/** Formats a stored UTC instant as the local `datetime-local` value. */
export function dateTimeLocalValue(instant: string): string {
  const date = new Date(instant)
  if (Number.isNaN(date.getTime())) return ''
  const pad = (value: number) => String(value).padStart(2, '0')
  const day = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
  return `${day}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
}

/** Parses a local `datetime-local` value into a UTC ISO 8601 instant. */
export function instantFromDateTimeLocal(value: string): string | undefined {
  const text = value.trim()
  if (!dateTimeLocalPattern.test(text)) return undefined
  const date = new Date(text)
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString()
}
