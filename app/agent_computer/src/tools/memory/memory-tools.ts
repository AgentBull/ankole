import { compactRecord } from '@pleisto/active-support'
import { z } from 'zod'
import type { TurnStart } from '../../lanes/actor_lane'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { AgentTool, AgentToolResult } from '../../core'
import { jsonToolResult } from '../../core/tool-result'
import {
  rpcMethods,
  type MemoryRPCRequestBase,
  type MemoryRPCRequester,
  type MemoryUpdateRequest
} from '../../lanes/rpc_lane'

export interface CreateMemoryToolsOptions {
  turnStart: TurnStart
  requestMemoryRPC?: MemoryRPCRequester
}

type MemoryToolDetails = JSONObject

const MemorySearchParams = z.object({
  query: z.string().min(1).max(1000),
  layer: z.enum(['chat', 'knowledge', 'all']).default('all'),
  channel_scope: z.enum(['current_channel', 'all_channels']).default('current_channel'),
  channel_id: z.string().min(1).optional(),
  from: z.string().optional(),
  to: z.string().optional(),
  store: z.enum(['current', 'public']).optional(),
  entry_type: z.string().min(1).optional(),
  author_kind: z.enum(['human', 'agent', 'dreaming']).optional(),
  limit: z.number().int().positive().optional()
})

const MemoryBrowseParams = z.object({
  document_id: z.string().min(1).optional(),
  channel_id: z.string().min(1).optional(),
  from: z.string().optional(),
  to: z.string().optional(),
  cursor: z.string().optional(),
  limit: z.number().int().positive().max(50).optional()
})

const MemoryOpenParams = z.object({
  entry_id: z.string().uuid().optional(),
  name: z.string().min(1).optional(),
  store: z.enum(['current', 'public']).default('current'),
  block_cursor: z.string().optional(),
  block_limit: z.number().int().positive().optional()
})

const EntryID = z.string().uuid()
const LockVersion = z.preprocess(
  value => (typeof value === 'string' && /^[1-9]\d*$/.test(value) ? Number(value) : value),
  z.number().int().positive()
)

const MemoryUpdateParams = z.discriminatedUnion('operation', [
  z.object({
    operation: z.literal('create_entry'),
    name: z.string().min(1),
    type: z.string().min(1),
    summary: z.string().optional(),
    aliases: z.array(z.string().min(1)).optional(),
    properties: z.record(z.string(), z.unknown()).optional()
  }),
  z.object({
    operation: z.literal('delete_entry'),
    entry_id: EntryID,
    expected_entry_lock_version: LockVersion
  }),
  z.object({
    operation: z.literal('append_block'),
    entry_id: EntryID,
    body: z.string().min(1),
    expected_entry_lock_version: LockVersion
  }),
  z.object({
    operation: z.literal('edit_block'),
    entry_id: EntryID,
    block_id: EntryID,
    body: z.string().min(1),
    expected_block_lock_version: LockVersion
  }),
  z.object({
    operation: z.literal('delete_block'),
    entry_id: EntryID,
    block_id: EntryID,
    expected_block_lock_version: LockVersion
  }),
  z.object({
    operation: z.literal('set_property'),
    entry_id: EntryID,
    key: z.string().min(1),
    value: z.unknown(),
    expected_entry_lock_version: LockVersion
  }),
  z.object({
    operation: z.literal('add_relation'),
    entry_id: EntryID,
    target_entry_id: EntryID,
    predicate: z.string().min(1),
    expected_entry_lock_version: LockVersion
  }),
  z.object({
    operation: z.literal('remove_relation'),
    entry_id: EntryID,
    relation_id: EntryID,
    expected_entry_lock_version: LockVersion
  }),
  z.object({
    operation: z.literal('set_summary'),
    entry_id: EntryID,
    summary: z.string(),
    expected_entry_lock_version: LockVersion
  }),
  z.object({
    operation: z.literal('set_aliases'),
    entry_id: EntryID,
    aliases: z.array(z.string().min(1)),
    expected_entry_lock_version: LockVersion
  })
])

