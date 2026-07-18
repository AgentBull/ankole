import { match, type JsonObject as JSONObject } from '@pleisto/active-support'
import { z } from 'zod'
import { truncateUTF8Safe, utf8ByteLength } from '../../common/text-sanitize'
import type { AgentTool, AgentToolResult } from '../../core'
import type { TurnStart } from '../../lanes/actor_lane'
import { jsonBytes, jsonObjectFromBytes } from '../../fabric/envelope_proto'
import {
  rpcMethods,
  type BackgroundAgentJobExecution,
  type BackgroundAgentJobListResponse,
  type BackgroundAgentJobResponse,
  type AgentPluginCatalogEntry,
  type RPCRequester,
  type RPCRequestInit
} from '../../lanes/rpc_lane'

const identifier = /^[a-z][a-z0-9_-]{0,63}$/
const contentHash = /^[a-f0-9]{64}$/

// Validates generated catalog messages; non-strict so the message runtime
// fields ($typeName) pass through while unknown data keys are still dropped.
const CatalogEntrySchema = z.object({
  id: z.string().regex(identifier),
  description: z.string().min(1),
  version: z.string().min(1),
  contentHash: z.string().regex(contentHash),
  skills: z.array(
    z.object({
      catalogName: z.string().min(1),
      codexName: z.string().min(1)
    })
  )
})

const WorkspaceMountSchema = z
  .object({
    id: z.string().regex(identifier).describe('Stable mount id used under /workspace/workspaces/<id>.'),
    source: z
      .string()
      .refine(
        value =>
          value.startsWith('/workspace/user-files/') &&
          !value.split('/').some(segment => segment === '.' || segment === '..') &&
          !value.includes('//'),
        {
          message: 'workspace mount source must be a normalized path inside /workspace/user-files/'
        }
      )
      .describe('Absolute caller-owned path inside /workspace/user-files/.'),
    access: z.enum(['read_only', 'read_write'])
  })
  .strict()

type BackgroundAgentJobToolDetails = BackgroundAgentJobResponse | BackgroundAgentJobListResponse

export type BackgroundAgentJobToolOptions = {
  turnStart: TurnStart
  agentPluginCatalog: AgentPluginCatalogEntry[]
  standaloneSkillNames: string[]
  rpc: RPCRequester
}

export function createBackgroundAgentJobTool(
  opts: BackgroundAgentJobToolOptions
): AgentTool<ReturnType<typeof backgroundAgentJobParamsSchema>, BackgroundAgentJobToolDetails> {
  const catalog = parseCatalog(opts.agentPluginCatalog)
  const standaloneSkillNames = uniqueSortedNames(opts.standaloneSkillNames, 'standalone Skill')
  const schema = backgroundAgentJobParamsSchema(catalog, standaloneSkillNames)

  return {
    name: 'background_agent_job',
    description: descriptionFor(catalog, standaloneSkillNames),
    schema,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: () => '协调后台任务',
    async execute(toolCallID, params): Promise<AgentToolResult<BackgroundAgentJobToolDetails>> {
      const details = await executeBackgroundAgentJob(toolCallID, params, opts)
      return {
        content: [{ type: 'text', text: visibleResult(details, params.action === 'status') }],
        details
      }
    }
  }
}

