import { describe, expect, it } from 'bun:test'
import { isValidCronExpression, nextCronFire, zonedLocalTimeToUtcMs } from '../../index.js'

describe('nextCronFire', () => {
  it('computes daily 9am in the installation timezone', () => {
    const after = Date.parse('2026-06-08T00:30:00.000Z')
    expect(nextCronFire('0 9 * * *', after, 'Asia/Shanghai')).toBe(Date.parse('2026-06-08T01:00:00.000Z'))
  })

  it('supports six-field expressions with seconds', () => {
    const after = Date.parse('2026-06-08T00:00:00.000Z')
    expect(nextCronFire('30 0 9 * * *', after, 'Asia/Shanghai')).toBe(Date.parse('2026-06-08T01:00:30.000Z'))
  })

  it('is strictly after the reference time', () => {
    const fire = Date.parse('2026-06-08T01:00:00.000Z')
    expect(nextCronFire('0 9 * * *', fire, 'Asia/Shanghai')).toBe(Date.parse('2026-06-09T01:00:00.000Z'))
  })

  it('keeps a daily 9am schedule at 9am local across a DST spring-forward', () => {
    // US DST began 2026-03-08 02:00 America/New_York (UTC-5 -> UTC-4).
    const before = Date.parse('2026-03-07T15:00:00.000Z') // 10:00 EST
    const first = nextCronFire('0 9 * * *', before, 'America/New_York')!
    expect(new Date(first).toISOString()).toBe('2026-03-08T13:00:00.000Z') // 09:00 EDT, not 14:00Z
    const second = nextCronFire('0 9 * * *', first, 'America/New_York')!
    expect(new Date(second).toISOString()).toBe('2026-03-09T13:00:00.000Z')
  })

  it('rejects invalid expressions', () => {
    expect(() => nextCronFire('not a cron', 0, 'UTC')).toThrow()
    expect(isValidCronExpression('not a cron')).toBe(false)
    expect(isValidCronExpression('*/5 * * * *')).toBe(true)
  })
})

describe('zonedLocalTimeToUtcMs', () => {
  it('converts unambiguous local times', () => {
    expect(zonedLocalTimeToUtcMs('Asia/Shanghai', 2026, 6, 8, 20, 30, 0)).toBe(Date.parse('2026-06-08T12:30:00.000Z'))
  })

  it('takes the earlier instant for ambiguous fall-back times', () => {
    // 2026-11-01 01:30 America/New_York occurs twice; earlier is EDT (UTC-4).
    expect(zonedLocalTimeToUtcMs('America/New_York', 2026, 11, 1, 1, 30, 0)).toBe(
      Date.parse('2026-11-01T05:30:00.000Z')
    )
  })

  it('rolls spring-forward gap times past the transition', () => {
    // 2026-03-08 02:30 America/New_York does not exist; rolls to 03:30 EDT.
    expect(zonedLocalTimeToUtcMs('America/New_York', 2026, 3, 8, 2, 30, 0)).toBe(Date.parse('2026-03-08T07:30:00.000Z'))
  })

  it('rejects invalid timezones', () => {
    expect(() => zonedLocalTimeToUtcMs('Not/AZone', 2026, 1, 1, 0, 0, 0)).toThrow()
  })
})
