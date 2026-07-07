import { createHash } from 'node:crypto'
import { compactRecord, deepString as rawDeepString, match } from '@pleisto/active-support'
import { z } from 'zod'
import type { JsonObject } from '@pleisto/active-support'
import { deepString } from '@pleisto/active-support'
import type { ActorEventEnvelope, TurnStart } from '../../lanes/actor_lane'
import type { AgentTool, AgentToolResult } from '../../core'
import { jsonToolResult } from '../../core/tool-result'
import { rpcMethods, type RpcMethod, type ScheduleRpcRequest } from '../../lanes/rpc_lane'

export type ScheduleRpcRequester = (method: RpcMethod, request: ScheduleRpcRequest) => Promise<JsonObject>

export interface CreateScheduleToolsOptions {
  turnStart: TurnStart
  requestScheduleRpc?: ScheduleRpcRequester
}

type ScheduleToolDetails = JsonObject

const JsonMap = z.record(z.string(), z.unknown())

const CRON_DESCRIPTION = [
  'Manage recurring schedules for this conversation: list, inspect, create, update, pause, resume, remove, manually run, or view run history.',
  'Use this tool when the user asks about standing work, recurring tasks, monitors, routines, scheduled jobs, or cron-like follow-up in the current conversation.',
  'Recurring schedules support kind=every and kind=cron only.',
  'After add or update, summarize the saved schedule in the visible reply: name, schedule/timezone, delivery target, and whether quiet_success is enabled.',
  'Use quiet_success=true for recurring monitors that should stay quiet on success and visibly report failures, blockers, or meaningful state changes.'
].join('\n')

const CheckBackLaterParams = z
  .object({
    reason: z.string().min(1).max(2000).describe('Why this checkback is being scheduled.'),
    check: z.string().min(1).max(4000).describe('What to check or continue when the wakeup fires.'),
    context_summary: z.string().max(8000).optional().describe('Compact context needed at wakeup time.'),
    after: z
      .object({
        value: z.number().int().positive(),
        unit: z.enum(['millisecond', 'second', 'minute', 'hour', 'day', 'week'])
      })
      .optional()
      .describe('Relative delay. Mutually exclusive with at.'),
    at: z.string().optional().describe('Absolute ISO datetime, or local ISO datetime with timezone.'),
    timezone: z.string().optional().describe('Timezone for local at values.'),
    idempotency_key: z.string().optional().describe('Stable key for retrying the same schedule request.')
  })
  .refine(params => Boolean(params.after) !== Boolean(params.at), {
    message: 'provide exactly one of after or at'
  })

const EverySchedule = z.object({
  kind: z.literal('every'),
  every_ms: z.number().int().positive(),
  anchor_at: z.string()
})

const CronSchedule = z.object({
  kind: z.literal('cron'),
  expression: z.string().min(1),
  timezone: z.string().optional(),
  stagger_ms: z.number().int().nonnegative().optional()
})

const DeliveryParams = z.object({
  signal_channel_id: z.string().optional(),
  provider_thread_id: z.string().optional(),
  quiet_success: z.boolean().optional()
})

const CronParams = z.object({
  action: z.enum(['list', 'get', 'runs', 'add', 'update', 'pause', 'resume', 'remove', 'run']),
  cron_schedule_id: z.string().optional(),
  name: z.string().optional(),
  binding_name: z.string().optional(),
  schedule: z.union([EverySchedule, CronSchedule]).optional(),
  payload: JsonMap.optional(),
  delivery: DeliveryParams.optional(),
  updates: JsonMap.optional(),
  idempotency_key: z.string().optional(),
  limit: z.number().int().positive().max(100).optional()
})

const CronOriginReadActions = new Set<z.output<typeof CronParams>['action']>(['list', 'get', 'runs'])

/**
 * Creates scheduling tools only when the turn runtime provides schedule RPC.
 */
export function createScheduleTools(opts: CreateScheduleToolsOptions): AgentTool<any>[] {
  if (!opts.requestScheduleRpc) return []
  return [createCheckBackLaterTool(opts), createCronTool(opts)]
}

/**
 * Builds the one-shot delayed self-wakeup tool.
 */
function createCheckBackLaterTool(
  opts: CreateScheduleToolsOptions
): AgentTool<typeof CheckBackLaterParams, ScheduleToolDetails> {
  return {
    name: 'check_back_later',
    description:
      'Schedule one delayed self-wakeup for this conversation. Use when the user asks you to wait, remind yourself, follow up later, or re-check something after time passes.',
    schema: CheckBackLaterParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(toolCallId, params): Promise<AgentToolResult<ScheduleToolDetails>> {
      const replyRoute = currentReplyRoute(opts.turnStart)
      if (!replyRoute) {
        throw new Error('check_back_later requires a provider reply route from the current turn')
      }

      const schedule = params.after
        ? { after: params.after, ...(params.timezone ? { timezone: params.timezone } : {}) }
        : { at: params.at, ...(params.timezone ? { timezone: params.timezone } : {}) }

      const response = await opts.requestScheduleRpc!(rpcMethods.scheduleCheckBackLaterCreate, {
        request_id: `schedule-checkback-${crypto.randomUUID()}`,
        turn_ref: opts.turnStart.turn,
        tool_call_id: toolCallId,
        idempotency_key: params.idempotency_key ?? defaultCheckBackIdempotencyKey(opts.turnStart, params),
        reason: params.reason,
        check: params.check,
        context_summary: params.context_summary,
        schedule,
        reply_route: replyRoute
      })

      return jsonToolResult(response)
    }
  }
}

