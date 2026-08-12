import { createHash } from 'node:crypto'
import { compactRecord, match } from '@agentbull/active-support'
import { z } from 'zod'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import type { TurnStart } from '../../lanes/actor_lane'
import type { AgentTool, AgentToolResult } from '../../core'
import { currentReplyRoute, type ReplyRoute } from '../../core/turns/reply_route'
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
const AUTOMATION_JOB_POINTER =
  "If you judge that a script you write could perform this trigger's check equally well and at lower token cost than waking you each time, run `create-automation-job-cli --help` before creating the trigger to confirm the fit. The script can still wake you when its result needs judgment."
const CRON_DESCRIPTION = [
  'Manage recurring schedules created from this conversation (list, inspect, create, update, pause, resume, remove, run, view history).',
  'Use when asked about standing work, recurring tasks, monitors, routines, scheduled jobs, or cron follow-ups.',
  'Each schedule runs in its own scheduled-task session, not in this conversation: fires never see this transcript, and Ankole delivers their replies to the configured channel.',
  'payload.task must therefore carry the complete standing instruction (goal, inputs, constraints, output form) unless automation_job_id consumes the trigger.',
  'Supports kind=every/cron only. For bounded repetitions ("ten times", "until Sept"), set schedule.occurrences with count/until (auto-completes when spent).',
  "Updating payload or delivery clears the schedule's own run history; schedule/timezone changes keep it.",
  'After add/update, summarize in visible reply: name, schedule/timezone, and quiet_success status.',
  'Use quiet_success=true for monitors to stay quiet on success and report only failures, blockers, or state changes.',
  AUTOMATION_JOB_POINTER,
  'In principle, a polling interval of less than 30 minutes should only be used for script tasks (create-automation-job), as frequently waking up an LLM can be quite costly.'
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
    ),
  automation_job_id: ModelIntegerID.optional().describe(
    'Optional automation job that consumes this trigger instead of waking this conversation directly.'
  )
})

const CheckBackUpdateParams = z
  .object({
    action: z.literal('update'),
    checkback_id: ModelIntegerID,
    reason: z.string().min(1).max(2000).optional(),
    check: z.string().min(1).max(4000).optional(),
    context_summary: z.string().max(8000).nullable().optional(),
    schedule: CheckBackSchedule.optional(),
    quiet_success: z.boolean().optional(),
    automation_job_id: ModelIntegerID.nullable().optional()
  })
  .refine(params => checkBackUpdatesFromFlat(params) !== undefined, {
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
  CheckBackUpdateParams,
  z.object({
    action: z.literal('cancel'),
    checkback_id: ModelIntegerID
  })
])

