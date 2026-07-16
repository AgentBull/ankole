import { match } from '@pleisto/active-support'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { z } from 'zod'
import { truncateUTF8Safe, utf8ByteLength } from '../../common/text-sanitize'
import type { AgentTool, AgentToolResult } from '../../core'
import type { TurnStart } from '../../lanes/actor_lane'
import {
  assertRPCResponse,
  type SubagentDelegationCreateRequest,
  type SubagentDelegationListResponse,
  type SubagentDelegationResponse
} from '../../lanes/rpc_lane'
import type {
  SubagentDelegationCreateRequester,
  SubagentDelegationGetRequester,
  SubagentDelegationListRequester,
  SubagentDelegationSteerRequester,
  SubagentDelegationStopRequester
} from '../../core/turns/turn_options'
import { strictOutputSchemaIssues } from './output-schema'

const SubagentParams = z
  .object({
    action: z.enum(['start', 'list', 'status', 'steer', 'stop']),
    title: z.string().min(1).max(200).describe('Short task-board title for start.').optional(),
    task: z
      .string()
      .min(1)
      .describe(
        'Complete task for the selected delegation profile. Include the instruction and every requirement, constraint, and acceptance criterion in this string.'
      )
      .optional(),
    background: z
      .string()
      .min(1)
      .describe(
        'Relevant context for the selected delegation profile. Include caller-conversation context only when it is relevant; do not repeat task requirements.'
      )
      .optional(),
    notes: z
      .string()
      .min(1)
      .describe('Execution notes and cautions for the selected delegation profile. Do not put task requirements here.')
      .optional(),
    delegation_id: z.string().uuid().describe('Delegation id for status, steer, or stop.').optional(),
    workdir: z.string().describe('Optional path under /workspace for the delegated work.').optional(),
    runtime: z
      .enum(['task_worker', 'deep_research'])
      .describe('Execution contract for start. Defaults to task_worker.')
      .optional(),
    mode: z
      .enum(['general', 'forecast', 'retrospect'])
      .describe('Deep Research mode for start. Defaults to general.')
      .optional(),
    source_delegation_id: z
      .string()
      .uuid()
      .describe('Succeeded forecast delegation to consume in retrospect mode.')
      .optional(),
    actual_outcome: z.boolean().describe('Optional resolved outcome for retrospect mode.').optional(),
    output_schema: z
      .record(z.string(), z.unknown())
      .describe(
        'Optional JSON Schema describing requested structured content. For task_worker, use a root object and set additionalProperties: false plus required containing every property on every object; use a null union for optional values. For Deep Research, express the content in report/report.md; it does not require a JSON sidecar.'
      )
      .optional(),
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
  .superRefine((params, context) => {
    if (params.action !== 'status' && (params.trajectory_limit !== undefined || params.trajectory_cursor)) {
      context.addIssue({
        code: 'custom',
        message: 'trajectory_limit and trajectory_cursor are only valid for status'
      })
    }

    const researchFields = [params.mode, params.source_delegation_id, params.actual_outcome]
    if (
      params.action !== 'start' &&
      (params.runtime || params.output_schema || researchFields.some(value => value !== undefined))
    ) {
      context.addIssue({
        code: 'custom',
        message: 'runtime, output_schema, and research fields are only valid for start'
      })
      return
    }

    if (params.action !== 'start') return
    const runtime = params.runtime ?? 'task_worker'
    const mode = params.mode ?? 'general'
    if (runtime === 'task_worker' && researchFields.some(value => value !== undefined)) {
      context.addIssue({ code: 'custom', message: 'task_worker does not accept research fields' })
    }
    if (runtime === 'task_worker' && params.output_schema) {
      for (const issue of strictOutputSchemaIssues(params.output_schema)) {
        context.addIssue({ code: 'custom', path: ['output_schema', ...issue.path], message: issue.message })
      }
    }
    if (runtime === 'deep_research' && mode === 'retrospect' && !params.source_delegation_id) {
      context.addIssue({ code: 'custom', message: 'retrospect requires source_delegation_id' })
    }
    if (runtime === 'deep_research' && mode !== 'retrospect' && params.source_delegation_id) {
      context.addIssue({ code: 'custom', message: 'source_delegation_id is only valid for retrospect' })
    }
    if (runtime === 'deep_research' && mode !== 'retrospect' && params.actual_outcome !== undefined) {
      context.addIssue({ code: 'custom', message: 'actual_outcome is only valid for retrospect' })
    }
  })

type SubagentParams = z.output<typeof SubagentParams>
type SubagentToolDetails = SubagentDelegationResponse | SubagentDelegationListResponse

export type SubagentToolOptions = {
  turnStart: TurnStart
  createSubagentDelegation?: SubagentDelegationCreateRequester
  getSubagentDelegation?: SubagentDelegationGetRequester
  listSubagentDelegations?: SubagentDelegationListRequester
  steerSubagentDelegation?: SubagentDelegationSteerRequester
  stopSubagentDelegation?: SubagentDelegationStopRequester
}

const DESCRIPTION = [
  "Manage asynchronous background work performed by this Ankole installation's task_worker or deep_research profile.",
  'Choose between immediate-response work and follow-up work.',
  'Work directly for immediate-response work: the user can reasonably wait in the active exchange, and the next assistant reply contains the completed result.',
  'Use subagent for follow-up work: accept it as a separate work item so the conversation can continue, then deliver the completed result in a later reply.',
  'Several tool calls may still be direct; a clear scope alone does not make work direct.',
  'Explicit requests for background or asynchronous execution, and enabled long-running Skills, always require subagent.',
  'start returns immediately. After start, tell the user the work has begun and that you will report when the system wakes you.',
  'The subagent receives SOUL and MISSION automatically, but no caller conversation history.',
  'Write one self-contained task string containing the instruction and every requirement, constraint, acceptance criterion, exact path, and output language.',
  'Put only relevant task context in background and execution cautions in notes. These become AGENTS instructions and are not task requirements.',
  '',
  'Actions:',
  '- start: create durable work; requires title and task.',
  '- deep_research supports general, forecast, and retrospect. Retrospect must name a succeeded forecast from this Agent.',
  '- list: list work from this conversation and prior conversations in the same channel.',
  '- status: inspect one delegation, its execution snapshot, and three recent semantic trajectory groups by default. Use trajectory_limit or trajectory_cursor for more.',
  '- steer: add instructions, answer pending questions, or continue a succeeded/failed delegation in its existing runtime session.',
  '- stop: cancel queued, waiting, or running work.',
  '- stopped delegations cannot be resumed. Do not create a replacement delegation merely to continue a succeeded or failed runtime session; steer the existing delegation.',
  '',
  'Do not merely promise to continue later in prose. Before ending a turn, background work must have a durable delegation, a check_back_later wakeup, or a terminal outcome.'
].join('\n')

export function createSubagentTool(opts: SubagentToolOptions): AgentTool<typeof SubagentParams, SubagentToolDetails> {
  return {
    name: 'subagent',
    description: DESCRIPTION,
    schema: SubagentParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    async execute(toolCallID, params): Promise<AgentToolResult<SubagentToolDetails>> {
      const details = await executeSubagent(toolCallID, params, opts)
      return {
        content: [{ type: 'text', text: visibleResult(details, params.action === 'status') }],
        details
      }
    }
  }
}

async function executeSubagent(
  toolCallID: string,
  params: SubagentParams,
  opts: SubagentToolOptions
): Promise<SubagentToolDetails> {
  const requestID = `subagent-${params.action}-${crypto.randomUUID()}`
  const turn = opts.turnStart.turn

  return match(params.action)
    .with('start', async () => {
      const request = requireRequester(opts.createSubagentDelegation, 'start')
      const base = {
        request_id: requestID,
        turn,
        tool_call_id: toolCallID,
        title: requiredText(params.title, 'start requires title'),
        task: requiredVerbatimText(params.task, 'start requires task'),
        ...(params.background ? { background: params.background } : {}),
        ...(params.notes ? { notes: params.notes } : {}),
        ...(params.workdir ? { workdir: params.workdir } : {}),
        ...(params.output_schema ? { output_schema: params.output_schema as JSONObject } : {}),
        ...(params.output_schema ? { metadata: { output_schema: params.output_schema as JSONObject } } : {})
      }
      const response = await request(subagentCreateRequest(base, params))
      assertRPCResponse<SubagentDelegationResponse>(response, 'subagent start rejected')
      return response
    })
    .with('list', async () => {
      const request = requireRequester(opts.listSubagentDelegations, 'list')
      const response = await request({ request_id: requestID, turn })
      assertRPCResponse<SubagentDelegationListResponse>(response, 'subagent list rejected')
      return response
    })
    .with('status', async () => {
      const request = requireRequester(opts.getSubagentDelegation, 'status')
      const response = await request({
        request_id: requestID,
        turn,
        delegation_id: requiredDelegationID(params),
        ...(params.trajectory_limit !== undefined ? { trajectory_limit: params.trajectory_limit } : {}),
        ...(params.trajectory_cursor ? { trajectory_cursor: params.trajectory_cursor } : {})
      })
      assertRPCResponse<SubagentDelegationResponse>(response, 'subagent status rejected')
      return response
    })
    .with('steer', async () => {
      const request = requireRequester(opts.steerSubagentDelegation, 'steer')
      if (!params.text && (!params.answers || Object.keys(params.answers).length === 0)) {
        throw new Error('steer requires text or answers')
      }
      const response = await request({
        request_id: requestID,
        turn,
        delegation_id: requiredDelegationID(params),
        ...(params.text ? { text: params.text } : {}),
        ...(params.answers ? { answers: params.answers } : {})
      })
      assertRPCResponse<SubagentDelegationResponse>(response, 'subagent steer rejected')
      return response
    })
    .with('stop', async () => {
      const request = requireRequester(opts.stopSubagentDelegation, 'stop')
      const response = await request({
        request_id: requestID,
        turn,
        delegation_id: requiredDelegationID(params),
        ...(params.text ? { reason: params.text } : {})
      })
      assertRPCResponse<SubagentDelegationResponse>(response, 'subagent stop rejected')
      return response
    })
    .exhaustive()
}

function subagentCreateRequest(
  base: Omit<SubagentDelegationCreateRequest, 'runtime' | 'mode' | 'source_delegation_id' | 'actual_outcome'>,
  params: SubagentParams
): SubagentDelegationCreateRequest {
  const runtime = params.runtime ?? 'task_worker'
  if (runtime === 'task_worker') return { ...base, runtime }
  const mode = params.mode ?? 'general'
  if (mode === 'retrospect') {
    return {
      ...base,
      runtime,
      mode,
      source_delegation_id: requiredText(params.source_delegation_id, 'retrospect requires source_delegation_id'),
      ...(params.actual_outcome !== undefined ? { actual_outcome: params.actual_outcome } : {})
    }
  }
  return { ...base, runtime, mode }
}

function requireRequester<T>(requester: T | undefined, action: string): T {
  if (!requester) throw new Error(`subagent ${action} RPC is not configured`)
  return requester
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

function requiredDelegationID(params: SubagentParams): string {
  if (!params.delegation_id) throw new Error(`${params.action} requires delegation_id`)
  return params.delegation_id
}

function visibleResult(details: SubagentToolDetails, includeTask = false): string {
  if ('delegations' in details) {
    if (details.delegations.length === 0) return 'No subagent delegations are visible in this conversation or channel.'
    return details.delegations
      .map(item => `${item.delegation_id} | ${item.status} | ${item.title} | attempts=${item.attempts}`)
      .join('\n')
  }

  const lines = [
    `subagent delegation ${details.delegation_id}`,
    `title: ${details.title}`,
    `status: ${details.status}`,
    `runtime: ${details.runtime}${details.mode ? `/${details.mode}` : ''}`,
    `attempts: ${details.attempts}`
  ]
  if (includeTask) lines.push(`task_excerpt: ${boundedText(details.task)}`)
  if (details.workdir) lines.push(`workdir: ${details.workdir}`)
  if (details.runtime_thread_id) lines.push(`runtime_thread_id: ${details.runtime_thread_id}`)
  if (details.execution) {
    const { trajectory_page: trajectoryPage, ...executionSummary } = details.execution
    lines.push(`execution: ${JSON.stringify(executionSummary)}`)
    lines.push(`trajectory_page: ${JSON.stringify(trajectoryPage)}`)
  }
  if (details.result && Object.keys(details.result).length > 0) lines.push(`result: ${boundedJSON(details.result)}`)
  if (details.error && Object.keys(details.error).length > 0) lines.push(`error: ${boundedJSON(details.error)}`)
  if (details.status === 'waiting_on_user' && details.metadata?.pending_user_input) {
    lines.push(`pending_user_input: ${JSON.stringify(details.metadata.pending_user_input)}`)
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
