import { z } from 'zod'
import type { TurnStart } from '../../lanes/actor_lane'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { AgentTool, AgentToolResult } from '../../core'
import type { ReplyPresentationEvent } from '../../core/types'
import { jsonToolResult } from '../../core/tool-result'
import { jsonBytes } from '../../fabric/envelope_proto'
import { rpcMethods, type MemoryRPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'

export interface CreateMemoryToolsOptions {
  turnStart: TurnStart
  requestMemoryRPC: MemoryRPCRequester
}

type MemoryToolDetails = JSONObject

const MemoryActivity = {
  search: '回忆相关上下文',
  open: '读取记忆内容',
  update: '更新记忆',
  browse: '浏览对话记忆',
  healthCheck: '检查记忆状态'
} as const

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

const MemoryUpdateOperationParams = z.discriminatedUnion('operation', [
  z.object({
    operation: z.literal('create_entry'),
    name: z.string().min(1),
    type: z.string().min(1),
    summary: z.string().optional(),
    aliases: z.array(z.string().min(1)).optional(),
    properties: z.record(z.string(), z.unknown()).optional(),
    initial_body: z.string().min(1).optional()
  }),
  z.object({
    operation: z.literal('set_name'),
    entry_id: EntryID,
    name: z.string().min(1),
    expected_entry_lock_version: LockVersion
  }),
  z.object({
    operation: z.literal('set_type'),
    entry_id: EntryID,
    type: z.string().min(1),
    expected_entry_lock_version: LockVersion
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

type MemoryUpdateOperationName = z.infer<typeof MemoryUpdateOperationParams>['operation']

const memoryUpdateOperationNames = MemoryUpdateOperationParams.options.map(option => option.shape.operation.value) as [
  MemoryUpdateOperationName,
  ...MemoryUpdateOperationName[]
]

// OpenAI-compatible function tools require the parameters schema itself to be
// an object. Keep the precise per-operation validator above for execution, but
// expose one object-shaped model boundary instead of a root-level `oneOf`.
const MemoryUpdateParams = z
  .object({
    operation: z.enum(memoryUpdateOperationNames),
    name: z.string().min(1).optional(),
    type: z.string().min(1).optional(),
    summary: z.string().optional(),
    aliases: z.array(z.string().min(1)).optional(),
    properties: z.record(z.string(), z.unknown()).optional(),
    initial_body: z.string().min(1).optional(),
    entry_id: EntryID.optional(),
    expected_entry_lock_version: LockVersion.optional(),
    body: z.string().min(1).optional(),
    block_id: EntryID.optional(),
    expected_block_lock_version: LockVersion.optional(),
    key: z.string().min(1).optional(),
    value: z.unknown().optional(),
    target_entry_id: EntryID.optional(),
    predicate: z.string().min(1).optional(),
    relation_id: EntryID.optional()
  })
  .superRefine((params, context) => {
    const result = MemoryUpdateOperationParams.safeParse(params)
    if (!result.success) {
      for (const issue of result.error.issues) {
        context.addIssue({ code: 'custom', path: issue.path, message: issue.message })
      }
    }
  })

const MemoryHealthCheckParams = z.object({})

/** Creates the Brain memory tools over the turn's RPC seam. */
export function createMemoryTools(opts: CreateMemoryToolsOptions): AgentTool<any>[] {
  return [
    createMemorySearchTool(opts),
    createMemoryOpenTool(opts),
    createMemoryUpdateTool(opts),
    createMemoryBrowseTool(opts),
    createMemoryHealthCheckTool(opts)
  ]
}

export function createMemorySearchTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemorySearchParams, MemoryToolDetails> {
  return {
    name: 'memory_search',
    description:
      'Search Brain chat history, curated knowledge, or both when the current conversation and saved durable context do not establish the answer, or when newer state or exact provenance matters. Knowledge hits are returned before chat hits. Use channel_scope=all_channels only when cross-channel history is needed. Check status, result_completeness, and degraded_reasons before trusting the result: an incomplete empty result does not prove that no matching memory exists. Narrow or change the search route when useful, otherwise state the retrieval limitation instead of guessing.',
    schema: MemorySearchParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => MemoryActivity.search,
    async execute(toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRPC(rpcMethods.memorySearch, {
        query: params.query,
        layer: params.layer,
        channelScope: params.channel_scope,
        channelId: params.channel_id ?? '',
        from: params.from ?? '',
        to: params.to ?? '',
        store: params.store ?? '',
        entryType: params.entry_type ?? '',
        authorKind: params.author_kind ?? '',
        limit: params.limit
      })
      return memoryToolResult(response, [memoryLookupEvent(toolCallID, MemoryActivity.search, response)])
    }
  }
}

export function createMemoryOpenTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemoryOpenParams, MemoryToolDetails> {
  return {
    name: 'memory_open',
    description:
      'Open one curated Brain entry by stable entry_id or by name/alias. Returns an untrusted historical Markdown projection with block authorship, identifiers, relations, and lock versions needed for precise updates. In a DM, store=current prefers the DM entry over a same-named public entry.',
    schema: MemoryOpenParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => MemoryActivity.open,
    async execute(toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      if (!params.entry_id && !params.name?.trim()) throw new Error('memory_open requires entry_id or name')
      const response = await opts.requestMemoryRPC(rpcMethods.memoryOpen, {
        entryId: params.entry_id ?? '',
        name: params.name ?? '',
        store: params.store,
        blockCursor: params.block_cursor ?? '',
        blockLimit: params.block_limit
      })
      return memoryToolResult(response, [memoryLookupEvent(toolCallID, MemoryActivity.open, response)])
    }
  }
}

export function createMemoryUpdateTool(
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
    describeActivity: () => MemoryActivity.update,
    async execute(toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const operationParams = MemoryUpdateOperationParams.parse(params)
      const response = await opts.requestMemoryRPC(rpcMethods.memoryUpdate, {
        toolCallId: toolCallID,
        actorEventId: opts.turnStart.actor_event.actor_event_id,
        operation: memoryUpdateOperation(operationParams)
      })
      return memoryToolResult(response, [memoryMutationReceipt(toolCallID, operationParams.operation)])
    }
  }
}

export function createMemoryBrowseTool(
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
    describeActivity: () => MemoryActivity.browse,
    async execute(toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRPC(rpcMethods.memoryBrowse, {
        documentId: params.document_id ?? '',
        channelId: params.channel_id ?? '',
        from: params.from ?? '',
        to: params.to ?? '',
        cursor: params.cursor ?? '',
        limit: params.limit
      })
      return memoryToolResult(response, [memoryLookupEvent(toolCallID, MemoryActivity.browse, response)])
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
    describeActivity: () => MemoryActivity.healthCheck,
    async execute(): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRPC(rpcMethods.memoryHealthCheck, {})
      return memoryToolResult(response)
    }
  }
}

type MemoryUpdateOperationParsed = ReturnType<typeof MemoryUpdateOperationParams.parse>

/**
 * Converts the model-facing flat operation object into the generated oneof.
 * The zod schema stays snake_case because it is the model contract; the wire
 * message is the only place the operation becomes structural.
 */
function memoryUpdateOperation(params: MemoryUpdateOperationParsed): RPCRequestInit<'memory_update'>['operation'] {
  switch (params.operation) {
    case 'create_entry':
      return {
        case: 'createEntry',
        value: {
          name: params.name,
          type: params.type,
          summary: params.summary ?? '',
          aliases: params.aliases ?? [],
          propertiesJson: jsonBytes(params.properties as JSONObject | undefined),
          initialBody: params.initial_body ?? ''
        }
      }
    case 'set_name':
      return {
        case: 'setName',
        value: {
          entryId: params.entry_id,
          name: params.name,
          expectedEntryLockVersion: params.expected_entry_lock_version
        }
      }
    case 'set_type':
      return {
        case: 'setType',
        value: {
          entryId: params.entry_id,
          type: params.type,
          expectedEntryLockVersion: params.expected_entry_lock_version
        }
      }
    case 'delete_entry':
      return {
        case: 'deleteEntry',
        value: { entryId: params.entry_id, expectedEntryLockVersion: params.expected_entry_lock_version }
      }
    case 'append_block':
      return {
        case: 'appendBlock',
        value: {
          entryId: params.entry_id,
          body: params.body,
          expectedEntryLockVersion: params.expected_entry_lock_version
        }
      }
    case 'edit_block':
      return {
        case: 'editBlock',
        value: {
          entryId: params.entry_id,
          blockId: params.block_id,
          body: params.body,
          expectedBlockLockVersion: params.expected_block_lock_version
        }
      }
    case 'delete_block':
      return {
        case: 'deleteBlock',
        value: {
          entryId: params.entry_id,
          blockId: params.block_id,
          expectedBlockLockVersion: params.expected_block_lock_version
        }
      }
    case 'set_property':
      return {
        case: 'setProperty',
        value: {
          entryId: params.entry_id,
          key: params.key,
          valueJson: jsonBytes(params.value as JSONObject | undefined),
          expectedEntryLockVersion: params.expected_entry_lock_version
        }
      }
    case 'add_relation':
      return {
        case: 'addRelation',
        value: {
          entryId: params.entry_id,
          targetEntryId: params.target_entry_id,
          predicate: params.predicate,
          expectedEntryLockVersion: params.expected_entry_lock_version
        }
      }
    case 'remove_relation':
      return {
        case: 'removeRelation',
        value: {
          entryId: params.entry_id,
          relationId: params.relation_id,
          expectedEntryLockVersion: params.expected_entry_lock_version
        }
      }
    case 'set_summary':
      return {
        case: 'setSummary',
        value: {
          entryId: params.entry_id,
          summary: params.summary,
          expectedEntryLockVersion: params.expected_entry_lock_version
        }
      }
    case 'set_aliases':
      return {
        case: 'setAliases',
        value: {
          entryId: params.entry_id,
          aliases: params.aliases,
          expectedEntryLockVersion: params.expected_entry_lock_version
        }
      }
  }
}

function memoryToolResult(
  details: JSONObject,
  presentation: ReplyPresentationEvent[] = []
): AgentToolResult<MemoryToolDetails> {
  const notice = typeof details.history_notice === 'string' ? `Brain notice: ${details.history_notice}\n` : ''
  return jsonToolResult(details, { textPrefix: notice, presentation })
}

function memoryLookupEvent(operationID: string, label: string, details: JSONObject): ReplyPresentationEvent {
  return {
    kind: 'memory.lookup',
    payload: {
      operation_id: operationID,
      phase: 'completed',
      label,
      source_count: memorySourceCount(details)
    }
  }
}

function memorySourceCount(details: JSONObject): number {
  for (const key of ['results', 'entries', 'blocks']) {
    const value = details[key]
    if (Array.isArray(value)) return value.length
  }
  return details.entry && typeof details.entry === 'object' && !Array.isArray(details.entry) ? 1 : 0
}

function memoryMutationReceipt(operationID: string, operation: string): ReplyPresentationEvent {
  return {
    kind: 'memory.mutation_receipt',
    payload: {
      operation_id: operationID,
      phase: 'confirmed',
      summary: memoryMutationSummary(operation),
      scope: 'Brain 记忆'
    }
  }
}

function memoryMutationSummary(operation: string): string {
  switch (operation) {
    case 'create_entry':
      return '已创建记忆条目'
    case 'delete_entry':
      return '已删除记忆条目'
    case 'append_block':
      return '已追加记忆内容'
    case 'edit_block':
      return '已更正记忆内容'
    case 'delete_block':
      return '已删除记忆内容'
    case 'set_property':
      return '已更新记忆属性'
    case 'add_relation':
      return '已建立记忆关联'
    case 'remove_relation':
      return '已移除记忆关联'
    case 'set_summary':
      return '已更新记忆摘要'
    case 'set_aliases':
      return '已更新记忆别名'
    case 'set_name':
      return '已更新记忆名称'
    case 'set_type':
      return '已更新记忆类型'
    default:
      return '已更新记忆'
  }
}
