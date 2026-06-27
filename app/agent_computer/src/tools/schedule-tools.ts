import { z } from 'zod'
import type { ActorInputEnvelope, JsonObject, TurnStart } from '../actor_lane'
import type { AgentTool, AgentToolResult } from '../core'
import { rpcMethods, type RpcMethod, type ScheduleRpcRequest } from '../rpc_lane'
import { buildTool } from './build-tool'

export type ScheduleRpcRequester = (method: RpcMethod, request: ScheduleRpcRequest) => Promise<JsonObject>

export interface CreateScheduleToolsOptions {
  turnStart: TurnStart
  requestScheduleRpc?: ScheduleRpcRequester
}

type ScheduleToolDetails = JsonObject

const JsonMap = z.record(z.string(), z.unknown())

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

export function createScheduleTools(opts: CreateScheduleToolsOptions): AgentTool<any>[] {
  if (!opts.requestScheduleRpc) return []
  return [createCheckBackLaterTool(opts), createCronTool(opts)]
}

function createCheckBackLaterTool(
  opts: CreateScheduleToolsOptions
): AgentTool<typeof CheckBackLaterParams, ScheduleToolDetails> {
  return buildTool({
    name: 'check_back_later',
    label: 'Check Back Later',
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
        idempotency_key: params.idempotency_key ?? `check_back_later:${opts.turnStart.turn.llm_turn_id}:${toolCallId}`,
        reason: params.reason,
        check: params.check,
        context_summary: params.context_summary,
        schedule,
        reply_route: replyRoute
      })

      return jsonToolResult(response)
    }
  })
}

function createCronTool(opts: CreateScheduleToolsOptions): AgentTool<typeof CronParams, ScheduleToolDetails> {
  return buildTool({
    name: 'cron',
    label: 'Cron Schedule',
    description:
      'List, inspect, create, update, pause, resume, remove, or manually run recurring schedules for this conversation. Recurring schedules support kind=every and kind=cron only.',
    schema: CronParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(toolCallId, params): Promise<AgentToolResult<ScheduleToolDetails>> {
      const method = cronMethod(params.action)
      const baseRequest = {
        request_id: `schedule-cron-${params.action}-${crypto.randomUUID()}`,
        turn_ref: opts.turnStart.turn
      }

      const response = await opts.requestScheduleRpc!(method, {
        ...baseRequest,
        ...cronPayload(params, opts.turnStart, toolCallId)
      })

      return jsonToolResult(response)
    }
  })
}

function cronMethod(action: z.output<typeof CronParams>['action']): RpcMethod {
  switch (action) {
    case 'list':
      return rpcMethods.scheduleCronList
    case 'get':
      return rpcMethods.scheduleCronGet
    case 'runs':
      return rpcMethods.scheduleCronRuns
    case 'add':
      return rpcMethods.scheduleCronAdd
    case 'update':
      return rpcMethods.scheduleCronUpdate
    case 'pause':
      return rpcMethods.scheduleCronPause
    case 'resume':
      return rpcMethods.scheduleCronResume
    case 'remove':
      return rpcMethods.scheduleCronRemove
    case 'run':
      return rpcMethods.scheduleCronRun
  }
}

function cronPayload(params: z.output<typeof CronParams>, turnStart: TurnStart, toolCallId: string): JsonObject {
  switch (params.action) {
    case 'list':
      return {}
    case 'get':
    case 'pause':
    case 'resume':
    case 'remove':
    case 'run':
      return { cron_schedule_id: requiredCronScheduleId(params) }
    case 'runs':
      return { cron_schedule_id: requiredCronScheduleId(params), ...(params.limit ? { limit: params.limit } : {}) }
    case 'add':
      return cronAddPayload(params, turnStart, toolCallId)
    case 'update':
      return {
        cron_schedule_id: requiredCronScheduleId(params),
        updates: cronUpdates(params, turnStart)
      }
  }
}

function cronAddPayload(params: z.output<typeof CronParams>, turnStart: TurnStart, toolCallId: string): JsonObject {
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
    idempotency_key: params.idempotency_key ?? `cron:add:${turnStart.turn.llm_turn_id}:${toolCallId}`
  }
}

function cronUpdates(params: z.output<typeof CronParams>, turnStart: TurnStart): JsonObject {
  const route = currentReplyRoute(turnStart)
  const updates: JsonObject = { ...params.updates }
  if (params.name !== undefined) updates.name = params.name
  if (params.schedule !== undefined) updates.schedule = params.schedule
  if (params.payload !== undefined) updates.payload = params.payload
  if (params.delivery !== undefined) updates.delivery = cronDelivery(params, route)
  return updates
}

function cronDelivery(params: z.output<typeof CronParams>, route: ReplyRoute | undefined): JsonObject | undefined {
  const delivery = {
    ...(route?.signal_channel_id ? { signal_channel_id: route.signal_channel_id } : {}),
    ...(route?.provider_thread_id ? { provider_thread_id: route.provider_thread_id } : {}),
    ...params.delivery
  }
  return Object.keys(delivery).length > 0 ? delivery : undefined
}

function requiredCronScheduleId(params: z.output<typeof CronParams>): string {
  if (!params.cron_schedule_id) throw new Error(`${params.action} requires cron_schedule_id`)
  return params.cron_schedule_id
}

type ReplyRoute = {
  binding_name?: string
  signal_channel_id?: string
  provider_thread_id?: string
  provider_entry_id?: string
}

function currentReplyRoute(turnStart: TurnStart): ReplyRoute | undefined {
  for (const input of turnStart.inputs) {
    const route = replyRouteFromInput(input)
    if (route.binding_name && route.signal_channel_id) return route
  }
}

function replyRouteFromInput(input: ActorInputEnvelope): ReplyRoute {
  const payload = input.payload_json
  return compact({
    binding_name:
      input.binding_name ??
      deepString(payload, ['data', 'reply_route', 'binding_name']) ??
      deepString(payload, ['data', 'session', 'binding_name']),
    signal_channel_id:
      input.signal_channel_id ??
      deepString(payload, ['data', 'reply_route', 'signal_channel_id']) ??
      deepString(payload, ['data', 'channel', 'id']) ??
      deepString(payload, ['data', 'entry', 'signal_channel_id']),
    provider_thread_id:
      input.provider_thread_id ??
      deepString(payload, ['data', 'reply_route', 'provider_thread_id']) ??
      deepString(payload, ['data', 'entry', 'provider_thread_id']),
    provider_entry_id:
      input.provider_entry_id ??
      deepString(payload, ['data', 'reply_route', 'provider_entry_id']) ??
      deepString(payload, ['data', 'entry', 'provider_entry_id'])
  })
}

function jsonToolResult(details: JsonObject): AgentToolResult<ScheduleToolDetails> {
  return {
    content: [{ type: 'text', text: JSON.stringify(details) }],
    details
  }
}

function compact<T extends Record<string, string | undefined>>(value: T): T {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined)) as T
}

function deepString(value: unknown, path: string[]): string | undefined {
  let current: unknown = value
  for (const key of path) {
    if (!isRecord(current)) return undefined
    current = current[key]
  }
  return typeof current === 'string' && current.trim() !== '' ? current.trim() : undefined
}

function isRecord(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
