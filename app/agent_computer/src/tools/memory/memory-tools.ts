import { z } from 'zod'
import type { TurnStart } from '../../lanes/actor_lane'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import type { AgentTool, AgentToolResult } from '../../core'
import type { ReplyPresentationEvent } from '../../core/types'
import { jsonToolResult } from '../../core/tool-result'
import { jsonBytes } from '../../fabric/envelope_proto'
import { rpcMethods, type MemoryRPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import { MemoryModelReferences } from './model-references'

export interface CreateMemoryToolsOptions {
  turnStart: TurnStart
  requestMemoryRPC: MemoryRPCRequester
  modelReferences?: MemoryModelReferences
}

type MemoryToolDetails = JSONObject

const memorySelfStoreDescription =
  "Select self only for knowledge about this Agent that must apply across its conversations, such as the Agent's own operating rule, skill, or self-knowledge. Omit store for knowledge about people, requests, conversations, or channel context. The control plane then uses the current conversation's default writable store: shared for a public group, dm:<uid> for a DM, or channel:<id> for a confidential channel. Never pass current, shared, dm:<uid>, or channel:<id>; self is the only explicit selection."

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
  from: z.string().optional(),
  to: z.string().optional(),
  store: z.enum(['current', 'shared']).optional(),
  entry_type: z.string().min(1).optional(),
  author_kind: z.enum(['human', 'agent', 'dreaming']).optional(),
  limit: z.number().int().positive().optional()
})

const MemoryBrowseParams = z.object({
  source: z
    .string()
    .regex(/^source_[1-9]\d*$/)
    .optional(),
  from: z.string().optional(),
  to: z.string().optional(),
  page: z
    .string()
    .regex(/^page_[1-9]\d*$/)
    .optional(),
  limit: z.number().int().positive().max(50).optional()
})

const MemoryOpenParams = z.object({
  name: z.string().min(1),
  store: z.enum(['current', 'shared']).default('current'),
  after_position: z.number().int().positive().optional(),
  block_limit: z.number().int().positive().optional()
})

const MemoryUpdateOperationParams = z.discriminatedUnion('operation', [
  z
    .object({
      operation: z.literal('create_entry'),
      store: z.enum(['self']).describe(memorySelfStoreDescription).optional(),
      name: z.string().min(1),
      type: z.string().min(1),
      summary: z.string().optional(),
      aliases: z.array(z.string().min(1)).optional(),
      properties: z.record(z.string(), z.unknown()).optional(),
      initial_body: z.string().min(1).optional()
    })
    .strict(),
  z
    .object({
      operation: z.literal('set_name'),
      entry_name: z.string().min(1),
      name: z.string().min(1)
    })
    .strict(),
  z
    .object({
      operation: z.literal('set_type'),
      entry_name: z.string().min(1),
      type: z.string().min(1)
    })
    .strict(),
  z
    .object({
      operation: z.literal('delete_entry'),
      entry_name: z.string().min(1)
    })
    .strict(),
  z
    .object({
      operation: z.literal('append_block'),
      entry_name: z.string().min(1),
      body: z.string().min(1)
    })
    .strict(),
  z
    .object({
      operation: z.literal('edit_block'),
      entry_name: z.string().min(1),
      block_position: z.number().int().positive(),
      body: z.string().min(1)
    })
    .strict(),
  z
    .object({
      operation: z.literal('delete_block'),
      entry_name: z.string().min(1),
      block_position: z.number().int().positive()
    })
    .strict(),
  z
    .object({
      operation: z.literal('set_property'),
      entry_name: z.string().min(1),
      key: z.string().min(1),
      value: z.unknown()
    })
    .strict(),
  z
    .object({
      operation: z.literal('add_relation'),
      entry_name: z.string().min(1),
      target_entry_name: z.string().min(1),
      predicate: z.string().min(1)
    })
    .strict(),
  z
    .object({
      operation: z.literal('remove_relation'),
      entry_name: z.string().min(1),
      target_entry_name: z.string().min(1),
      predicate: z.string().min(1)
    })
    .strict(),
  z
    .object({
      operation: z.literal('set_summary'),
      entry_name: z.string().min(1),
      summary: z.string()
    })
    .strict(),
  z
    .object({
      operation: z.literal('set_aliases'),
      entry_name: z.string().min(1),
      aliases: z.array(z.string().min(1))
    })
    .strict()
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
    store: z.enum(['self']).describe(memorySelfStoreDescription).optional(),
    name: z.string().min(1).optional(),
    type: z.string().min(1).optional(),
    summary: z.string().optional(),
    aliases: z.array(z.string().min(1)).optional(),
    properties: z.record(z.string(), z.unknown()).optional(),
    initial_body: z
      .string()
      .min(1)
      .describe('Use only for the first body block of create_entry. Do not use body for create_entry.')
      .optional(),
    entry_name: z.string().min(1).optional(),
    body: z
      .string()
      .min(1)
      .describe('Use only for append_block or edit_block. Use initial_body for create_entry.')
      .optional(),
    block_position: z.number().int().positive().optional(),
    key: z.string().min(1).optional(),
    value: z.unknown().optional(),
    target_entry_name: z.string().min(1).optional(),
    predicate: z.string().min(1).optional()
  })
  .superRefine((params, context) => {
    if (params.operation === 'create_entry' && params.body !== undefined) {
      context.addIssue({
        code: 'custom',
        path: ['body'],
        message: 'create_entry uses initial_body, not body'
      })
    }

    const result = MemoryUpdateOperationParams.safeParse(params)
    if (!result.success) {
      for (const issue of result.error.issues) {
        context.addIssue({ code: 'custom', path: issue.path, message: issue.message })
      }
    }
  })