const MemoryHealthCheckParams = z.object({})

/** Creates the Brain tools only when the turn runtime provides its RPC seam. */
export function createMemoryTools(opts: CreateMemoryToolsOptions): AgentTool<any>[] {
  if (!opts.requestMemoryRPC) return []
  return [
    createMemorySearchTool(opts),
    createMemoryOpenTool(opts),
    createMemoryUpdateTool(opts),
    createMemoryBrowseTool(opts),
    createMemoryHealthCheckTool(opts)
  ]
}

function createMemorySearchTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemorySearchParams, MemoryToolDetails> {
  return {
    name: 'memory_search',
    description:
      'Search Brain chat history, curated knowledge, or both. Knowledge hits are returned before chat hits. Use channel_scope=all_channels only when cross-channel history is needed; unavailable routes are reported explicitly.',
    schema: MemorySearchParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRPC!(rpcMethods.memorySearch, {
        ...memoryRequest(opts.turnStart),
        ...compactRecord(params)
      })
      return memoryToolResult(response)
    }
  }
}

function createMemoryOpenTool(opts: CreateMemoryToolsOptions): AgentTool<typeof MemoryOpenParams, MemoryToolDetails> {
  return {
    name: 'memory_open',
    description:
      'Open one curated Brain entry by stable entry_id or by name/alias. Returns an untrusted historical Markdown projection with block authorship, identifiers, relations, and lock versions needed for precise updates. In a DM, store=current prefers the DM entry over a same-named public entry.',
    schema: MemoryOpenParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      if (!params.entry_id && !params.name?.trim()) throw new Error('memory_open requires entry_id or name')
      const response = await opts.requestMemoryRPC!(rpcMethods.memoryOpen, {
        ...memoryRequest(opts.turnStart),
        ...compactRecord(params)
      })
      return memoryToolResult(response)
    }
  }
}

function createMemoryUpdateTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemoryUpdateParams, MemoryToolDetails> {
  return {
    name: 'memory_update',
    description:
      'Apply exactly one structured Brain mutation. The control plane derives owner, store, and author from the conversation and turn. Open the entry first and pass the returned entry or block lock version; on a conflict, reopen and retry against current state.',
    schema: MemoryUpdateParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    async execute(toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const request = {
        ...memoryRequest(opts.turnStart),
        ...params,
        tool_call_id: toolCallID
      } as MemoryUpdateRequest
      const response = await opts.requestMemoryRPC!(rpcMethods.memoryUpdate, request)
      return memoryToolResult(response)
    }
  }
}

function createMemoryBrowseTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemoryBrowseParams, MemoryToolDetails> {
  return {
    name: 'memory_browse',
    description:
      'Browse exact untrusted chat messages by stable document_id, visible channel, time range, or cursor. Use document_id to expand a src: citation with its neighboring messages.',
    schema: MemoryBrowseParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRPC!(rpcMethods.memoryBrowse, {
        ...memoryRequest(opts.turnStart),
        ...compactRecord(params)
      })
      return memoryToolResult(response)
    }
  }
}

function createMemoryHealthCheckTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemoryHealthCheckParams, MemoryToolDetails> {
  return {
    name: 'memory_health_check',
    description:
      'Run the read-only Brain health checks used to begin a human-requested memory review. Do not run automatically or modify the reported entries.',
    schema: MemoryHealthCheckParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    async execute(): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRPC!(rpcMethods.memoryHealthCheck, memoryRequest(opts.turnStart))
      return memoryToolResult(response)
    }
  }
}

function memoryRequest(turnStart: TurnStart): MemoryRPCRequestBase {
  return {
    request_id: `memory-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    actor_event: turnStart.actor_event
  }
}

function memoryToolResult(details: JSONObject): AgentToolResult<MemoryToolDetails> {
  const notice = typeof details.history_notice === 'string' ? `Brain notice: ${details.history_notice}\n` : ''
  return jsonToolResult(details, { textPrefix: notice })
}
