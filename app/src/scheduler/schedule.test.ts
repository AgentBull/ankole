import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { computeNextRun, parseScheduledAt, resolveCheckbackDueAt, SchedulerScheduleError } = await import('./schedule')

describe('scheduler schedule helpers', () => {
  it('resolves check_back_later local at values using system.timezone semantics', () => {
    expect(parseScheduledAt('2026-06-08 20:30', 'Asia/Shanghai').toISOString()).toBe('2026-06-08T12:30:00.000Z')
  })

  it('keeps explicit offsets authoritative for at values', () => {
    expect(parseScheduledAt('2026-06-08T20:30:00+09:00', 'Asia/Shanghai').toISOString()).toBe(
      '2026-06-08T11:30:00.000Z'
    )
  })

  it('requires exactly one check_back_later time condition', () => {
    expect(() =>
      resolveCheckbackDueAt({
        after: { value: 1, unit: 'minutes' },
        at: '2026-06-08 20:30',
        timezone: 'Asia/Shanghai'
      })
    ).toThrow(SchedulerScheduleError)
    expect(() => resolveCheckbackDueAt({ timezone: 'Asia/Shanghai' })).toThrow(SchedulerScheduleError)
  })

  it('resolves relative check_back_later delays from the current time', () => {
    const now = new Date('2026-06-08T12:00:00.000Z')

    expect(
      resolveCheckbackDueAt({
        after: { value: 15, unit: 'minutes' },
        now,
        timezone: 'Asia/Shanghai'
      }).toISOString()
    ).toBe('2026-06-08T12:15:00.000Z')
  })

  it('computes every schedules from their anchor', () => {
    expect(
      computeNextRun({
        after: new Date('2026-06-08T00:00:00.000Z'),
        schedule: { kind: 'every', every_ms: 60_000, anchor_ms: Date.parse('2026-06-08T00:00:00.000Z') },
        taskId: 'task-a',
        timezone: 'Asia/Shanghai'
      }).toISOString()
    ).toBe('2026-06-08T00:01:00.000Z')
  })

  it('computes cron schedules in the installation timezone', () => {
    expect(
      computeNextRun({
        after: new Date('2026-06-08T00:30:00.000Z'),
        schedule: { kind: 'cron', expression: '0 9 * * *' },
        taskId: 'task-a',
        timezone: 'Asia/Shanghai'
      }).toISOString()
    ).toBe('2026-06-08T01:00:00.000Z')
  })
})
