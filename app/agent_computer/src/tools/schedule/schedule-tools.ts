import { createHash } from 'node:crypto'
import { compactRecord, deepString as rawDeepString, match } from '@pleisto/active-support'
import { z } from 'zod'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { deepString } from '@pleisto/active-support'
import type { ActorEventEnvelope, TurnStart } from '../../lanes/actor_lane'
import type { AgentTool, AgentToolResult } from '../../core'
import { ModelIntegerID, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import { jsonBytes } from '../../fabric/envelope_proto'
import { rpcMethods, type RPCRequestInit, type ScheduleRPCRequester } from '../../lanes/rpc_lane'

export interface CreateScheduleToolsOptions {
  turnStart: TurnStart
  requestScheduleRPC: ScheduleRPCRequester
}

type ScheduleToolDetails = JSONObject

const JSONMap = z.record(z.string(), z.unknown())
const CRON_DESCRIPTION = [
  'Manage recurring schedules for this conversation: list, inspect, create, update, pause, resume, remove, manually run, or view run history.',
  'Use this tool when the user asks about standing work, recurring tasks, monitors, routines, scheduled jobs, or cron-like follow-up in the current conversation.',
  'Recurring schedules support kind=every and kind=cron only.',
  'After add or update, summarize the saved schedule in the visible reply: name, schedule/timezone, and whether quiet_success is enabled.',
  'Use quiet_success=true for recurring monitors that should stay quiet on success and visibly report failures, blockers, or meaningful state changes.'
].join('\n')

const CheckBackDelay = z.object({
  value: z.number().int().positive(),
  unit: z.enum(['millisecond', 'second', 'minute', 'hour', 'day', 'week'])
})

const CheckBackSchedule = z.union([
  z.object({
    after: CheckBackDelay.describe(
      'Relative delay for genuinely relative requests. Do not round a known clock time, market close, deadline, or timezone-converted instant into an approximate delay.'
    ),
    timezone: z.string().optional()
  }),
  z.object({
    at: z
      .string()
      .describe(
        'Exact absolute ISO datetime, or local ISO datetime with timezone. Prefer at whenever the requested event has a known clock time or deadline.'
      ),
    timezone: z.string().optional().describe('Timezone for local at values.')
  })
])

const CheckBackCreateParams = z.object({
  action: z.literal('create'),
  reason: z.string().min(1).max(2000).describe('Why this checkback is being scheduled.'),
  check: z.string().min(1).max(4000).describe('What to check or continue when the wakeup fires.'),
  context_summary: z.string().max(8000).optional().describe('Compact context needed at wakeup time.'),
  schedule: CheckBackSchedule,
  quiet_success: z
    .boolean()
    .optional()
    .describe(
      'Allow this checkback to finish without a visible reply when nothing needs attention. Set true only when the user explicitly asked for no update on normal/no-change outcomes; failures, blockers, human decisions, meaningful changes, and time-sensitive risks must still be visible.'
    )
})

const CheckBackUpdateFields = z
  .object({
    reason: z.string().min(1).max(2000).describe('Why this checkback is being scheduled.'),
    check: z.string().min(1).max(4000).optional().describe('Replacement wakeup instructions.'),
    context_summary: z.string().max(8000).nullable().optional().describe('Replacement compact wakeup context.'),
    schedule: CheckBackSchedule.optional(),
    quiet_success: z.boolean().optional()
  })
  .partial()
  .refine(updates => Object.keys(updates).length > 0, {
    message: 'provide at least one checkback update'
  })

const CheckBackLaterOperationParams = z.discriminatedUnion('action', [
  CheckBackCreateParams,
  z.object({
    action: z.literal('list'),
    limit: z.number().int().positive().max(25).optional()
  }),
  z.object({
    action: z.literal('get'),
    checkback_id: ModelIntegerID
  }),
  z.object({
    action: z.literal('update'),
    checkback_id: ModelIntegerID,
    updates: CheckBackUpdateFields
  }),
  z.object({
    action: z.literal('cancel'),
    checkback_id: ModelIntegerID
  })
])

// OpenAI-compatible function tools require the parameters schema itself to be
// an object. Keep the precise per-action validator above for execution, but
// expose one object-shaped model boundary instead of a root-level `oneOf`.
const CheckBackLaterParams = z
  .object({
    action: z.enum(['create', 'list', 'get', 'update', 'cancel']).describe('Checkback management action.'),
    checkback_id: ModelIntegerID.optional().describe(
      'Required for get, update, and cancel. Use list first when the id is unknown.'
    ),
    reason: z.string().min(1).max(2000).optional().describe('Required for create: why the checkback is useful.'),
    check: z.string().min(1).max(4000).optional().describe('Required for create: what to do at wakeup.'),
    context_summary: z.string().max(8000).nullable().optional().describe('Optional compact create-time context.'),
    schedule: CheckBackSchedule.optional().describe('Required for create: the one-shot wakeup time.'),
    quiet_success: z.boolean().optional().describe('Optional create-time quiet-success policy.'),
    updates: CheckBackUpdateFields.optional().describe('Required for update; provide at least one changed field.'),
    limit: z.number().int().positive().max(25).optional().describe('Optional list result limit, at most 25.')
  })
  .superRefine((params, context) => {
    const result = CheckBackLaterOperationParams.safeParse(params)
    if (!result.success) {
      for (const issue of result.error.issues) {
        context.addIssue({ code: 'custom', path: issue.path, message: issue.message })
      }
    }
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
  quiet_success: z.boolean().optional()
})

const CronParams = z
  .object({
    action: z.enum(['list', 'get', 'runs', 'add', 'update', 'pause', 'resume', 'remove', 'run']),
    name: z.string().min(1).optional(),
    schedule: z.union([EverySchedule, CronSchedule]).optional(),
    payload: JSONMap.optional(),
    delivery: DeliveryParams.optional(),
    limit: z.number().int().positive().max(100).optional()
  })
  .superRefine((params, context) => {
    if (params.action !== 'list' && !params.name?.trim()) {
      context.addIssue({ code: 'custom', path: ['name'], message: `${params.action} requires name` })
    }
    if (params.action === 'add' && !params.schedule) {
      context.addIssue({ code: 'custom', path: ['schedule'], message: 'add requires schedule' })
    }
    if (
      params.action === 'update' &&
      params.schedule === undefined &&
      params.payload === undefined &&
      params.delivery === undefined
    ) {
      context.addIssue({ code: 'custom', path: ['action'], message: 'update requires a changed field' })
    }
  })

const CronOriginReadParams = z.object({
  action: z.enum(['list', 'get', 'runs']),
  name: z.string().min(1).optional(),
  limit: z.number().int().positive().max(100).optional()
})

const CronOriginReadActions = new Set<z.output<typeof CronParams>['action']>(['list', 'get', 'runs'])

/**
 * Creates the scheduling tools over the turn's schedule RPC seam.
 */
export function createScheduleTools(opts: CreateScheduleToolsOptions): AgentTool<any>[] {
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
    description: [
      'Manage one-shot delayed self-wakeups for this conversation: create, list, inspect, update, or cancel pending checkbacks.',
      'Use this tool when the user asks you to wait, remind yourself, follow up later, re-check something after time passes, or changes/revokes an already scheduled checkback.',
      'Use list/get before update/cancel when you do not know the checkback_id.',
      'For create provide reason, check, and schedule. For get/update/cancel provide checkback_id; update also requires a non-empty updates object.',
      'For create/update schedules, use at for a named clock time, market close, deadline, or exact instant; use after only for a genuinely relative delay.',
      'A conversational correction does not change durable work by itself. Never claim a checkback was created, updated, or cancelled until the corresponding tool action returns a confirmed result.',
      'Checkbacks are visible by default. Use quiet_success=true only when the user explicitly asked not to be notified for normal or unchanged outcomes.'
    ].join('\n'),
    schema: CheckBackLaterParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => '安排后续工作',
    async execute(toolCallID, params): Promise<AgentToolResult<ScheduleToolDetails>> {
      const operation = CheckBackLaterOperationParams.parse(params)
      const call = opts.requestScheduleRPC

      const response = await match(operation)
        .with({ action: 'list' }, value =>
          call(rpcMethods.scheduleCheckBackLaterList, value.limit ? { limit: value.limit } : {})
        )
        .with({ action: 'get' }, value =>
          call(rpcMethods.scheduleCheckBackLaterGet, { scheduledEventId: modelIntegerIDToWire(value.checkback_id) })
        )
        .with({ action: 'create' }, value => {
          const replyRoute = requiredCheckBackReplyRoute(opts.turnStart)
          return call(rpcMethods.scheduleCheckBackLaterCreate, {
            toolCallId: toolCallID,
            idempotencyKey: defaultCheckBackIdempotencyKey(opts.turnStart, value),
            reason: value.reason,
            check: value.check,
            contextSummary: value.context_summary ?? '',
            quietSuccess: value.quiet_success === true,
            scheduleJson: jsonBytes(value.schedule),
            replyRouteJson: jsonBytes(replyRoute)
          })
        })
        .with({ action: 'update' }, value => {
          const replyRoute = requiredCheckBackReplyRoute(opts.turnStart)
          return call(rpcMethods.scheduleCheckBackLaterUpdate, {
            scheduledEventId: modelIntegerIDToWire(value.checkback_id),
            toolCallId: toolCallID,
            idempotencyKey: defaultCheckBackUpdateIdempotencyKey(opts.turnStart, value),
            updatesJson: jsonBytes(value.updates),
            replyRouteJson: jsonBytes(replyRoute)
          })
        })
        .with({ action: 'cancel' }, value =>
          call(rpcMethods.scheduleCheckBackLaterCancel, { scheduledEventId: modelIntegerIDToWire(value.checkback_id) })
        )
        .exhaustive()

      return jsonToolResult(response, {
        presentation: checkBackEffectPresentation(operation)
      })
    }
  }
}

