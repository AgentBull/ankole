import { compactRecord, match } from '@pleisto/active-support'
import { z } from 'zod'
import type { TurnStart } from '../../lanes/actor_lane'
import type { JsonObject } from '@pleisto/active-support'
import type { AgentTool, AgentToolResult } from '../../core'
import { rpcMethods, type MemoryRpcRequest, type RpcMethod } from '../../lanes/rpc_lane'

export type MemoryRpcRequester = (method: RpcMethod, request: MemoryRpcRequest) => Promise<JsonObject>

export interface CreateMemoryToolsOptions {
  turnStart: TurnStart
  requestMemoryRpc?: MemoryRpcRequester
}

type MemoryToolDetails = JsonObject

const MEMORY_NOTE_DESCRIPTION = [
  'Manage curated durable facts for this agent in the current channel only.',
  'Use action=list when the user asks what you remember about this channel.',
  'Save proactively when the user states a preference, correction, or personal detail, or you learn a stable fact about their environment, conventions, or workflow.',
  'Priority: user preferences and corrections, then environment facts, then procedures. The best memory stops the user repeating themselves.',
  'Skip trivial or obvious info, easily re-discovered facts, raw data dumps, task progress, completed-work logs, and temporary TODO state.',
  'Use update or forget to replace, remove, shorten, or merge stale notes when needed.',
  'After save, update, or forget, confirm in the visible reply exactly what changed.',
  'Notes are shared channel context, so keep each note short, stable, and directly actionable.'
].join('\n')

const MemoryNoteParams = z.object({
  action: z.enum(['save', 'update', 'forget', 'list']),
  note_id: z.string().optional(),
  content: z.string().max(500).optional()
})

const MemorySearchParams = z.object({
  query: z.string().min(1).max(1000),
  scope: z.enum(['current_channel', 'all_channels']).default('current_channel'),
  from: z.string().optional(),
  to: z.string().optional(),
  limit: z.number().int().positive().max(10).optional()
})

const MemoryBrowseParams = z.object({
  channel_id: z.string().optional(),
  from: z.string().optional(),
  to: z.string().optional(),
  cursor: z.string().optional(),
  limit: z.number().int().positive().max(50).optional()
})

/**
 * Creates Memory tools only when the turn runtime provides Memory RPC.
 */
export function createMemoryTools(opts: CreateMemoryToolsOptions): AgentTool<any>[] {
  if (!opts.requestMemoryRpc) return []
  return [createMemoryNoteTool(opts), createMemorySearchTool(opts), createMemoryBrowseTool(opts)]
}

function createMemoryNoteTool(opts: CreateMemoryToolsOptions): AgentTool<typeof MemoryNoteParams, MemoryToolDetails> {
  return {
    name: 'memory_note',
    description: MEMORY_NOTE_DESCRIPTION,
    schema: MemoryNoteParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(toolCallId, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const method = memoryNoteMethod(params.action)
      const payload: JsonObject = { tool_call_id: toolCallId }

      if (params.action === 'save' || params.action === 'update') {
        if (!params.content?.trim()) throw new Error(`${params.action} requires content`)
        payload.content = params.content
      }
      if (params.action === 'update' || params.action === 'forget') {
        if (!params.note_id?.trim()) throw new Error(`${params.action} requires note_id`)
        payload.note_id = params.note_id
      }

      const response = await opts.requestMemoryRpc!(method, memoryRequest(opts.turnStart, payload))
      return jsonToolResult(response)
    }
  }
}

function createMemorySearchTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemorySearchParams, MemoryToolDetails> {
  return {
    name: 'memory_search',
    description:
      'Search durable memory before answering about prior work, decisions, dates, people, preferences, or channel history. Defaults to current channel; all_channels respects observed-channel and DM leak policy.',
    schema: MemorySearchParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRpc!(
        rpcMethods.memorySearch,
        memoryRequest(opts.turnStart, compactRecord(params))
      )
      return jsonToolResult(response)
    }
  }
}

function createMemoryBrowseTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemoryBrowseParams, MemoryToolDetails> {
  return {
    name: 'memory_browse',
    description:
      'Browse durable channel history by time or cursor. Use this when exact neighboring messages matter or when memory_search current-context exclusion is not appropriate.',
    schema: MemoryBrowseParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRpc!(
        rpcMethods.memoryBrowse,
        memoryRequest(opts.turnStart, compactRecord(params))
      )
      return jsonToolResult(response)
    }
  }
}

function memoryNoteMethod(action: z.output<typeof MemoryNoteParams>['action']): RpcMethod {
  return match(action)
    .with('save', () => rpcMethods.memoryNoteSave)
    .with('update', () => rpcMethods.memoryNoteUpdate)
    .with('forget', () => rpcMethods.memoryNoteForget)
    .with('list', () => rpcMethods.memoryNoteList)
    .exhaustive()
}

function memoryRequest(turnStart: TurnStart, payload: JsonObject): MemoryRpcRequest {
  return {
    request_id: `memory-${crypto.randomUUID()}`,
    turn_ref: turnStart.turn,
    actor_event: turnStart.actor_event,
    ...payload
  }
}

function jsonToolResult(details: JsonObject): AgentToolResult<MemoryToolDetails> {
  const notice = typeof details.history_notice === 'string' ? `Memory notice: ${details.history_notice}\n` : ''

  return {
    content: [{ type: 'text', text: `${notice}${JSON.stringify(details)}` }],
    details
  }
}