/**
 * Builds the default idempotency key for a delayed checkback request.
 *
 * Provider/tool retries should create one schedule, not duplicate wakeups. The
 * key is stable for the actor event and semantic schedule payload.
 */
function defaultCheckBackIdempotencyKey(turnStart: TurnStart, params: z.output<typeof CheckBackLaterParams>): string {
  const stableInput = {
    actor_event_id: turnStart.turn.actor_event_id,
    reason: params.reason.trim(),
    check: params.check.trim(),
    context_summary: params.context_summary?.trim() ?? '',
    schedule: params.after
      ? {
          after: params.after,
          timezone: params.timezone ?? null
        }
      : {
          at: params.at ?? null,
          timezone: params.timezone ?? null
        }
  }

  return `check_back_later:${turnStart.turn.actor_event_id}:${stableHash(stableInput)}`
}

/**
 * Builds the recurring schedule management tool.
 */
function createCronTool(opts: CreateScheduleToolsOptions): AgentTool<typeof CronParams, ScheduleToolDetails> {
  return {
    name: 'cron',
    description: CRON_DESCRIPTION,
    schema: CronParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<ScheduleToolDetails>> {
      rejectCronOriginMutation(params, opts.turnStart)
      const method = cronMethod(params.action)
      const baseRequest = {
        request_id: `schedule-cron-${params.action}-${crypto.randomUUID()}`,
        turn_ref: opts.turnStart.turn
      }

      const response = await opts.requestScheduleRpc!(method, {
        ...baseRequest,
        ...cronPayload(params, opts.turnStart)
      })

      return jsonToolResult(response)
    }
  }
}

/**
 * Cron fires are already the result of one recurring schedule. Letting that
 * callback create or mutate more cron schedules is an easy way for a model to
 * accidentally build a self-replicating loop, so cron-origin turns are read-only.
 */
function rejectCronOriginMutation(params: z.output<typeof CronParams>, turnStart: TurnStart): void {
  if (!isCronOriginTurn(turnStart) || CronOriginReadActions.has(params.action)) return
  throw new Error(
    `cron-origin turns may only list/get/runs cron schedules; action=${params.action} is denied to prevent recursive schedule mutation`
  )
}

function isCronOriginTurn(turnStart: TurnStart): boolean {
  return turnStart.request_context?.turn_mode === 'cron'
}

/**
 * Maps the model-facing cron action to the control-plane RPC method.
 */
function cronMethod(action: z.output<typeof CronParams>['action']): RpcMethod {
  return match(action)
    .with('list', () => rpcMethods.scheduleCronList)
    .with('get', () => rpcMethods.scheduleCronGet)
    .with('runs', () => rpcMethods.scheduleCronRuns)
    .with('add', () => rpcMethods.scheduleCronAdd)
    .with('update', () => rpcMethods.scheduleCronUpdate)
    .with('pause', () => rpcMethods.scheduleCronPause)
    .with('resume', () => rpcMethods.scheduleCronResume)
    .with('remove', () => rpcMethods.scheduleCronRemove)
    .with('run', () => rpcMethods.scheduleCronRun)
    .exhaustive()
}

/**
 * Builds the action-specific cron RPC payload.
 */
function cronPayload(params: z.output<typeof CronParams>, turnStart: TurnStart): JsonObject {
  return match(params.action)
    .with('list', () => ({}))
    .with('get', 'pause', 'resume', 'remove', 'run', () => ({ cron_schedule_id: requiredCronScheduleId(params) }))
    .with('runs', () => ({
      cron_schedule_id: requiredCronScheduleId(params),
      ...(params.limit ? { limit: params.limit } : {})
    }))
    .with('add', () => cronAddPayload(params, turnStart))
    .with('update', () => ({
      cron_schedule_id: requiredCronScheduleId(params),
      updates: cronUpdates(params, turnStart)
    }))
    .exhaustive()
}

/**
 * Builds the payload for creating a recurring schedule.
 *
 * The current reply route is reused by default so scheduled fires know where to
 * reply without the model repeating provider routing fields.
 */
