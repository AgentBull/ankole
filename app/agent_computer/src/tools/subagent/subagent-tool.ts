import { match } from '@pleisto/active-support'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { z } from 'zod'
import { truncateUTF8Safe, utf8ByteLength } from '../../common/text-sanitize'
import type { AgentTool, AgentToolResult } from '../../core'
import type { TurnStart } from '../../lanes/actor_lane'
import {
  assertRPCResponse,
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

const SubagentParams = z.object({
  action: z.enum(['start', 'list', 'status', 'steer', 'stop']),
  title: z.string().min(1).max(200).describe('Short task-board title for start.').optional(),
  brief: z
    .string()
    .min(1)
    .describe('Self-contained task brief for start: paths, constraints, acceptance criteria, and output language.')
    .optional(),
  delegation_id: z.string().uuid().describe('Delegation id for status, steer, or stop.').optional(),
  workdir: z.string().describe('Optional path under /workspace for the delegated work.').optional(),
  output_schema: z.record(z.string(), z.unknown()).describe('Optional JSON Schema for the final report.').optional(),
  text: z.string().min(1).describe('Steering instructions, or an optional stop reason.').optional(),
  answers: z
    .record(z.string(), z.union([z.string(), z.array(z.string())]))
    .describe('Answers keyed by Codex requestUserInput question id for steer.')
    .optional()
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
  "Manage asynchronous background work performed by this Ankole installation's Codex subagent runtime.",
  'Delegate only work expected to take at least 10 minutes. Do faster work directly in this turn.',
  'start returns immediately. After start, tell the user the work has begun and that you will report when the system wakes you.',
  'The subagent receives SOUL and MISSION automatically, but no parent conversation history. The brief is its only task input.',
  'Write a self-contained brief with exact paths, constraints, acceptance criteria, and output language.',
  '',
  'Actions:',
  '- start: create durable work; requires title and brief.',
  '- list: list work from this conversation and prior conversations in the same channel.',
  '- status: inspect one delegation and its latest audit cursor.',
  '- steer: add instructions or answer pending questions.',
  '- stop: cancel queued, waiting, or running work.',
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
        content: [{ type: 'text', text: visibleResult(details) }],
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
      const response = await request({
        request_id: requestID,
        turn,
        tool_call_id: toolCallID,
        title: requiredText(params.title, 'start requires title'),
        prompt: requiredText(params.brief, 'start requires brief'),
        ...(params.workdir ? { workdir: params.workdir } : {}),
        ...(params.output_schema ? { output_schema: params.output_schema as JSONObject } : {}),
        ...(params.output_schema ? { metadata: { output_schema: params.output_schema as JSONObject } } : {})
      })
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
        delegation_id: requiredDelegationID(params)
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

function requireRequester<T>(requester: T | undefined, action: string): T {
  if (!requester) throw new Error(`subagent ${action} RPC is not configured`)
  return requester
}

function requiredText(value: string | undefined, error: string): string {
  const text = value?.trim()
  if (!text) throw new Error(error)
  return text
}

function requiredDelegationID(params: SubagentParams): string {
  if (!params.delegation_id) throw new Error(`${params.action} requires delegation_id`)
  return params.delegation_id
}

function visibleResult(details: SubagentToolDetails): string {
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
    `attempts: ${details.attempts}`
  ]
  if (details.workdir) lines.push(`workdir: ${details.workdir}`)
  if (details.runtime_thread_id) lines.push(`runtime_thread_id: ${details.runtime_thread_id}`)
  if (details.last_event_seq !== undefined) lines.push(`last_event_seq: ${details.last_event_seq}`)
  if (details.result && Object.keys(details.result).length > 0) lines.push(`result: ${boundedJSON(details.result)}`)
  if (details.error && Object.keys(details.error).length > 0) lines.push(`error: ${boundedJSON(details.error)}`)
  if (details.status === 'waiting_on_user' && details.metadata?.pending_user_input) {
    lines.push(`pending_user_input: ${JSON.stringify(details.metadata.pending_user_input)}`)
  }
  return lines.join('\n')
}

function boundedJSON(value: JSONObject): string {
  const text = JSON.stringify(value)
  const suffix = '...[truncated]'
  if (utf8ByteLength(text) <= 16_384) return text
  return `${truncateUTF8Safe(text, 16_384 - utf8ByteLength(suffix))}${suffix}`
}