// OpenAI-compatible function tools require the parameters schema itself to be
// an object. Keep the precise per-action validator above for execution, but
// expose one object-shaped model boundary instead of a root-level `oneOf`.
// Update reuses the create-shaped fields: only provided fields change.
const CheckBackLaterParams = z
  .object({
    action: z.enum(['create', 'list', 'get', 'update', 'cancel']).describe('Checkback management action.'),
    checkback_id: ModelIntegerID.optional().describe(
      'Required for get, update, and cancel. Use list first when the id is unknown.'
    ),
    reason: z.string().min(1).max(2000).optional().describe('Required for create: why the checkback is useful.'),
    check: z.string().min(1).max(4000).optional().describe('Required for create: what to do at wakeup.'),
    context_summary: z
      .string()
      .max(8000)
      .nullable()
      .optional()
      .describe('Optional compact context carried to the wakeup. On update, null clears it.'),
    schedule: CheckBackSchedule.optional().describe('Required for create: the one-shot wakeup time.'),
    quiet_success: z
      .boolean()
      .optional()
      .describe(
        'Allow finishing without a visible reply when nothing needs attention. Set true only when the user explicitly asked for no update on normal/no-change outcomes; failures, blockers, human decisions, meaningful changes, and time-sensitive risks stay visible.'
      ),
    automation_job_id: ModelIntegerID.nullable()
      .optional()
      .describe('Optional automation job that consumes this trigger. On update, null detaches it.'),
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

/**
 * Collects the explicitly provided update fields, preserving null as "clear".
 * Returns undefined when the update carries no field.
 */
function checkBackUpdatesFromFlat(params: {
  reason?: string
  check?: string
  context_summary?: string | null
  schedule?: z.output<typeof CheckBackSchedule>
  quiet_success?: boolean
  automation_job_id?: number | null
}): JSONObject | undefined {
  const updates: JSONObject = {}
  if (params.reason !== undefined) updates.reason = params.reason
  if (params.check !== undefined) updates.check = params.check
  if (params.context_summary !== undefined) updates.context_summary = params.context_summary
  if (params.schedule !== undefined) updates.schedule = params.schedule
  if (params.quiet_success !== undefined) updates.quiet_success = params.quiet_success
  if (params.automation_job_id !== undefined) updates.automation_job_id = params.automation_job_id
  return Object.keys(updates).length > 0 ? updates : undefined
}

const ScheduleOccurrences = z
  .union([z.object({ count: z.number().int().positive() }).strict(), z.object({ until: z.string().min(1) }).strict()])
  .describe(
    'Optional finite bound for the recurrence: count is a budget of due occurrences (a due occurrence spends it whether its delivery then succeeds or fails; retries of one occurrence spend nothing more), until is an inclusive cutoff instant (ISO 8601, or a local wall-clock time resolved in the schedule timezone). Give one or the other, never both. The schedule reports status completed once the bound is spent.'
  )

const EverySchedule = z.object({
  kind: z.literal('every'),
  every_ms: z.number().int().positive(),
  anchor_at: z.string(),
  occurrences: ScheduleOccurrences.optional()
})

const CronSchedule = z.object({
  kind: z.literal('cron'),
  expression: z.string().min(1),
  timezone: z.string().optional(),
  occurrences: ScheduleOccurrences.optional()
})

const DeliveryParams = z.object({
  quiet_success: z.boolean().optional()
})

const CronParams = z
  .object({
    action: z.enum(['list', 'get', 'runs', 'add', 'update', 'pause', 'resume', 'remove', 'run']),
    name: z.string().min(1).optional(),
    schedule: z.union([EverySchedule, CronSchedule]).optional(),
    payload: JSONMap.optional().describe(
      'Schedule input. For a direct-Agent schedule, task (string) must carry the complete standing instruction: fires run outside this conversation and see only this payload.'
    ),
    delivery: DeliveryParams.optional(),
    automation_job_id: ModelIntegerID.nullable().optional(),
    limit: z.number().int().positive().max(100).optional()
  })
  .superRefine((params, context) => {
    if (params.action !== 'list' && !params.name?.trim()) {
      context.addIssue({ code: 'custom', path: ['name'], message: `${params.action} requires name` })
    }
    if (params.action === 'add' && !params.schedule) {
      context.addIssue({ code: 'custom', path: ['schedule'], message: 'add requires schedule' })
    }
    if (params.action === 'add' && params.automation_job_id == null) {
      const task = params.payload?.task
      if (typeof task !== 'string' || !task.trim()) {
        context.addIssue({
          code: 'custom',
          path: ['payload', 'task'],
          message: 'add requires payload.task: a self-contained instruction the fire can run without this conversation'
        })
      }
    }
    if (
      params.action === 'update' &&
      params.schedule === undefined &&
      params.payload === undefined &&
      params.delivery === undefined &&
      params.automation_job_id === undefined
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
      'Manage one-shot delayed self-wakeups for this conversation (create, list, inspect, update, cancel pending checkbacks).',
      'Use when asked to wait, remind yourself, follow up later, re-check after time passes, or modify/cancel scheduled checkbacks.',
      'update only modifies provided fields.',
      "Conversational corrections alone don't change durable work. Never claim creation, update, or cancellation until tool confirms success.",
      AUTOMATION_JOB_POINTER
    ].join('\n'),
    schema: CheckBackLaterParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.schedule_follow_up' }),
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
            replyRouteJson: jsonBytes(replyRoute),
            ...(value.automation_job_id === undefined
              ? {}
              : { automationJobId: modelIntegerIDToWire(value.automation_job_id) })
          })
        })
        .with({ action: 'update' }, value => {
          const replyRoute = requiredCheckBackReplyRoute(opts.turnStart)
          const updates = checkBackUpdatesFromFlat(value)
          if (!updates) throw new Error('provide at least one checkback update')
          return call(rpcMethods.scheduleCheckBackLaterUpdate, {
            scheduledEventId: modelIntegerIDToWire(value.checkback_id),
            toolCallId: toolCallID,
            idempotencyKey: defaultCheckBackUpdateIdempotencyKey(opts.turnStart, value.checkback_id, updates),
            updatesJson: jsonBytes(updates),
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
    ...(params.automation_job_id === undefined ? {} : { automation_job_id: params.automation_job_id }),
    schedule: params.schedule
  }

  return `check_back_later:${turnStart.turn.actor_event_id}:${stableHash(stableInput)}`
}

function defaultCheckBackUpdateIdempotencyKey(turnStart: TurnStart, checkbackID: number, updates: JSONObject): string {
  const stableInput = {
    actor_event_id: turnStart.turn.actor_event_id,
    checkback_id: checkbackID,
    updates
  }

  return `check_back_later:update:${checkbackID}:${turnStart.turn.actor_event_id}:${stableHash(stableInput)}`
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
      ? "Inspect this turn's own recurring schedule. A cron-origin turn sees exactly the schedule that fired it (list/get/runs) and cannot create or change schedules."
      : CRON_DESCRIPTION,
    schema: cronOrigin ? CronOriginReadParams : CronParams,
    executionMode: 'sequential',
    isReadOnly: cronOrigin,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.schedule_follow_up' }),
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
        .with('run', () => call(rpcMethods.scheduleCronRun, { ...target(), toolCallId: toolCallID }))
        .with('runs', () =>
          call(rpcMethods.scheduleCronRuns, { ...target(), ...(params.limit ? { limit: params.limit } : {}) })
        )
        .with('add', () => call(rpcMethods.scheduleCronAdd, cronAddPayload(params, opts.turnStart)))
        .with('update', () =>
          call(rpcMethods.scheduleCronUpdate, {
            ...target(),
            updatesJson: jsonBytes(cronUpdates(params))
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
          summary_key: 'signals_gateway.reply.activity.check_back_created',
          ...localizedReceiptField('scope', checkBackScheduleScope(params.schedule)),
          follow_up_key:
            params.quiet_success === true
              ? 'signals_gateway.reply.activity.notify_on_change'
              : 'signals_gateway.reply.activity.report_check_result'
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
          summary_key: 'signals_gateway.reply.activity.check_back_updated',
          target: params.checkback_id,
          ...(params.schedule ? localizedReceiptField('scope', checkBackScheduleScope(params.schedule)) : {}),
          follow_up_key:
            params.quiet_success === true
              ? 'signals_gateway.reply.activity.notify_on_change'
              : params.quiet_success === false
                ? 'signals_gateway.reply.activity.report_check_result'
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
          summary_key: 'signals_gateway.reply.activity.check_back_cancelled',
          target: params.checkback_id
        }
      }
    ]
  }

  return []
}

function checkBackScheduleScope(schedule: z.output<typeof CheckBackSchedule>): LocalizedPresentationText | string {
  if ('at' in schedule) return schedule.timezone ? `${schedule.at} (${schedule.timezone})` : schedule.at

  const after = schedule.after
  return {
    key: `signals_gateway.reply.activity.schedule_after_${after.unit}`,
    bindings: { value: after.value }
  }
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
    add: 'signals_gateway.reply.activity.cron_created',
    update: 'signals_gateway.reply.activity.cron_updated',
    pause: 'signals_gateway.reply.activity.cron_paused',
    resume: 'signals_gateway.reply.activity.cron_resumed',
    remove: 'signals_gateway.reply.activity.cron_removed',
    run: 'signals_gateway.reply.activity.cron_run_started'
  }
  const summary = summaries[params.action]

  if (!summary) return []

  return [
    {
      kind: 'effect.receipt',
      payload: compactRecord({
        phase: 'confirmed',
        summary_key: summary,
        target: params.name?.trim() || undefined,
        ...localizedReceiptField('scope', cronScheduleScope(params.schedule)),
        follow_up_key:
          params.delivery?.quiet_success === true ? 'signals_gateway.reply.activity.quiet_success' : undefined
      })
    }
  ]
}