function cronAddPayload(params: z.output<typeof CronParams>, turnStart: TurnStart): JsonObject {
  if (!params.schedule) throw new Error('cron add requires schedule')
  const route = currentReplyRoute(turnStart)
  const bindingName = params.binding_name ?? route?.binding_name
  if (!bindingName) throw new Error('cron add requires binding_name or a current provider binding')

  return {
    binding_name: bindingName,
    name: params.name,
    schedule: params.schedule,
    payload: params.payload ?? {},
    delivery: cronDelivery(params, route),
    idempotency_key: params.idempotency_key ?? defaultCronAddIdempotencyKey(turnStart, params, bindingName, route)
  }
}

/**
 * Builds a stable idempotency key for cron creation.
 */
function defaultCronAddIdempotencyKey(
  turnStart: TurnStart,
  params: z.output<typeof CronParams>,
  bindingName: string,
  route: ReplyRoute | undefined
): string {
  const stableInput = {
    actor_event_id: turnStart.turn.actor_event_id,
    binding_name: bindingName,
    name: params.name?.trim() ?? '',
    schedule: params.schedule,
    payload: params.payload ?? {},
    delivery: cronDelivery(params, route) ?? {}
  }

  return `cron:add:${turnStart.turn.actor_event_id}:${stableHash(stableInput)}`
}

/**
 * Builds the partial update object for cron update actions.
 */
function cronUpdates(params: z.output<typeof CronParams>, turnStart: TurnStart): JsonObject {
  const route = currentReplyRoute(turnStart)
  const updates: JsonObject = { ...params.updates }
  if (params.name !== undefined) updates.name = params.name
  if (params.schedule !== undefined) updates.schedule = params.schedule
  if (params.payload !== undefined) updates.payload = params.payload
  if (params.delivery !== undefined) updates.delivery = cronDelivery(params, route)
  return updates
}

/**
 * Merges explicit delivery options with the current provider reply route.
 */
function cronDelivery(params: z.output<typeof CronParams>, route: ReplyRoute | undefined): JsonObject | undefined {
  const delivery = {
    ...(route?.signal_channel_id ? { signal_channel_id: route.signal_channel_id } : {}),
    ...(route?.provider_thread_id ? { provider_thread_id: route.provider_thread_id } : {}),
    ...params.delivery
  }
  return Object.keys(delivery).length > 0 ? delivery : undefined
}

/**
 * Reads the required cron schedule id for actions that target one schedule.
 */
function requiredCronScheduleId(params: z.output<typeof CronParams>): string {
  if (!params.cron_schedule_id) throw new Error(`${params.action} requires cron_schedule_id`)
  return params.cron_schedule_id
}

type ReplyRoute = {
  binding_name?: string
  signal_channel_id?: string
  provider_thread_id?: string
  source_entry_id?: string
}

/**
 * Returns the current reply route only when it has enough provider routing
 * information for a future schedule fire.
 */
function currentReplyRoute(turnStart: TurnStart): ReplyRoute | undefined {
  const route = replyRouteFromInput(turnStart.actor_event)
  return route.binding_name && route.signal_channel_id ? route : undefined
}

/**
 * Extracts provider reply routing from the actor event and its payload.
 */
function replyRouteFromInput(input: ActorEventEnvelope): ReplyRoute {
  const payload = input.payload_json
  return compactRecord({
    binding_name:
      input.binding_name ??
      deepString(payload, ['data', 'reply_route', 'binding_name']) ??
      deepString(payload, ['data', 'session', 'binding_name']),
    signal_channel_id:
      input.signal_channel_id ??
      nonEmptyDeepString(payload, ['data', 'reply_route', 'signal_channel_id']) ??
      nonEmptyDeepString(payload, ['data', 'channel', 'id']) ??
      nonEmptyDeepString(payload, ['data', 'entry', 'signal_channel_id']),
    provider_thread_id:
      input.provider_thread_id ??
      nonEmptyDeepString(payload, ['data', 'reply_route', 'provider_thread_id']) ??
      nonEmptyDeepString(payload, ['data', 'entry', 'provider_thread_id']),
    source_entry_id:
      input.source_entry_id ??
      nonEmptyDeepString(payload, ['data', 'reply_route', 'source_entry_id']) ??
      nonEmptyDeepString(payload, ['data', 'entry', 'source_entry_id'])
  })
}

/**
 * Reads a non-empty string from a nested payload path.
 */
function nonEmptyDeepString(value: unknown, path: string[]): string | undefined {
  const text = rawDeepString(value, path)?.trim()
  return text ? text : undefined
}

/**
 * Produces a short deterministic hash for idempotency keys.
 */
function stableHash(value: unknown): string {
  return createHash('sha256').update(stableJson(value)).digest('hex').slice(0, 16)
}

/**
 * Serializes JSON with stable object key order.
 */
function stableJson(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(stableJson).join(',')}]`
  }

  if (value && typeof value === 'object') {
    const entries = Object.entries(value as JsonObject).sort(([left], [right]) => left.localeCompare(right))
    return `{${entries.map(([key, entry]) => `${JSON.stringify(key)}:${stableJson(entry)}`).join(',')}}`
  }

  return JSON.stringify(value) ?? 'null'
}