/**
 * Builds the default idempotency key for a delayed checkback request.
 *
 * Provider/tool retries should create one schedule, not duplicate wakeups. The
 * key is stable for the actor event and semantic schedule payload.
 */
function defaultCheckBackIdempotencyKey(turnStart: TurnStart, params: z.output<typeof CheckBackCreateParams>): string {
  const stableInput = {
    actor_event_id: turnStart.turn.actor_event_id,
    reason: params.reason.trim(),
    check: params.check.trim(),
    context_summary: params.context_summary?.trim() ?? '',
    ...(params.quiet_success === true ? { quiet_success: true } : {}),
    schedule: params.schedule
  }

  return `check_back_later:${turnStart.turn.actor_event_id}:${stableHash(stableInput)}`
}

function defaultCheckBackUpdateIdempotencyKey(
  turnStart: TurnStart,
  params: Extract<z.output<typeof CheckBackLaterOperationParams>, { action: 'update' }>
): string {
  const stableInput = {
    actor_event_id: turnStart.turn.actor_event_id,
    checkback_id: params.checkback_id,
    updates: params.updates
  }

  return `check_back_later:update:${params.checkback_id}:${turnStart.turn.actor_event_id}:${stableHash(stableInput)}`
}

/**
 * Builds the recurring schedule management tool.
 */
