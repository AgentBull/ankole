/**
 * Renders instants in the installation timezone for model-visible text.
 *
 * The Worker system clock runs in UTC, so every prompt surface that shows a
 * wall clock converts it here instead of printing a UTC instant beside a
 * timezone label it was not formatted in. Intl is used so DST and historical
 * timezone changes are not approximated.
 */

export type ZonedDateTimeParts = {
  year: string
  month: string
  day: string
  hour: string
  minute: string
}

/** An instant and the timezone it was rendered in, which always agree. */
export type LabeledZonedDateTime = {
  /** `YYYY-MM-DD HH:MM`. */
  text: string
  timezone: string
}

/**
 * Formats an instant to minute precision as `YYYY-MM-DD HH:MM`.
 */
export function formatZonedDateTime(value: Date | string, timezone: string): string | undefined {
  const parts = zonedDateTimeParts(value, timezone)
  return parts ? `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}` : undefined
}

/**
 * Formats the calendar date of an instant as `YYYY-MM-DD`.
 */
export function formatZonedDate(value: Date | string, timezone: string): string | undefined {
  const parts = zonedDateTimeParts(value, timezone)
  return parts ? `${parts.year}-${parts.month}-${parts.day}` : undefined
}

/**
 * Renders an instant together with the timezone it was rendered in.
 *
 * A caller that prints the timezone beside the clock must print this timezone,
 * not the stored one: an absent or unusable timezone degrades the clock and
 * the label together to UTC, so the label always matches the clock.
 */
export function labeledZonedDateTime(
  value: Date | string,
  timezone: string | null | undefined
): LabeledZonedDateTime | undefined {
  const zone = timezone?.trim() || 'UTC'
  const text = formatZonedDateTime(value, zone)
  if (text) return { text, timezone: zone }

  const utc = formatZonedDateTime(value, 'UTC')
  return utc ? { text: utc, timezone: 'UTC' } : undefined
}

/**
 * Splits an instant into zoned calendar fields.
 *
 * An unparsable value or a timezone Intl rejects yields undefined; each caller
 * owns the fallback text its surface needs.
 */
export function zonedDateTimeParts(value: Date | string, timezone: string): ZonedDateTimeParts | undefined {
  const at = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(at.getTime())) return undefined

  try {
    const parts = new Intl.DateTimeFormat('en-CA', {
      timeZone: timezone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23'
    }).formatToParts(at)

    const part = (type: string) => parts.find(item => item.type === type)?.value ?? '00'
    return {
      year: part('year'),
      month: part('month'),
      day: part('day'),
      hour: part('hour'),
      minute: part('minute')
    }
  } catch {
    return undefined
  }
}