const MemoryHealthCheckParams = z.object({})

/** Creates the long-term memory tools over the turn's RPC seam. */
export function createMemoryTools(opts: CreateMemoryToolsOptions): AgentTool<any>[] {
  const modelReferences = opts.modelReferences ?? new MemoryModelReferences()
  const sharedOpts = { ...opts, modelReferences }
  return [
    createMemorySearchTool(sharedOpts),
    createMemoryOpenTool(sharedOpts),
    createMemoryUpdateTool(sharedOpts),
    createMemoryBrowseTool(sharedOpts),
    createMemoryHealthCheckTool(sharedOpts)
  ]
}

export function createMemorySearchTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemorySearchParams, MemoryToolDetails> {
  const modelReferences = opts.modelReferences ?? new MemoryModelReferences()
  return {
    name: 'memory_search',
    description:
      'Search chat history, curated entries, or both when current context does not establish the answer, or when newer state or exact provenance matters. layer is an explicit filter; all routes share one relevance ranking. Use channel_scope=all_channels only when cross-channel history is needed. Check status, result_completeness, and degraded_reasons before trusting the result: an incomplete empty result does not prove that no matching memory exists. Narrow or change the search route when useful, otherwise state the retrieval limitation instead of guessing.',
    schema: MemorySearchParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => MemoryActivity.search,
    async execute(_toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRPC(rpcMethods.memorySearch, {
        query: params.query,
        layer: params.layer,
        channelScope: params.channel_scope,
        channelId: '',
        from: params.from ?? '',
        to: params.to ?? '',
        store: params.store ?? '',
        entryType: params.entry_type ?? '',
        authorKind: params.author_kind ?? '',
        limit: params.limit
      })
      const details = modelReferences.searchResult(response)
      return memoryToolResult(details, [memoryLookupEvent(MemoryActivity.search, details)])
    }
  }
}

export function createMemoryOpenTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemoryOpenParams, MemoryToolDetails> {
  const modelReferences = opts.modelReferences ?? new MemoryModelReferences()
  return {
    name: 'memory_open',
    description:
      'Open one curated current entry by its canonical name or alias. The result uses the canonical entry name, permanent block positions, and semantic relation triples. Open every entry and block immediately before updating it. store=current prefers the conversation store over self and shared entries with the same name.',
    schema: MemoryOpenParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => MemoryActivity.open,
    async execute(_toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRPC(rpcMethods.memoryOpen, {
        entryId: '',
        name: params.name,
        store: params.store,
        blockCursor: params.after_position ? modelReferences.blockCursor(params.name, params.after_position) : '',
        blockLimit: params.block_limit
      })
      const details = modelReferences.openResult(response, params.name)
      return memoryToolResult(details, [memoryLookupEvent(MemoryActivity.open, details)])
    }
  }
}