function createCronTool(
  opts: CreateScheduleToolsOptions
): AgentTool<typeof CronParams | typeof CronOriginReadParams, ScheduleToolDetails> {
  const cronOrigin = isCronOriginTurn(opts.turnStart)

  return {
    name: 'cron',
    description: cronOrigin
      ? 'Inspect recurring schedules for this conversation. This cron-origin turn can only list schedules, inspect one schedule, or view its run history.'
      : CRON_DESCRIPTION,
    schema: cronOrigin ? CronOriginReadParams : CronParams,
    executionMode: 'sequential',
    isReadOnly: cronOrigin,
    isDestructive: false,
    describeActivity: () => '安排后续工作',
    async execute(toolCallID, params): Promise<AgentToolResult<ScheduleToolDetails>> {
      rejectCronOriginMutation(params, opts.turnStart)
      const call = opts.requestScheduleRPC
      const target = () => ({ name: requiredCronScheduleName(params, cronOrigin) })

      // Method and payload for one action stay in a single branch so the RPC
      // contract types check each shape exactly.
      const response = await match(params.action)
        .with('list', () => call(rpcMethods.scheduleCronList, {}))
        .with('get', () => call(rpcMethods.scheduleCronGet, target()))
        .with('pause', () => call(rpcMethods.scheduleCronPause, target()))
        .with('resume', () => call(rpcMethods.scheduleCronResume, target()))
        .with('remove', () => call(rpcMethods.scheduleCronRemove, target()))
        .with('run', () => call(rpcMethods.scheduleCronRun, target()))
        .with('runs', () =>
          call(rpcMethods.scheduleCronRuns, { ...target(), ...(params.limit ? { limit: params.limit } : {}) })
        )
        .with('add', () => call(rpcMethods.scheduleCronAdd, cronAddPayload(params, opts.turnStart)))
        .with('update', () =>
          call(rpcMethods.scheduleCronUpdate, {
            ...target(),
            updatesJson: jsonBytes(cronUpdates(params, opts.turnStart))
          })
        )
        .exhaustive()

      return jsonToolResult(response, {
        presentation: cronEffectPresentation(params)
      })
    }
  }
}

