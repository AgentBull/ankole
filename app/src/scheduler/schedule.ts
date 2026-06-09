import { z } from 'zod'
import { timezoneOffsetMs, zonedLocalTimeToUtc } from '@/config/system'
import type { ScheduledTaskSchedule } from '@/common/db-schema'

const EXPLICIT_OFFSET = /(z|[+-]\d{2}:?\d{2})$/i
const LOCAL_DATE_TIME = /^(\d{4})-(\d{2})-(\d{2})(?:[T\s](\d{2}):(\d{2})(?::(\d{2}))?)?$/
const DEFAULT_TOP_OF_HOUR_STAGGER_MS = 5 * 60 * 1000
const TEN_YEARS_MS = 10 * 365.25 * 24 * 60 * 60 * 1000

export const ScheduledTaskScheduleSchema = z.discriminatedUnion('kind', [
  z
    .object({
      kind: z.literal('every'),
      every_ms: z.number().int().min(60_000),
      anchor_ms: z.number().int().optional()
    })
    .strict(),
  z
    .object({
      kind: z.literal('cron'),
      expression: z.string().min(1),
      stagger_ms: z.number().int().nonnegative().optional()
    })
    .strict()
])

export const CheckBackLaterAfterSchema = z
  .object({
    value: z.number().positive(),
    unit: z.enum(['seconds', 'minutes', 'hours', 'days'])
  })
  .strict()

export type CheckBackLaterAfter = z.output<typeof CheckBackLaterAfterSchema>

export function computeNextRun(input: {
  after: Date
  schedule: ScheduledTaskSchedule
  taskId: string
  timezone: string
}): Date {
  if (input.schedule.kind === 'every') return nextEveryRun(input.schedule, input.after)

  const staggerMs = resolveCronStaggerMs(input.schedule)
  const offsetMs = stableOffset(input.taskId, staggerMs)
  if (offsetMs <= 0) return computeCronBaseNextRun(input.schedule.expression, input.after, input.timezone)

  let cursor = new Date(Math.max(0, input.after.getTime() - offsetMs))
  for (let attempt = 0; attempt < 4; attempt++) {
    const baseNext = computeCronBaseNextRun(input.schedule.expression, cursor, input.timezone)
    const shifted = new Date(baseNext.getTime() + offsetMs)
    if (shifted > input.after) return shifted
    cursor = new Date(Math.max(cursor.getTime() + 1, baseNext.getTime() + 1_000))
  }
  throw new SchedulerScheduleError(`Unable to compute staggered cron expression: ${input.schedule.expression}`)
}

function computeCronBaseNextRun(expression: string, after: Date, timezone: string): Date {
  const offset = timezoneOffsetMs(timezone, after)
  const localAfter = new Date(after.getTime() + offset)
  const parsed = Bun.cron.parse(expression, localAfter)
  if (!parsed) throw new SchedulerScheduleError(`Invalid cron expression: ${expression}`)
  return new Date(parsed.getTime() - offset)
}

export function validateCronExpression(expression: string): void {
  if (!Bun.cron.parse(expression, new Date())) {
    throw new SchedulerScheduleError(`Invalid cron expression: ${expression}`)
  }
}

export function resolveCheckbackDueAt(input: {
  after?: CheckBackLaterAfter
  at?: string
  now?: Date
  timezone: string
}): Date {
  if (input.after && input.at) throw new SchedulerScheduleError('Provide exactly one of after or at')
  if (!input.after && !input.at) throw new SchedulerScheduleError('Provide exactly one of after or at')

  const now = input.now ?? new Date()
  if (input.after) return assertDueAtWithinBounds(new Date(now.getTime() + afterToMs(input.after)), now)

  return assertDueAtWithinBounds(parseScheduledAt(input.at!, input.timezone), now)
}

export function parseScheduledAt(value: string, timezone: string): Date {
  const trimmed = value.trim()
  if (EXPLICIT_OFFSET.test(trimmed)) {
    const parsed = new Date(trimmed)
    if (!Number.isFinite(parsed.getTime())) throw new SchedulerScheduleError(`Invalid at value: ${value}`)
    return parsed
  }

  const match = LOCAL_DATE_TIME.exec(trimmed)
  if (!match) throw new SchedulerScheduleError(`Invalid local at value: ${value}`)
  return zonedLocalTimeToUtc({
    timezone,
    year: Number(match[1]),
    month: Number(match[2]),
    day: Number(match[3]),
    hour: Number(match[4] ?? 0),
    minute: Number(match[5] ?? 0),
    second: Number(match[6] ?? 0)
  })
}

function nextEveryRun(schedule: Extract<ScheduledTaskSchedule, { kind: 'every' }>, after: Date): Date {
  const anchor = schedule.anchor_ms ?? after.getTime()
  const elapsed = after.getTime() - anchor
  const steps = elapsed < 0 ? 0 : Math.floor(elapsed / schedule.every_ms) + 1
  return new Date(anchor + steps * schedule.every_ms)
}

function afterToMs(after: CheckBackLaterAfter): number {
  const multiplier =
    after.unit === 'seconds'
      ? 1_000
      : after.unit === 'minutes'
        ? 60_000
        : after.unit === 'hours'
          ? 3_600_000
          : 86_400_000
  return Math.ceil(after.value * multiplier)
}

function stableOffset(input: string, modulo: number): number {
  if (modulo <= 1) return 0
  let hash = 2166136261
  for (let index = 0; index < input.length; index++) {
    hash ^= input.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return Math.abs(hash) % modulo
}

function resolveCronStaggerMs(schedule: Extract<ScheduledTaskSchedule, { kind: 'cron' }>): number {
  if (schedule.stagger_ms !== undefined) return Math.max(0, Math.floor(schedule.stagger_ms))
  return isRecurringTopOfHourCronExpr(schedule.expression) ? DEFAULT_TOP_OF_HOUR_STAGGER_MS : 0
}

function isRecurringTopOfHourCronExpr(expression: string): boolean {
  const fields = expression.trim().split(/\s+/).filter(Boolean)
  if (fields.length === 5) {
    const [minuteField, hourField] = fields
    return minuteField === '0' && hourField.includes('*')
  }
  if (fields.length === 6) {
    const [secondField, minuteField, hourField] = fields
    return secondField === '0' && minuteField === '0' && hourField.includes('*')
  }
  return false
}

function assertDueAtWithinBounds(dueAt: Date, now: Date): Date {
  if (dueAt.getTime() - now.getTime() > TEN_YEARS_MS) {
    throw new SchedulerScheduleError(
      `Scheduled time is too far in the future: ${dueAt.toISOString()}. Maximum allowed: 10 years`
    )
  }
  return dueAt
}

export class SchedulerScheduleError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SchedulerScheduleError'
  }
}