export function createMemoryUpdateTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemoryUpdateParams, MemoryToolDetails> {
  const modelReferences = opts.modelReferences ?? new MemoryModelReferences()
  return {
    name: 'memory_update',
    description: `Apply exactly one structured mutation to a curated current entry. Select entries by canonical name, blocks by the permanent position returned by memory_open, and relations by source name, predicate, and target name. The control plane derives owner, store, author, and concurrency fences from the entry opened in this turn. ${memorySelfStoreDescription} Use the exact marker src:<source> with a source_N alias returned in this turn. Open each affected entry immediately before the update; after any update, reopen before another update.`,
    schema: MemoryUpdateParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: () => MemoryActivity.update,
    async execute(toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const operationParams = MemoryUpdateOperationParams.parse(params)
      const response = await opts.requestMemoryRPC(rpcMethods.memoryUpdate, {
        toolCallId: toolCallID,
        store: memoryUpdateStore(operationParams, modelReferences),
        operation: memoryUpdateOperation(operationParams, modelReferences)
      })
      const details = modelReferences.updateResult(response)
      modelReferences.invalidateEntries()
      return memoryToolResult(details, [memoryMutationReceipt(operationParams.operation)])
    }
  }
}

export function createMemoryBrowseTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemoryBrowseParams, MemoryToolDetails> {
  const modelReferences = opts.modelReferences ?? new MemoryModelReferences()
  return {
    name: 'memory_browse',
    description:
      'Browse exact untrusted chat messages or retained external material. Use a source_N alias returned in this turn to expand one source. Use next_page to continue a page scan of the current channel.',
    schema: MemoryBrowseParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => MemoryActivity.browse,
    async execute(_toolCallID, params): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRPC(rpcMethods.memoryBrowse, {
        documentId: params.source ? modelReferences.sourceDocument(params.source) : '',
        channelId: '',
        from: params.from ?? '',
        to: params.to ?? '',
        cursor: params.page ? modelReferences.browseCursor(params.page) : '',
        limit: params.limit
      })
      const details = modelReferences.browseResult(response)
      return memoryToolResult(details, [memoryLookupEvent(MemoryActivity.browse, details)])
    }
  }
}

function createMemoryHealthCheckTool(
  opts: CreateMemoryToolsOptions
): AgentTool<typeof MemoryHealthCheckParams, MemoryToolDetails> {
  const modelReferences = opts.modelReferences ?? new MemoryModelReferences()
  return {
    name: 'memory_health_check',
    description:
      'Read the same status used by the human console, including pipeline failures, embedding backlog, memo budget, and curation lints. Do not run automatically or modify reported entries.',
    schema: MemoryHealthCheckParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => MemoryActivity.healthCheck,
    async execute(): Promise<AgentToolResult<MemoryToolDetails>> {
      const response = await opts.requestMemoryRPC(rpcMethods.memoryHealthCheck, {})
      return memoryToolResult(modelReferences.genericResult(response))
    }
  }
}

type MemoryUpdateOperationParsed = ReturnType<typeof MemoryUpdateOperationParams.parse>

/**
 * Converts the model-facing flat operation object into the generated oneof.
 * The zod schema stays snake_case because it is the model contract; the wire
 * message is the only place the operation becomes structural.
 */
