export type TimeZoneOption = {
  value: string
  label: string
  description?: string
}

const UTC_TIME_ZONE = 'Etc/UTC'

export function timeZoneOptions(locale: string, current: string, at = new Date()): TimeZoneOption[] {
  const zones = new Set([UTC_TIME_ZONE, current, ...supportedTimeZones()].filter(Boolean))

  return [...zones]
    .filter(timeZone => timeZoneCurrentTime(timeZone, locale, at) !== undefined)
    .map(timeZone => ({
      value: timeZone,
      label: timeZone,
      description: timeZoneOffsetLabel(timeZone, locale, at)
    }))
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