function cronScheduleScope(
  schedule: z.output<typeof EverySchedule> | z.output<typeof CronSchedule> | undefined
): LocalizedPresentationText | string | undefined {
  if (!schedule) return undefined
  if (schedule.kind === 'every') return humanInterval(schedule.every_ms)
  return schedule.timezone ? `${schedule.expression} (${schedule.timezone})` : schedule.expression
}

function humanInterval(milliseconds: number): LocalizedPresentationText {
  const units = [
    { milliseconds: 7 * 24 * 60 * 60 * 1000, unit: 'week' },
    { milliseconds: 24 * 60 * 60 * 1000, unit: 'day' },
    { milliseconds: 60 * 60 * 1000, unit: 'hour' },
    { milliseconds: 60 * 1000, unit: 'minute' },
    { milliseconds: 1000, unit: 'second' }
  ]

  const exact = units.find(unit => milliseconds >= unit.milliseconds && milliseconds % unit.milliseconds === 0)
  return {
    key: `signals_gateway.reply.activity.schedule_every_${exact?.unit ?? 'millisecond'}`,
    bindings: { value: exact ? milliseconds / exact.milliseconds : milliseconds }
  }
}

type LocalizedPresentationText = { key: string; bindings?: JSONObject }

function localizedReceiptField(field: 'scope', text: LocalizedPresentationText | string | undefined): JSONObject {
  if (!text) return {}
  if (typeof text === 'string') return { [field]: text }
  return {
    [`${field}_key`]: text.key,
    ...(text.bindings ? { [`${field}_bindings`]: text.bindings } : {})
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
    idempotencyKey: defaultCronAddIdempotencyKey(turnStart, params, bindingName, route),
    ...(params.automation_job_id == null ? {} : { automationJobId: modelIntegerIDToWire(params.automation_job_id) })
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
    delivery: cronDelivery(params, route) ?? {},
    automation_job_id: params.automation_job_id ?? null
  }

  return `cron:add:${turnStart.turn.actor_event_id}:${stableHash(stableInput)}`
}

/**
 * Builds the partial update object for cron update actions.
 */
function cronUpdates(params: z.output<typeof CronParams>): JSONObject {
  const updates: JSONObject = {}
  if (params.schedule !== undefined) updates.schedule = params.schedule
  if (params.payload !== undefined) updates.payload = params.payload
  if (params.delivery !== undefined) updates.delivery = params.delivery
  if (params.automation_job_id !== undefined) updates.automation_job_id = params.automation_job_id
  return updates
}

/**
 * Builds the canonical delivery list from the current provider reply route.
 */
function cronDelivery(params: z.output<typeof CronParams>, route: ReplyRoute | undefined): JSONObject | undefined {
  const target = {
    ...(route?.binding_name ? { binding_name: route.binding_name } : {}),
    ...(route?.signal_channel_id ? { signal_channel_id: route.signal_channel_id } : {}),
    ...(route?.provider_thread_id ? { provider_thread_id: route.provider_thread_id } : {})
  }
  const delivery = {
    ...(target.binding_name && target.signal_channel_id ? { targets: [target] } : {}),
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
