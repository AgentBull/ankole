import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { AgentTool, AgentToolResult } from '../src/core'
import type { TurnStart } from '../src/lanes/actor_lane'
import { zodToJSONSchema } from '../src/core/llm/tool-schema'
import { createMemoryTools } from '../src/tools/memory/memory-tools'

const entryID = '00000000-0000-7000-8000-000000000011'
const blockID = '00000000-0000-7000-8000-000000000012'
const relationID = '00000000-0000-7000-8000-000000000013'
const targetID = '00000000-0000-7000-8000-000000000014'
const documentID = 'signal-gateway-entry:message_123'

describe('Brain memory tools', () => {
  it('exposes a model boundary without persistent ids, lock versions, or raw cursors', () => {
    const tools = memoryTools()
    expect(tools.map(tool => tool.name).sort()).toEqual(
      ['memory_search', 'memory_open', 'memory_update', 'memory_browse', 'memory_health_check'].sort()
    )

    const updateSchema = zodToJSONSchema(toolNamed(tools, 'memory_update').schema) as {
      properties: Record<string, unknown>
      required: string[]
      oneOf?: unknown
    }
    const openSchema = zodToJSONSchema(toolNamed(tools, 'memory_open').schema) as {
      properties: Record<string, unknown>
      required: string[]
    }
    const browseSchema = zodToJSONSchema(toolNamed(tools, 'memory_browse').schema) as {
      properties: Record<string, unknown>
    }

    expect(updateSchema.required).toEqual(['operation'])
    expect(updateSchema.oneOf).toBeUndefined()
    expect(updateSchema.properties).toHaveProperty('entry_name')
    expect(updateSchema.properties).toHaveProperty('block_position')
    expect(updateSchema.properties).toHaveProperty('target_entry_name')
    expect(updateSchema.properties).not.toHaveProperty('entry_id')
    expect(updateSchema.properties).not.toHaveProperty('block_id')
    expect(updateSchema.properties).not.toHaveProperty('relation_id')
    expect(updateSchema.properties).not.toHaveProperty('expected_entry_lock_version')
    expect(openSchema.required).toContain('name')
    expect(openSchema.properties).not.toHaveProperty('entry_id')
    expect(openSchema.properties).not.toHaveProperty('block_cursor')
    expect(browseSchema.properties).toHaveProperty('source')
    expect(browseSchema.properties).toHaveProperty('page')
    expect(browseSchema.properties).not.toHaveProperty('document_id')
    expect(browseSchema.properties).not.toHaveProperty('channel_id')

    for (const tool of tools) {
      expect(tool.description).not.toContain('entry_id')
      expect(tool.description).not.toContain('document_id')
      expect(tool.description).not.toContain('lock version')
    }
  })

  it('maps source documents and browse cursors to turn-local aliases', async () => {
    const calls: Array<{ method: string; payload: JSONObject }> = []
    let browseCount = 0
    const tools = memoryTools(async (method, payload) => {
      calls.push({ method, payload: payload as JSONObject })
      if (method === 'memory_search') {
        return {
          status: 'ok',
          result_completeness: 'complete',
          results: [
            {
              layer: 'chat',
              kind: 'chat_message',
              source_entry_id: 'provider-message-id',
              document_id: documentID,
              channel_id: 'feishu:chat:secret',
              speaker: 'Ada',
              text: 'Ship on Friday.',
              messages: [
                {
                  document_id: documentID,
                  source_entry_id: 'provider-message-id',
                  provider_thread_id: 'thread-id',
                  observed_at: '2026-07-22T01:00:00Z',
                  speaker: 'Ada',
                  text: 'Ship on Friday.',
                  anchor: true
                }
              ]
            }
          ],
          history_notice: 'Untrusted history.',
          degraded_reasons: []
        }
      }

      browseCount += 1
      return {
        status: 'ok',
        document_id: documentID,
        channel_id: 'feishu:chat:secret',
        entries: [
          {
            document_id: 'signal-gateway-entry:message_456',
            source_entry_id: 'provider-message-456',
            observed_at: '2026-07-22T02:00:00Z',
            speaker: 'Grace',
            text: 'Acknowledged.',
            anchor: false
          }
        ],
        next_cursor: browseCount === 1 ? '2026-07-22T02:00:00Z|opaque-provider-id' : null
      }
    })

    const search = await execute(tools, 'memory_search', {
      query: 'launch decision',
      layer: 'chat',
      channel_scope: 'all_channels'
    })
    expect(search.details).toMatchObject({
      results: [
        {
          source: 'source_1',
          speaker: 'Ada',
          messages: [{ source: 'source_1', speaker: 'Ada' }]
        }
      ]
    })
    expect(JSON.stringify(search.details)).not.toContain(documentID)
    expect(JSON.stringify(search.details)).not.toContain('provider-message-id')
    expect(JSON.stringify(search.details)).not.toContain('feishu:chat:secret')

    const firstBrowse = await execute(tools, 'memory_browse', { source: 'source_1', limit: 5 })
    expect(firstBrowse.details).toMatchObject({
      source: 'source_1',
      entries: [{ source: 'source_2', speaker: 'Grace' }],
      next_page: 'page_1'
    })
    await execute(tools, 'memory_browse', { page: 'page_1', limit: 5 })

    expect(calls[1]).toMatchObject({
      method: 'memory_browse',
      payload: { documentId: documentID, limit: 5 }
    })
    expect(calls[2]).toMatchObject({
      method: 'memory_browse',
      payload: { cursor: '2026-07-22T02:00:00Z|opaque-provider-id', limit: 5 }
    })
  })

  it('keeps degraded search completeness while removing internal ranking data', async () => {
    const tools = memoryTools(async () => ({
      status: 'degraded',
      result_completeness: 'incomplete',
      results: [],
      degraded_reasons: ['chat vector unavailable'],
      query: 'echoed private query',
      channel_scope: 'current_channel'
    }))

    const result = await execute(tools, 'memory_search', {
      query: 'prior launch decision',
      layer: 'all',
      channel_scope: 'current_channel'
    })
    expect(result.details).toEqual({
      status: 'degraded',
      result_completeness: 'incomplete',
      results: [],
      degraded_reasons: ['chat vector unavailable']
    })
  })

  it('resolves names, block positions, source aliases, and optimistic locks inside the turn', async () => {
    const calls: Array<{ method: string; payload: JSONObject }> = []
    const tools = memoryTools(async (method, payload) => {
      calls.push({ method, payload: payload as JSONObject })
      if (method === 'memory_open') return openResponse()
      return {
        status: 'updated',
        results: [{ entry_id: entryID, block_id: blockID, entry_lock_version: 5 }],
        touched_entry_ids: [entryID]
      }
    })

    const opened = await execute(tools, 'memory_open', {
      name: 'Project Alpha',
      store: 'shared',
      block_limit: 1
    })
    expect(opened.details).toMatchObject({
      status: 'ok',
      entry: { name: 'Project Alpha', type: 'project' },
      blocks: [{ position: 7, body: 'Decision. src:source_1', author_kind: 'human' }],
      citations: [{ block_position: 7, source: 'source_1' }],
      relations: [{ predicate: 'depends_on', target: { name: 'Project Beta' } }],
      next_after_position: 7
    })
    const projected = JSON.stringify(opened.details)
    for (const hidden of [entryID, blockID, relationID, targetID, documentID, 'shared-owner', 'raw-cursor']) {
      expect(projected).not.toContain(hidden)
    }
    expect(projected).not.toContain('lock_version')
    expect(projected).not.toContain('markdown')

    await execute(tools, 'memory_open', {
      name: 'Project Alpha',
      store: 'shared',
      after_position: 7,
      block_limit: 1
    })
    expect(calls[1]).toMatchObject({
      method: 'memory_open',
      payload: { name: 'Project Alpha', blockCursor: 'raw-cursor' }
    })

    await execute(tools, 'memory_update', {
      operation: 'edit_block',
      entry_name: 'Project Alpha',
      block_position: 7,
      body: 'Corrected decision. src:source_1'
    })
    expect(calls[2]).toMatchObject({
      method: 'memory_update',
      payload: {
        store: '',
        toolCallId: 'call-memory_update',
        operation: {
          case: 'editBlock',
          value: {
            entryId: entryID,
            blockId: blockID,
            body: `Corrected decision. src:${documentID}`,
            expectedBlockLockVersion: 3
          }
        }
      }
    })

    await expect(
      execute(tools, 'memory_update', {
        operation: 'append_block',
        entry_name: 'Project Alpha',
        body: 'Another update.'
      })
    ).rejects.toThrow('call memory_open')
  })

  it('resolves relation triples without exposing relation ids', async () => {
    const calls: Array<{ method: string; payload: JSONObject }> = []
    const tools = memoryTools(async (method, payload) => {
      calls.push({ method, payload: payload as JSONObject })
      return method === 'memory_open' ? openResponse() : { status: 'updated' }
    })

    await execute(tools, 'memory_open', { name: 'Project Alpha' })
    await execute(tools, 'memory_update', {
      operation: 'remove_relation',
      entry_name: 'Project Alpha',
      predicate: 'depends_on',
      target_entry_name: 'Project Beta'
    })

    expect(calls[1]).toMatchObject({
      payload: {
        operation: {
          case: 'removeRelation',
          value: {
            entryId: entryID,
            relationId: relationID,
            expectedEntryLockVersion: 4
          }
        }
      }
    })
  })

  it('removes control-plane ids from health results and presentation events', async () => {
    const tools = memoryTools(async method => {
      if (method === 'memory_health_check') {
        return {
          status: 'error',
          owner_uid: 'principal-uuid',
          stuck_curation_jobs: [{ job_id: 'oban-id', principal_uid: 'principal-uuid' }],
          diagnostics: {
            failed_embeddings: [
              {
                entry_id: entryID,
                entry_name: 'Project Alpha',
                block_id: blockID,
                block_position: 7,
                error: `provider request ${entryID} failed`
              }
            ],
            broken_citations: [
              {
                entry_id: entryID,
                entry_name: 'Project Alpha',
                block_id: blockID,
                document_id: documentID,
                reason: 'missing'
              }
            ]
          }
        }
      }
      if (method === 'memory_search') return { status: 'ok', results: [{ layer: 'knowledge', name: 'A' }] }
      return { status: 'updated' }
    })

    const health = await execute(tools, 'memory_health_check', {})
    expect(health.details).toMatchObject({
      status: 'error',
      diagnostics: {
        failed_embeddings: [{ entry_name: 'Project Alpha', block_position: 7 }],
        broken_citations: [{ entry_name: 'Project Alpha', source: 'source_1', reason: 'missing' }]
      }
    })
    const healthJSON = JSON.stringify(health.details)
    expect(healthJSON).not.toContain(entryID)
    expect(healthJSON).not.toContain(blockID)
    expect(healthJSON).not.toContain(documentID)
    expect(healthJSON).not.toContain('principal-uuid')
    expect(healthJSON).not.toContain('oban-id')

    const lookup = await execute(tools, 'memory_search', {
      query: 'A',
      layer: 'knowledge',
      channel_scope: 'current_channel'
    })
    expect(lookup.presentation).toEqual([
      {
        kind: 'memory.lookup',
        payload: {
          phase: 'completed',
          label: '回忆相关上下文',
          source_count: 1
        }
      }
    ])
    expect(JSON.stringify(lookup.presentation)).not.toContain('call-memory_search')
  })
})