function backgroundAgentJobParamsSchema(catalog: CatalogEntry[], standaloneSkillNames: string[]) {
  const agentPluginIDs = catalog.map(agentPlugin => agentPlugin.id)

  return z
    .object({
      action: z.enum(['start', 'list', 'status', 'steer', 'stop']),
      title: z.string().min(1).max(200).describe('Short task-board title for start.').optional(),
      task: z
        .string()
        .min(1)
        .describe(
          'Complete self-contained task. Include every requirement, constraint, exact path, output language, and acceptance criterion.'
        )
        .optional(),
      background: z.string().min(1).describe('Relevant context for start; do not repeat task requirements.').optional(),
      notes: z.string().min(1).describe('Execution cautions for start; do not put task requirements here.').optional(),
      agent_plugin_ids: z
        .array(dynamicEnum(agentPluginIDs, 'enabled Agent Plugin'))
        .max(16)
        .describe(`${agentPluginCatalogDescription(catalog)} Select only ids from this live enabled catalog.`)
        .optional(),
      skill_names: z
        .array(dynamicEnum(standaloneSkillNames, 'enabled standalone Skill'))
        .max(256)
        .describe(standaloneSkillDescription(standaloneSkillNames))
        .optional(),
      workspace_mounts: z
        .array(WorkspaceMountSchema)
        .min(1)
        .max(16)
        .describe(
          'Explicit caller workspace mounts. Omit for the managed writable workspace mounted as /workspace/workspaces/workspace.'
        )
        .optional(),
      model: z.string().min(1).describe('Exact Codex model override for this Job.').optional(),
      reasoning_effort: z
        .enum(['minimal', 'low', 'medium', 'high', 'xhigh'])
        .describe('Exact Codex reasoning effort override for this Job.')
        .optional(),
      job_id: z.string().uuid().describe('BackgroundAgentJob id for status, steer, or stop.').optional(),
      text: z.string().min(1).describe('Steering instructions, or an optional stop reason.').optional(),
      answers: z
        .record(z.string(), z.union([z.string(), z.array(z.string())]))
        .describe('Answers keyed by pending user-input question id for steer.')
        .optional(),
      trajectory_limit: z
        .number()
        .int()
        .min(1)
        .max(20)
        .describe('Semantic trajectory groups to return for status. Defaults to 3.')
        .optional(),
      trajectory_cursor: z
        .string()
        .min(1)
        .describe('Opaque status cursor for the immediately older trajectory page.')
        .optional()
    })
    .strict()
    .superRefine((params, context) => {
      refineActionFields(params, context)
      refineUnique(params.agent_plugin_ids, 'agent_plugin_ids', context)
      refineUnique(params.skill_names, 'skill_names', context)
      refineUnique(
        params.workspace_mounts?.map(mount => mount.id),
        'workspace_mounts ids',
        context
      )
    })
}

type BackgroundAgentJobParams = z.output<ReturnType<typeof backgroundAgentJobParamsSchema>>

async function executeBackgroundAgentJob(
  toolCallID: string,
  params: BackgroundAgentJobParams,
  opts: BackgroundAgentJobToolOptions
): Promise<BackgroundAgentJobToolDetails> {
  const turn = opts.turnStart.turn

  return match(params.action)
    .with('start', async () => {
      const request: RPCRequestInit<'background_agent_job.create'> = {
        sourceToolCallId: toolCallID,
        title: requiredText(params.title, 'start requires title'),
        task: requiredVerbatimText(params.task, 'start requires task'),
        background: params.background ?? '',
        notes: params.notes ?? '',
        agentPluginIds: params.agent_plugin_ids ?? [],
        skillNames: params.skill_names ?? [],
        workspaceMounts: params.workspace_mounts ?? [],
        model: params.model ?? '',
        reasoningEffort: params.reasoning_effort ?? ''
      }
      return await opts.rpc(rpcMethods.backgroundAgentJobCreate, request, { turn })
    })
    .with('list', async () => {
      return await opts.rpc(rpcMethods.backgroundAgentJobList, {}, { turn })
    })
    .with('status', async () => {
      return await opts.rpc(
        rpcMethods.backgroundAgentJobGet,
        {
          jobId: requiredJobID(params),
          trajectoryLimit: params.trajectory_limit,
          trajectoryCursor: params.trajectory_cursor ?? ''
        },
        { turn }
      )
    })
    .with('steer', async () => {
      return await opts.rpc(
        rpcMethods.backgroundAgentJobSteer,
        {
          jobId: requiredJobID(params),
          text: params.text ?? '',
          ...(params.answers ? { answersJson: jsonBytes(params.answers) } : {})
        },
        { turn }
      )
    })
    .with('stop', async () => {
      return await opts.rpc(
        rpcMethods.backgroundAgentJobStop,
        { jobId: requiredJobID(params), reason: params.text ?? '' },
        { turn }
      )
    })
    .exhaustive()
}

