import { z } from 'zod'
import { timezoneOffsetMs, zonedLocalTimeToUtc } from '@/config/system'
import type { ScheduledTaskSchedule } from '@/common/db-schema'

const EXPLICIT_OFFSET = /(z|[+-]\d{2}:?\d{2})$/i
const LOCAL_DATE_TIME = /^(\d{4})-(\d{2})-(\d{2})(?:[T\s](\d{2}):(\d{2})(?::(\d{2}))?)?$/

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

  const offset = timezoneOffsetMs(input.timezone, input.after)
  const localAfter = new Date(input.after.getTime() + offset)
  const parsed = Bun.cron.parse(input.schedule.expression, localAfter)
  if (!parsed) throw new SchedulerScheduleError(`Invalid cron expression: ${input.schedule.expression}`)

  const stagger = input.schedule.stagger_ms ? stableOffset(input.taskId, input.schedule.stagger_ms) : 0
  return new Date(parsed.getTime() - offset + stagger)
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
  if (input.after) return new Date(now.getTime() + afterToMs(input.after))

  return parseScheduledAt(input.at!, input.timezone)
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
  let hash = 2166136261
  for (let index = 0; index < input.length; index++) {
    hash ^= input.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return Math.abs(hash) % modulo
}

export class SchedulerScheduleError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SchedulerScheduleError'
  }
}