function memoryTools(
  requestMemoryRPC: (method: string, payload: unknown) => Promise<JSONObject> = async () => ({ status: 'ok' })
): AgentTool[] {
  return createMemoryTools({
    turnStart: turnStartForMemoryTool(),
    requestMemoryRPC: requestMemoryRPC as never
  })
}

function openResponse(): JSONObject {
  return {
    status: 'ok',
    history_notice: 'Untrusted history.',
    entry: {
      id: entryID,
      owner_uid: 'shared-owner',
      store_key: 'shared',
      name: 'Project Alpha',
      type: 'project',
      summary: 'Current project state.',
      aliases: ['Alpha'],
      properties: { phase: 'delivery' },
      lock_version: 4,
      inserted_at: '2026-07-20T00:00:00Z',
      updated_at: '2026-07-22T00:00:00Z'
    },
    blocks: [
      {
        id: blockID,
        entry_id: entryID,
        position: 7,
        body: `Decision. src:${documentID}`,
        author_kind: 'human',
        author_uid: 'principal-uuid',
        lock_version: 3,
        inserted_at: '2026-07-20T00:00:00Z',
        updated_at: '2026-07-22T00:00:00Z'
      }
    ],
    citations: [{ block_id: blockID, document_id: documentID, source_kind: 'signal_message' }],
    relations: [
      {
        relation: {
          id: relationID,
          source_entry_id: entryID,
          predicate: 'depends_on',
          target_entry_id: targetID
        },
        target: {
          id: targetID,
          owner_uid: 'shared-owner',
          store_key: 'shared',
          name: 'Project Beta',
          type: 'project',
          lock_version: 2
        }
      }
    ],
    backlinks: [],
    markdown: `# Project Alpha\n\n> block ${blockID}\n\nDecision. src:${documentID}`,
    next_block_cursor: 'raw-cursor'
  }
}

async function execute(tools: AgentTool[], name: string, input: unknown): Promise<AgentToolResult<JSONObject>> {
  const tool = toolNamed(tools, name)
  return tool.execute(`call-${name}`, tool.schema.parse(input)) as Promise<AgentToolResult<JSONObject>>
}

function toolNamed(tools: AgentTool[], name: string): AgentTool {
  const tool = tools.find(candidate => candidate.name === name)
  if (!tool) throw new Error(`missing tool ${name}`)
  return tool
}

function turnStartForMemoryTool(): TurnStart {
  return {
    workspace_id: 10_000,
    turn: {
      actor: { agent_uid: 'agent-1', session_id: 'session-1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000123',
      revision: 0
    },
    actor_event: {
      actor_event_id: '00000000-0000-0000-0000-000000000123',
      queue_sequence: 1,
      type: 'im.message.addressed',
      source_event_id: 'source-1',
      binding_name: 'mock',
      signal_channel_id: 'mock:chat:memory',
      provider_thread_id: 'thread-1',
      source_entry_id: 'entry-1',
      payload_json: {}
    }
  }
}