function memoryUpdateOperation(
  params: MemoryUpdateOperationParsed,
  modelReferences: MemoryModelReferences
): RPCRequestInit<'memory_update'>['operation'] {
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
          initialBody: params.initial_body ? modelReferences.expandSourceMarkers(params.initial_body) : ''
        }
      }
    case 'set_name': {
      const entry = modelReferences.entry(params.entry_name)
      return {
        case: 'setName',
        value: {
          entryId: entry.id,
          name: params.name,
          expectedEntryLockVersion: entry.lockVersion
        }
      }
    }
    case 'set_type': {
      const entry = modelReferences.entry(params.entry_name)
      return {
        case: 'setType',
        value: {
          entryId: entry.id,
          type: params.type,
          expectedEntryLockVersion: entry.lockVersion
        }
      }
    }
    case 'delete_entry': {
      const entry = modelReferences.entry(params.entry_name)
      return {
        case: 'deleteEntry',
        value: { entryId: entry.id, expectedEntryLockVersion: entry.lockVersion }
      }
    }
    case 'append_block': {
      const entry = modelReferences.entry(params.entry_name)
      return {
        case: 'appendBlock',
        value: {
          entryId: entry.id,
          body: modelReferences.expandSourceMarkers(params.body),
          expectedEntryLockVersion: entry.lockVersion
        }
      }
    }
    case 'edit_block': {
      const entry = modelReferences.entry(params.entry_name)
      const block = modelReferences.block(params.entry_name, params.block_position)
      return {
        case: 'editBlock',
        value: {
          entryId: entry.id,
          blockId: block.id,
          body: modelReferences.expandSourceMarkers(params.body),
          expectedBlockLockVersion: block.lockVersion
        }
      }
    }
    case 'delete_block': {
      const entry = modelReferences.entry(params.entry_name)
      const block = modelReferences.block(params.entry_name, params.block_position)
      return {
        case: 'deleteBlock',
        value: {
          entryId: entry.id,
          blockId: block.id,
          expectedBlockLockVersion: block.lockVersion
        }
      }
    }
    case 'set_property': {
      const entry = modelReferences.entry(params.entry_name)
      return {
        case: 'setProperty',
        value: {
          entryId: entry.id,
          key: params.key,
          valueJson: jsonBytes(params.value as JSONObject | undefined),
          expectedEntryLockVersion: entry.lockVersion
        }
      }
    }
    case 'add_relation': {
      const entry = modelReferences.entry(params.entry_name)
      const target = modelReferences.entry(params.target_entry_name)
      return {
        case: 'addRelation',
        value: {
          entryId: entry.id,
          targetEntryId: target.id,
          predicate: params.predicate,
          expectedEntryLockVersion: entry.lockVersion
        }
      }
    }
    case 'remove_relation': {
      const entry = modelReferences.entry(params.entry_name)
      const relation = modelReferences.relation(params.entry_name, params.predicate, params.target_entry_name)
      return {
        case: 'removeRelation',
        value: {
          entryId: entry.id,
          relationId: relation.id,
          expectedEntryLockVersion: entry.lockVersion
        }
      }
    }
    case 'set_summary': {
      const entry = modelReferences.entry(params.entry_name)
      return {
        case: 'setSummary',
        value: {
          entryId: entry.id,
          summary: params.summary,
          expectedEntryLockVersion: entry.lockVersion
        }
      }
    }
    case 'set_aliases': {
      const entry = modelReferences.entry(params.entry_name)
      return {
        case: 'setAliases',
        value: {
          entryId: entry.id,
          aliases: params.aliases,
          expectedEntryLockVersion: entry.lockVersion
        }
      }
    }
  }
}

function memoryUpdateStore(params: MemoryUpdateOperationParsed, modelReferences: MemoryModelReferences): string {
  if (params.operation === 'create_entry') return params.store ?? ''
  return modelReferences.entry(params.entry_name).store === 'self' ? 'self' : ''
}

function memoryToolResult(
  details: JSONObject,
  presentation: ReplyPresentationEvent[] = []
): AgentToolResult<MemoryToolDetails> {
  const notice =
    typeof details.history_notice === 'string' ? `Long-term memory result notice: ${details.history_notice}\n` : ''
  return jsonToolResult(details, { textPrefix: notice, presentation })
}

function memoryLookupEvent(label: string, details: JSONObject): ReplyPresentationEvent {
  return {
    kind: 'memory.lookup',
    payload: {
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

function memoryMutationReceipt(operation: string): ReplyPresentationEvent {
  return {
    kind: 'memory.mutation_receipt',
    payload: {
      phase: 'confirmed',
      summary: memoryMutationSummary(operation),
      scope: '长期记忆（代号 Brain）'
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
