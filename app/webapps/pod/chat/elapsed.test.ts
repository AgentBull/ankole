import { describe, expect, test } from 'bun:test'
import { formatElapsed } from './elapsed'

describe('formatElapsed', () => {
  test('counts seconds to one decimal under a minute', () => {
    expect(formatElapsed(0, 'en-US')).toBe('0.0s')
    expect(formatElapsed(999, 'en-US')).toBe('1.0s')
    expect(formatElapsed(30_000, 'en-US')).toBe('30.0s')
  })

  test('counts minutes and seconds under an hour', () => {
    expect(formatElapsed(61_000, 'en-US')).toBe('1m 1s')
    expect(formatElapsed(3_481_000, 'en-US')).toBe('58m 1s')
  })

  test('counts hours and minutes past an hour', () => {
    expect(formatElapsed(11_532_000, 'en-US')).toBe('3h 12m')
    expect(formatElapsed(11_532_000, 'zh-Hans-CN')).toBe('3小时 12分钟')
  })

  test('treats a negative duration as zero', () => {
    expect(formatElapsed(-5, 'en-US')).toBe('0.0s')
  })
})