function refineActionFields(params: BackgroundAgentJobParams, context: z.RefinementCtx): void {
  const startFields = [
    'title',
    'task',
    'background',
    'notes',
    'agent_plugin_ids',
    'skill_names',
    'workspace_mounts',
    'model',
    'reasoning_effort'
  ] as const

  if (params.action === 'start') {
    if (!params.title?.trim()) context.addIssue({ code: 'custom', path: ['title'], message: 'start requires title' })
    if (!params.task?.trim()) context.addIssue({ code: 'custom', path: ['task'], message: 'start requires task' })
  } else {
    for (const field of startFields) {
      if (params[field] !== undefined) {
        context.addIssue({ code: 'custom', path: [field], message: `${field} is only valid for start` })
      }
    }
  }

  if (params.action === 'status') {
    if (!params.job_id) context.addIssue({ code: 'custom', path: ['job_id'], message: 'status requires job_id' })
  } else if (params.trajectory_limit !== undefined || params.trajectory_cursor !== undefined) {
    context.addIssue({
      code: 'custom',
      message: 'trajectory_limit and trajectory_cursor are only valid for status'
    })
  }

  if (params.action === 'steer') {
    if (!params.job_id) context.addIssue({ code: 'custom', path: ['job_id'], message: 'steer requires job_id' })
    if (!params.text && (!params.answers || Object.keys(params.answers).length === 0)) {
      context.addIssue({ code: 'custom', message: 'steer requires text or answers' })
    }
  }

  if (params.action === 'stop' && !params.job_id) {
    context.addIssue({ code: 'custom', path: ['job_id'], message: 'stop requires job_id' })
  }
  if ((params.action === 'start' || params.action === 'list') && params.job_id !== undefined) {
    context.addIssue({ code: 'custom', path: ['job_id'], message: `job_id is not valid for ${params.action}` })
  }
  if (params.action !== 'steer' && params.answers !== undefined) {
    context.addIssue({ code: 'custom', path: ['answers'], message: 'answers is only valid for steer' })
  }
  if (params.action !== 'steer' && params.action !== 'stop' && params.text !== undefined) {
    context.addIssue({ code: 'custom', path: ['text'], message: 'text is only valid for steer or stop' })
  }
}

type CatalogEntry = z.output<typeof CatalogEntrySchema>

function parseCatalog(value: AgentPluginCatalogEntry[]): CatalogEntry[] {
  const catalog = z.array(CatalogEntrySchema).max(256).parse(value)
  uniqueSortedNames(
    catalog.map(agentPlugin => agentPlugin.id),
    'Agent Plugin'
  )
  for (const agentPlugin of catalog) {
    for (const skill of agentPlugin.skills) {
      if (skill.codexName !== `${agentPlugin.id}:${skill.catalogName}`) {
        throw new Error(`Agent Plugin ${agentPlugin.id} has an invalid namespaced Skill mapping`)
      }
    }
  }
  return [...catalog].sort((left, right) => compareCodePoints(left.id, right.id))
}

function descriptionFor(catalog: CatalogEntry[], standaloneSkillNames: string[]): string {
  return [
    "Manage asynchronous background work performed by this Ankole installation's Codex runner.",
    'Work directly when the user can reasonably wait for the next assistant reply; create a Job for follow-up work that completes later.',
    'Explicit background/asynchronous requests and enabled long-running Skills always require background_agent_job.',
    'start returns immediately. Tell the user work has begun and report after the system wakes you.',
    'The Job receives SOUL, MISSION, durable context, selected capabilities, and no caller conversation history.',
    'Write one self-contained task with all requirements, constraints, exact paths, output language, and acceptance criteria.',
    'agent_plugin_ids selects Agent Plugins by id. Each execution uses their current enabled Skills and package, while workspace-template/ initializes the private Job project only once.',
    'skill_names selects standalone enabled Skills only.',
    '',
    'Actions:',
    '- start: create durable work; requires title and task.',
    '- list: list work from this conversation and prior conversations in the same channel.',
    '- status: inspect one Job, its execution snapshot, and recent semantic trajectory.',
    '- steer: add instructions, answer pending questions, or continue a succeeded/failed Job in its existing runtime session.',
    '- stop: cancel queued, waiting, or running work. Stopped Jobs cannot resume.',
    '',
    agentPluginCatalogDescription(catalog),
    standaloneSkillDescription(standaloneSkillNames),
    '',
    'Do not merely promise to continue later in prose. Before ending a turn, background work must have a durable Job, a check_back_later wakeup, or a terminal outcome.'
  ].join('\n')
}

function agentPluginCatalogDescription(catalog: CatalogEntry[]): string {
  if (catalog.length === 0) return 'Enabled Agent Plugin catalog: none. Omit agent_plugin_ids.'
  return boundedCatalogText(
    [
      'Enabled Agent Plugin catalog:',
      ...catalog.map(agentPlugin => {
        const skills =
          agentPlugin.skills.map(skill => `${skill.catalogName} -> ${skill.codexName}`).join(', ') || 'none'
        return `- ${agentPlugin.id}@${agentPlugin.version}: ${agentPlugin.description}; Agent Plugin Skills: ${skills}`
      })
    ].join('\n')
  )
}

