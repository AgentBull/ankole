import { describe, expect, test } from 'bun:test'
import { timeZoneCurrentTime, timeZoneOffsetLabel, timeZoneOptions } from './timezone-editor'

describe('timezone editor', () => {
  const at = new Date('2026-01-15T12:00:00Z')

  test('keeps the effective timezone first and always offers the canonical UTC zone', () => {
    const options = timeZoneOptions('en-US', 'Asia/Shanghai', at)

    expect(options[0]?.value).toBe('Asia/Shanghai')
    expect(options.some(option => option.value === 'Etc/UTC')).toBe(true)
    expect(options.find(option => option.value === 'Asia/Shanghai')?.description).toBe('UTC+08:00')
  })

  test('formats valid zones and rejects values the browser cannot interpret', () => {
    expect(timeZoneOffsetLabel('America/New_York', 'en-US', at)).toBe('UTC-05:00')
    expect(timeZoneCurrentTime('Not/A_Time_Zone', 'en-US', at)).toBeUndefined()
  })
})
