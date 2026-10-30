// Agent work lasts from a fraction of a second to many hours, so a duration counts in the two largest units
// that still show progress, in the reader's own unit words.
export function formatElapsed(ms: number, locale: string) {
  const unit = (name: 'second' | 'minute' | 'hour', value: number, digits = 0) =>
    new Intl.NumberFormat(locale, {
      style: 'unit',
      unit: name,
      unitDisplay: 'narrow',
      minimumFractionDigits: digits,
      maximumFractionDigits: digits
    }).format(value)
  const seconds = Math.floor(Math.max(0, ms) / 1000)
  if (seconds < 60) return unit('second', Math.max(0, ms) / 1000, 1)
  if (seconds < 3_600) return `${unit('minute', Math.floor(seconds / 60))} ${unit('second', seconds % 60)}`
  return `${unit('hour', Math.floor(seconds / 3_600))} ${unit('minute', Math.floor((seconds % 3_600) / 60))}`
}
