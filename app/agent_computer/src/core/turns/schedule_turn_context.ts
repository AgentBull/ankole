import { isRecord, type JsonObject as JSONObject } from '@agentbull/active-support'
import type { TurnStart } from '../../lanes/actor_lane'

export type ScheduleTurnContext = {
  mode: 'check_back_later' | 'cron'
  origin: {
    scheduleKind?: string
    dueAt?: string
    firedAt?: string
    timezone?: string
    cronScheduleName?: string
    cronFireSlotAt?: string
    trigger?: string
    payload: JSONObject
  }
  silentSuccessAllowed: boolean
  consecutiveIdenticalReplies?: number
}

/** Decodes the schedule-owned part of request_context for scheduled turns. */
export function scheduleTurnContextFromTurnStart(turnStart: TurnStart): ScheduleTurnContext | undefined {
  const mode = scheduleMode(turnStart.actor_event.type)
  if (!mode) return undefined

  const context = turnStart.request_context
  if (!isRecord(context)) throw new Error('Scheduled turn request context is required.')

  const origin = context.schedule_origin
  if (!isRecord(origin)) throw new Error('Scheduled turn origin is required.')

  if (typeof context.silent_success_allowed !== 'boolean') {
    throw new Error('Scheduled turn silent_success_allowed must be a boolean.')
  }

  const consecutiveIdenticalReplies = optionalReplyStreak(context.consecutive_identical_replies)

  return {
    mode,
    origin: {
      ...optionalStringField(origin, 'schedule_kind', 'scheduleKind'),
      ...optionalStringField(origin, 'due_at', 'dueAt'),
      ...optionalStringField(origin, 'fired_at', 'firedAt'),
      ...optionalStringField(origin, 'timezone', 'timezone'),
      ...optionalStringField(origin, 'cron_schedule_name', 'cronScheduleName'),
      ...optionalStringField(origin, 'cron_fire_slot_at', 'cronFireSlotAt'),
      ...optionalStringField(origin, 'trigger', 'trigger'),
      payload: jsonObject(origin.payload, 'schedule_origin.payload')
    },
    silentSuccessAllowed: context.silent_success_allowed,
    ...(consecutiveIdenticalReplies === undefined ? {} : { consecutiveIdenticalReplies })
  }
}

function scheduleMode(eventType: string): ScheduleTurnContext['mode'] | undefined {
  if (eventType === 'check_back_later.wakeup') return 'check_back_later'
  if (eventType === 'cron.fire') return 'cron'
  return undefined
}

function optionalStringField<OutputKey extends string>(
  source: JSONObject,
  inputKey: string,
  outputKey: OutputKey
): Partial<Record<OutputKey, string>> {
  const value = source[inputKey]
  if (value === undefined || value === null) return {}
  if (typeof value !== 'string') throw new Error(`Scheduled turn ${inputKey} must be a string.`)
  return { [outputKey]: value } as Partial<Record<OutputKey, string>>
}

function jsonObject(value: unknown, field: string): JSONObject {
  if (value === undefined || value === null) return {}
  if (!isRecord(value)) throw new Error(`Scheduled turn ${field} must be an object.`)
  return value
}

function optionalReplyStreak(value: unknown): number | undefined {
  if (value === undefined || value === null) return undefined
  if (!Number.isSafeInteger(value) || (value as number) < 2) {
    throw new Error('Scheduled turn consecutive_identical_replies must be an integer of at least 2.')
  }
  return value as number
}