function standaloneSkillDescription(names: string[]): string {
  return names.length === 0
    ? 'Enabled standalone Skills: none. Omit skill_names. Agent Plugin Skills are selected through agent_plugin_ids.'
    : `Enabled standalone Skills: ${names.join(', ')}. Agent Plugin Skills must not appear here; select their agent_plugin_ids.`
}

function dynamicEnum(values: string[], label: string): z.ZodType<string> {
  if (values.length === 0) {
    return z.string().refine(() => false, { message: `no ${label} values are available` })
  }
  return z.enum(values as [string, ...string[]])
}

function uniqueSortedNames(values: string[], label: string): string[] {
  for (const value of values) {
    if (typeof value !== 'string' || !identifier.test(value)) throw new Error(`invalid ${label} name: ${String(value)}`)
  }
  if (new Set(values).size !== values.length) throw new Error(`duplicate ${label} name`)
  return [...values].sort(compareCodePoints)
}

function refineUnique(values: string[] | undefined, label: string, context: z.RefinementCtx): void {
  if (values && new Set(values).size !== values.length) {
    context.addIssue({ code: 'custom', message: `${label} must not contain duplicates` })
  }
}

function requiredText(value: string | undefined, error: string): string {
  const text = value?.trim()
  if (!text) throw new Error(error)
  return text
}

function requiredVerbatimText(value: string | undefined, error: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) throw new Error(error)
  return value
}

function requiredJobID(params: BackgroundAgentJobParams): string {
  if (!params.job_id) throw new Error(`${params.action} requires job_id`)
  return params.job_id
}

function visibleResult(details: BackgroundAgentJobToolDetails, includeTask = false): string {
  if (details.$typeName === 'ankole.runtime_fabric.v1.BackgroundAgentJobListResponse') {
    if (details.jobs.length === 0) return 'No background agent Jobs are visible in this conversation or channel.'
    return details.jobs
      .map(
        item =>
          `${item.jobId} | ${item.status} | ${item.title} | agent_plugin_ids=${item.agentPluginIds.join(',')} | attempts=${item.attempts}`
      )
      .join('\n')
  }

  const execution = jsonObjectFromBytes(details.executionJson, 'background_agent_job.execution_json') as
    | BackgroundAgentJobExecution
    | undefined
  const result = jsonObjectFromBytes(details.resultJson, 'background_agent_job.result_json')
  const error = jsonObjectFromBytes(details.errorJson, 'background_agent_job.error_json')
  const metadata = jsonObjectFromBytes(details.metadataJson, 'background_agent_job.metadata_json')

  const lines = [
    `background agent job ${details.jobId}`,
    `title: ${details.title}`,
    `status: ${details.status}`,
    `agent_plugin_ids: ${details.agentPluginIds.join(',') || 'none'}`,
    `skills: ${details.skillNames.join(',') || 'none'}`,
    `attempts: ${details.attempts}`
  ]
  if (includeTask) lines.push(`task_excerpt: ${boundedText(details.task)}`)
  if (details.runtimeThreadId) lines.push(`runtime_thread_id: ${details.runtimeThreadId}`)
  if (execution) {
    const { trajectory_page: trajectoryPage, ...executionSummary } = execution
    lines.push(`execution: ${JSON.stringify(executionSummary)}`)
    lines.push(`trajectory_page: ${JSON.stringify(trajectoryPage)}`)
  }
  if (result && Object.keys(result).length > 0) lines.push(`result: ${boundedJSON(result)}`)
  if (error && Object.keys(error).length > 0) lines.push(`error: ${boundedJSON(error)}`)
  if (details.status === 'waiting_on_user' && metadata?.pending_user_input) {
    lines.push(`pending_user_input: ${JSON.stringify(metadata.pending_user_input)}`)
  }
  return lines.join('\n')
}

function boundedText(value: string): string {
  const suffix = '...[truncated]'
  if (utf8ByteLength(value) <= 16_384) return value
  return `${truncateUTF8Safe(value, 16_384 - utf8ByteLength(suffix))}${suffix}`
}

function boundedJSON(value: JSONObject): string {
  return boundedText(JSON.stringify(value))
}

function boundedCatalogText(value: string): string {
  const suffix = '\n...[Agent Plugin catalog description truncated; schema enums remain authoritative]'
  const maxBytes = 32_768
  if (utf8ByteLength(value) <= maxBytes) return value
  return `${truncateUTF8Safe(value, maxBytes - utf8ByteLength(suffix))}${suffix}`
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}
