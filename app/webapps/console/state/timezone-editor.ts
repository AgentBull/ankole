export type TimeZoneOption = {
  value: string
  label: string
  description?: string
}

const UTC_TIME_ZONE = 'Etc/UTC'

export function timeZoneOptions(locale: string, current: string, at = new Date()): TimeZoneOption[] {
  const zones = new Set([UTC_TIME_ZONE, current, ...supportedTimeZones()].filter(Boolean))

  // One formatter per zone: the offset label doubles as the validity probe,
  // because `Intl.DateTimeFormat` rejects the same zones it cannot label.
  return [...zones]
    .flatMap(timeZone => {
      const description = timeZoneOffsetLabel(timeZone, locale, at)
      return description === undefined ? [] : [{ value: timeZone, label: timeZone, description }]
    })
    .sort((left, right) => {
      const priority = timeZonePriority(left.value, current) - timeZonePriority(right.value, current)
      return priority || left.value.localeCompare(right.value)
    })
}

export function timeZoneOffsetLabel(timeZone: string, locale: string, at = new Date()): string | undefined {
  try {
    const name = new Intl.DateTimeFormat(locale, { timeZone, timeZoneName: 'longOffset' })
      .formatToParts(at)
      .find(part => part.type === 'timeZoneName')?.value

    return name?.replace(/^GMT/, 'UTC')
  } catch {
    return undefined
  }
}

export function timeZoneCurrentTime(timeZone: string, locale: string, at = new Date()): string | undefined {
  try {
    return new Intl.DateTimeFormat(locale, {
      timeZone,
      dateStyle: 'medium',
      timeStyle: 'long'
    }).format(at)
  } catch {
    return undefined
  }
}

function supportedTimeZones(): string[] {
  try {
    return Intl.supportedValuesOf('timeZone')
  } catch {
    return []
  }
}

function timeZonePriority(timeZone: string, current: string): number {
  if (timeZone === current) return 0
  if (timeZone === UTC_TIME_ZONE) return 1
  return 2
}