function checkBackEffectPresentation(
  params: z.output<typeof CheckBackLaterOperationParams>
): AgentToolResult<ScheduleToolDetails>['presentation'] {
  if (params.action === 'create') {
    return [
      {
        kind: 'effect.receipt',
        payload: {
          phase: 'confirmed',
          summary: '已安排后续检查',
          scope: checkBackScheduleScope(params.schedule),
          follow_up: params.quiet_success === true ? '仅在异常、阻塞或有变化时通知' : '到时会反馈检查结果'
        }
      }
    ]
  }

  if (params.action === 'update') {
    return [
      {
        kind: 'effect.receipt',
        payload: compactRecord({
          phase: 'confirmed',
          summary: '已更新后续检查',
          target: params.checkback_id,
          scope: params.updates.schedule ? checkBackScheduleScope(params.updates.schedule) : undefined,
          follow_up:
            params.updates.quiet_success === true
              ? '仅在异常、阻塞或有变化时通知'
              : params.updates.quiet_success === false
                ? '到时会反馈检查结果'
                : undefined
        })
      }
    ]
  }

  if (params.action === 'cancel') {
    return [
      {
        kind: 'effect.receipt',
        payload: {
          phase: 'confirmed',
          summary: '已取消后续检查',
          target: params.checkback_id
        }
      }
    ]
  }

  return []
}

function checkBackScheduleScope(schedule: z.output<typeof CheckBackSchedule>): string {
  if ('at' in schedule) return schedule.timezone ? `${schedule.at} (${schedule.timezone})` : schedule.at

  const after = schedule.after
  const unit =
    {
      millisecond: '毫秒',
      second: '秒',
      minute: '分钟',
      hour: '小时',
      day: '天',
      week: '周'
    }[after.unit] ?? after.unit

  return `${after.value} ${unit}后`
}

function requiredCheckBackReplyRoute(turnStart: TurnStart): ReplyRoute {
  const replyRoute = currentReplyRoute(turnStart)
  if (!replyRoute) {
    throw new Error('check_back_later create/update requires a provider reply route from the current turn')
  }
  return replyRoute
}

function cronEffectPresentation(
  params: z.output<typeof CronParams>
): AgentToolResult<ScheduleToolDetails>['presentation'] {
  const summaries: Partial<Record<z.output<typeof CronParams>['action'], string>> = {
    add: '已创建定期任务',
    update: '已更新定期任务',
    pause: '已暂停定期任务',
    resume: '已恢复定期任务',
    remove: '已删除定期任务',
    run: '已启动一次定期任务运行'
  }
  const summary = summaries[params.action]

  if (!summary) return []

  return [
    {
      kind: 'effect.receipt',
      payload: compactRecord({
        phase: 'confirmed',
        summary,
        target: params.name?.trim() || undefined,
        scope: cronScheduleScope(params.schedule),
        follow_up: params.delivery?.quiet_success === true ? '常规成功时保持安静，异常或变化会通知' : undefined
      })
    }
  ]
}

