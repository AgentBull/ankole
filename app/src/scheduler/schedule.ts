import { genericHash, isValidCronExpression, nextCronFire } from '@agentbull/bullx-native-addons'
import { ms } from '@pleisto/active-support'
import { z } from 'zod'
import { zonedLocalTimeToUtc } from '@/config/system'
import type { ScheduledTaskSchedule } from '@/common/db-schema'

// Matches a trailing timezone designator: either "Z" or a numeric offset like
// "+09:00". When present the caller has already pinned the instant, so we trust
// it and skip local-timezone interpretation.
const EXPLICIT_OFFSET = /(z|[+-]\d{2}:?\d{2})$/i
// Matches a bare wall-clock string (date, optionally with time) that carries no
// offset and must therefore be resolved against the installation timezone.
const LOCAL_DATE_TIME = /^(\d{4})-(\d{2})-(\d{2})(?:[T\s](\d{2}):(\d{2})(?::(\d{2}))?)?$/
// Spreads "top of the hour" cron tasks over a 5-minute window by default. Many
// tasks use expressions like "0 * * * *", so without a stagger they would all
// fire at exactly :00 and stampede the agent runtime at once.
const DEFAULT_TOP_OF_HOUR_STAGGER_MS = ms('5m')
// Upper bound on how far ahead a one-shot wakeup may be scheduled. Guards
// against a typo (e.g. wrong year) parking a checkback effectively forever.
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

/**
 * Computes the next fire time for a scheduled task, strictly after `after`.
 *
 * Two schedule kinds are handled. An `every` schedule steps off a fixed anchor
 * so the cadence never drifts. A `cron` schedule fires on calendar boundaries,
 * optionally shifted by a small per-task offset so that many tasks sharing the
 * same expression do not all fire at the same instant.
 *
 * @param after - The result is the first fire time strictly later than this.
 * @param taskId - Seeds the deterministic stagger offset; the same task always
 *   gets the same shift, so its fire times stay predictable across runs.
 * @param timezone - IANA zone used to interpret cron fields (e.g. "9am" means
 *   9am local, surviving DST changes).
 */
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

  // The stagger shifts each fire time forward by `offsetMs`. To find the first
  // shifted fire after `after`, we rewind the cursor by the offset, ask for the
  // base cron boundary, then add the offset back. The loop retries because a
  // boundary near `after` can shift to a moment that is still <= `after` (it
  // belongs to the previous period); each retry advances past that boundary.
  // Four attempts comfortably cover this; failing that many times signals a
  // pathological expression rather than a normal edge.
  let cursor = new Date(Math.max(0, input.after.getTime() - offsetMs))
  for (let attempt = 0; attempt < 4; attempt++) {
    const baseNext = computeCronBaseNextRun(input.schedule.expression, cursor, input.timezone)
    const shifted = new Date(baseNext.getTime() + offsetMs)
    if (shifted > input.after) return shifted
    cursor = new Date(Math.max(cursor.getTime() + 1, baseNext.getTime() + 1_000))
  }
  throw new SchedulerScheduleError(`Unable to compute staggered cron expression: ${input.schedule.expression}`)
}

// Resolves the next cron boundary after `after`, ignoring any per-task stagger.
// Delegates to the native addon so the calendar walk happens in the target zone.
function computeCronBaseNextRun(expression: string, after: Date, timezone: string): Date {
  let nextMs: number | null
  try {
    // Native fire-time math iterates inside the IANA timezone, so DST
    // transitions cannot skew "every day at 9am"-style schedules.
    nextMs = nextCronFire(expression, after.getTime(), timezone)
  } catch (error) {
    throw new SchedulerScheduleError(error instanceof Error ? error.message : `Invalid cron expression: ${expression}`)
  }
  if (nextMs === null) throw new SchedulerScheduleError(`Cron expression never fires again: ${expression}`)
  return new Date(nextMs)
}

/** Rejects a cron expression the native parser cannot understand, before it is stored. */
export function validateCronExpression(expression: string): void {
  if (!isValidCronExpression(expression)) {
    throw new SchedulerScheduleError(`Invalid cron expression: ${expression}`)
  }
}

/**
 * Resolves the absolute due time for a one-shot `check_back_later` wakeup.
 *
 * The caller supplies exactly one of a relative delay (`after`) or an absolute
 * wall-clock string (`at`); supplying both or neither is a usage error and is
 * rejected rather than guessed. The result is bounded so a malformed `at` cannot
 * schedule a wakeup centuries out.
 */
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

/**
 * Parses a user-supplied "at" timestamp into a UTC instant.
 *
 * A string that already carries an offset (or "Z") is treated as authoritative
 * and parsed as-is. A bare wall-clock string has no offset, so it is interpreted
 * in the installation timezone — that is the difference an LLM or operator means
 * when they write "2026-06-08 20:30" without a zone.
 */
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

// Lands the next "every N ms" tick on the anchored grid rather than `after + N`.
// Counting whole steps from the anchor means a late or skipped tick snaps back
// to the original phase instead of letting the cadence drift forward over time.
// When `after` precedes the anchor, the first scheduled instant is the anchor.
function nextEveryRun(schedule: Extract<ScheduledTaskSchedule, { kind: 'every' }>, after: Date): Date {
  const anchor = schedule.anchor_ms ?? after.getTime()
  const elapsed = after.getTime() - anchor
  const steps = elapsed < 0 ? 0 : Math.floor(elapsed / schedule.every_ms) + 1
  return new Date(anchor + steps * schedule.every_ms)
}

// Converts a {value, unit} delay into whole milliseconds. Rounds up so a
// fractional request never resolves to "now" or the past and fire immediately.
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

// Derives a deterministic offset in [0, modulo) by hashing a stable key (the
// task id). Same task -> same offset every time, so a task keeps its fixed slot
// in the stagger window instead of jumping around on each recompute.
function stableOffset(input: string, modulo: number): number {
  if (modulo <= 1) return 0
  return Number.parseInt(genericHash(input).slice(0, 8), 16) % modulo
}

// Chooses the stagger window width. An explicit `stagger_ms` always wins; with
// no explicit value, only "top of the hour"-style recurring expressions get the
// default spread, since those are the ones prone to a synchronized stampede.
function resolveCronStaggerMs(schedule: Extract<ScheduledTaskSchedule, { kind: 'cron' }>): number {
  if (schedule.stagger_ms !== undefined) return Math.max(0, Math.floor(schedule.stagger_ms))
  return isRecurringTopOfHourCronExpr(schedule.expression) ? DEFAULT_TOP_OF_HOUR_STAGGER_MS : 0
}

// Detects expressions that fire at minute 0 across many hours (5-field form) or
// at second 0 / minute 0 across many hours (6-field form). These are the common
// "on the hour" schedules whose fire times collide; other shapes opt out so we
// do not nudge a task the operator pinned to a precise minute.
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