function cronScheduleScope(schedule: z.output<typeof EverySchedule> | z.output<typeof CronSchedule> | undefined) {
  if (!schedule) return undefined
  if (schedule.kind === 'every') return `每 ${humanInterval(schedule.every_ms)}`
  return schedule.timezone ? `${schedule.expression} (${schedule.timezone})` : schedule.expression
}

function humanInterval(milliseconds: number): string {
  const units = [
    { milliseconds: 7 * 24 * 60 * 60 * 1000, label: '周' },
    { milliseconds: 24 * 60 * 60 * 1000, label: '天' },
    { milliseconds: 60 * 60 * 1000, label: '小时' },
    { milliseconds: 60 * 1000, label: '分钟' },
    { milliseconds: 1000, label: '秒' }
  ]

  const exact = units.find(unit => milliseconds >= unit.milliseconds && milliseconds % unit.milliseconds === 0)
  return exact ? `${milliseconds / exact.milliseconds} ${exact.label}` : `${milliseconds} 毫秒`
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
 * Builds the payload for creating a recurring schedule.
 *
 * The current reply route is reused by default so scheduled fires know where to
 * reply without the model repeating provider routing fields.
 */
function cronAddPayload(
  params: z.output<typeof CronParams>,
  turnStart: TurnStart
): RPCRequestInit<'schedule.cron.add'> {
  if (!params.schedule) throw new Error('cron add requires schedule')
  const route = currentReplyRoute(turnStart)
  const bindingName = route?.binding_name
  if (!bindingName) throw new Error('cron add requires a current provider binding')
  if (!params.name?.trim()) throw new Error('cron add requires name')

  return {
    bindingName,
    name: params.name.trim(),
    scheduleJson: jsonBytes(params.schedule),
    payloadJson: jsonBytes(params.payload ?? {}),
    deliveryJson: jsonBytes(cronDelivery(params, route)),
    idempotencyKey: defaultCronAddIdempotencyKey(turnStart, params, bindingName, route)
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
function cronUpdates(params: z.output<typeof CronParams>, turnStart: TurnStart): JSONObject {
  const route = currentReplyRoute(turnStart)
  const updates: JSONObject = {}
  if (params.schedule !== undefined) updates.schedule = params.schedule
  if (params.payload !== undefined) updates.payload = params.payload
  if (params.delivery !== undefined) updates.delivery = cronDelivery(params, route)
  return updates
}

/**
 * Merges explicit delivery options with the current provider reply route.
 */
function cronDelivery(params: z.output<typeof CronParams>, route: ReplyRoute | undefined): JSONObject | undefined {
  const delivery = {
    ...(route?.signal_channel_id ? { signal_channel_id: route.signal_channel_id } : {}),
    ...(route?.provider_thread_id ? { provider_thread_id: route.provider_thread_id } : {}),
    ...(params.delivery?.quiet_success !== undefined ? { quiet_success: params.delivery.quiet_success } : {})
  }
  return Object.keys(delivery).length > 0 ? delivery : undefined
}

/**
 * Reads the stable cron schedule name for actions that target one schedule.
 */
function requiredCronScheduleName(
  params: z.output<typeof CronParams> | z.output<typeof CronOriginReadParams>,
  allowOrigin: boolean
): string {
  const name = params.name?.trim()
  if (name) return name
  if (allowOrigin) return ''
  throw new Error(`${params.action} requires name`)
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
  return createHash('sha256').update(stableJSON(value)).digest('hex').slice(0, 16)
}

/**
 * Serializes JSON with stable object key order.
 */
function stableJSON(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(stableJSON).join(',')}]`
  }

  if (value && typeof value === 'object') {
    const entries = Object.entries(value as JSONObject).sort(([left], [right]) => left.localeCompare(right))
    return `{${entries.map(([key, entry]) => `${JSON.stringify(key)}:${stableJSON(entry)}`).join(',')}}`
  }

  return JSON.stringify(value) ?? 'null'
}
