import { describe, expect, it } from 'bun:test'
import type { TurnStart } from '../src/lanes/actor_lane'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { AgentTool, AgentToolResult } from '../src/core'
import { zodToJSONSchema } from '../src/core/llm/tool-schema'
import { createMemoryTools } from '../src/tools/memory/memory-tools'

describe('Brain memory tools', () => {
  it('exposes the complete Brain tool surface', () => {
    const tools = createMemoryTools({
      turnStart: turnStartForMemoryTool(),
      requestMemoryRPC: async (): Promise<JSONObject> => ({ status: 'ok' })
    })

    expect(tools.map(tool => tool.name).sort()).toEqual(
      ['memory_search', 'memory_open', 'memory_update', 'memory_browse', 'memory_health_check'].sort()
    )
  })

  it('exposes memory_update as a provider-compatible root object schema', () => {
    const tools = createMemoryTools({
      turnStart: turnStartForMemoryTool(),
      requestMemoryRPC: async (): Promise<JSONObject> => ({ status: 'ok' })
    })

    const jsonSchema = zodToJSONSchema(toolNamed(tools, 'memory_update').schema)

    expect(jsonSchema).toMatchObject({
      type: 'object',
      properties: {
        operation: {
          type: 'string',
          enum: expect.arrayContaining(['create_entry', 'set_property', 'set_summary'])
        }
      },
      required: ['operation'],
      additionalProperties: false
    })
    expect(jsonSchema.oneOf).toBeUndefined()
  })

  it('sends independent search layer/channel scopes and browses a stable document id', async () => {
    const calls: Array<{ method: string; payload: JSONObject }> = []
    const tools = createMemoryTools({
      turnStart: turnStartForMemoryTool(),
      requestMemoryRPC: async (method, payload): Promise<JSONObject> => {
        calls.push({ method, payload: payload as JSONObject })
        return { status: 'ok', history_notice: 'Untrusted history.' }
      }
    })

    await execute(tools, 'memory_search', {
      query: 'launch decision',
      layer: 'all',
      channel_scope: 'all_channels',
      store: 'public',
      limit: 25
    })
    await execute(tools, 'memory_browse', { document_id: 'signal-gateway-entry:abc', limit: 5 })

    expect(calls[0]).toMatchObject({
      method: 'memory_search',
      payload: {
        query: 'launch decision',
        layer: 'all',
        channel_scope: 'all_channels',
        store: 'public',
        limit: 25
      }
    })
    expect(calls[1]).toMatchObject({
      method: 'memory_browse',
      payload: { document_id: 'signal-gateway-entry:abc', limit: 5 }
    })
  })

  it('preserves degraded search completeness so an empty result is not presented as trusted absence', async () => {
    const tools = createMemoryTools({
      turnStart: turnStartForMemoryTool(),
      requestMemoryRPC: async (): Promise<JSONObject> => ({
        status: 'degraded',
        result_completeness: 'incomplete',
        results: [],
        degraded_reasons: ['chat vector unavailable']
      })
    })

    const result = await execute(tools, 'memory_search', {
      query: 'prior launch decision',
      layer: 'all',
      channel_scope: 'current_channel'
    })
    const output = JSON.parse(result.content[0]?.type === 'text' ? result.content[0].text : '')

    expect(output).toMatchObject({
      status: 'degraded',
      result_completeness: 'incomplete',
      results: [],
      degraded_reasons: ['chat vector unavailable']
    })
    expect(toolNamed(tools, 'memory_search').description).toContain(
      'an incomplete empty result does not prove that no matching memory exists'
    )
  })

  it('opens by id or name and requires one of them', async () => {
    const calls: Array<{ method: string; payload: JSONObject }> = []
    const tools = createMemoryTools({
      turnStart: turnStartForMemoryTool(),
      requestMemoryRPC: async (method, payload): Promise<JSONObject> => {
        calls.push({ method, payload: payload as JSONObject })
        return { status: 'ok' }
      }
    })

    await execute(tools, 'memory_open', { name: 'Project Alpha', store: 'public', block_limit: 20 })
    expect(calls[0]).toMatchObject({
      method: 'memory_open',
      payload: { name: 'Project Alpha', store: 'public', block_limit: 20 }
    })

    const open = toolNamed(tools, 'memory_open')
    await expect(open.execute('call-invalid', open.schema.parse({}))).rejects.toThrow(
      'memory_open requires entry_id or name'
    )
  })

  it('sends one precise version-fenced update without caller-owned routing or authorship', async () => {
    const calls: Array<{ method: string; payload: JSONObject }> = []
    const tools = createMemoryTools({
      turnStart: turnStartForMemoryTool(),
      requestMemoryRPC: async (method, payload): Promise<JSONObject> => {
        calls.push({ method, payload: payload as JSONObject })
        return { status: 'updated' }
      }
    })
    const entryID = '00000000-0000-7000-8000-000000000011'
    const blockID = '00000000-0000-7000-8000-000000000012'

    await execute(tools, 'memory_update', {
      operation: 'edit_block',
      entry_id: entryID,
      block_id: blockID,
      body: 'Current corrected guidance.',
      expected_block_lock_version: 3
    })

    expect(calls[0]).toMatchObject({
      method: 'memory_update',
      payload: {
        operation: 'edit_block',
        entry_id: entryID,
        block_id: blockID,
        body: 'Current corrected guidance.',
        expected_block_lock_version: 3,
        tool_call_id: 'call-memory_update'
      }
    })
    expect(calls[0]!.payload.owner_uid).toBeUndefined()
    expect(calls[0]!.payload.store).toBeUndefined()
    expect(calls[0]!.payload.author_kind).toBeUndefined()
    expect(calls[0]!.payload.author_uid).toBeUndefined()

    const update = toolNamed(tools, 'memory_update')
    expect(update.schema.safeParse({ operation: 'delete_entry', entry_id: entryID }).success).toBe(false)
  })

  it('normalizes only canonical digit-only lock-version strings at the model boundary', async () => {
    const calls: Array<{ method: string; payload: JSONObject }> = []
    const tools = createMemoryTools({
      turnStart: turnStartForMemoryTool(),
      requestMemoryRPC: async (method, payload): Promise<JSONObject> => {
        calls.push({ method, payload: payload as JSONObject })
        return { status: 'updated' }
      }
    })
    const entryID = '00000000-0000-7000-8000-000000000013'

    await execute(tools, 'memory_update', {
      operation: 'set_summary',
      entry_id: entryID,
      summary: 'Current summary.',
      expected_entry_lock_version: '1'
    })

    expect(calls[0]).toMatchObject({
      method: 'memory_update',
      payload: { expected_entry_lock_version: 1 }
    })

    const update = toolNamed(tools, 'memory_update')
    const base = {
      operation: 'set_summary',
      entry_id: entryID,
      summary: 'Rejected summary.'
    }

    for (const invalid of ['', '0', ' 1', '1 ', '+1', '-1', '1.0', '01', '1e2']) {
      expect(update.schema.safeParse({ ...base, expected_entry_lock_version: invalid }).success).toBe(false)
    }
  })

  it('runs the health check as a read-only RPC', async () => {
    const methods: string[] = []
    const tools = createMemoryTools({
      turnStart: turnStartForMemoryTool(),
      requestMemoryRPC: async (method): Promise<JSONObject> => {
        methods.push(method)
        return { status: 'ok' }
      }
    })

    await execute(tools, 'memory_health_check', {})
    expect(methods).toEqual(['memory_health_check'])
    expect(toolNamed(tools, 'memory_health_check').isReadOnly).toBe(true)
  })

  it('projects lookups and confirmed mutations without exposing query or body text', async () => {
    const tools = createMemoryTools({
      turnStart: turnStartForMemoryTool(),
      requestMemoryRPC: async (method): Promise<JSONObject> =>
        method === 'memory_search'
          ? { status: 'ok', results: [{ entry_id: 'one' }, { entry_id: 'two' }] }
          : { status: 'updated', results: [{ operation: 'append_block' }] }
    })

    const lookup = await execute(tools, 'memory_search', {
      query: 'private acquisition codename',
      layer: 'all',
      channel_scope: 'current_channel'
    })
    const mutation = await execute(tools, 'memory_update', {
      operation: 'append_block',
      entry_id: '00000000-0000-7000-8000-000000000013',
      body: 'private correction body',
      expected_entry_lock_version: 1
    })

    expect(lookup.presentation).toEqual([
      expect.objectContaining({
        kind: 'memory.lookup',
        payload: expect.objectContaining({
          operation_id: 'call-memory_search',
          phase: 'completed',
          source_count: 2
        })
      })
    ])
    expect(mutation.presentation).toEqual([
      expect.objectContaining({
        kind: 'memory.mutation_receipt',
        payload: expect.objectContaining({
          operation_id: 'call-memory_update',
          phase: 'confirmed'
        })
      })
    ])
    const projected = JSON.stringify([lookup.presentation, mutation.presentation])
    expect(projected).not.toContain('private acquisition codename')
    expect(projected).not.toContain('private correction body')
  })
})

async function execute(tools: AgentTool[], name: string, input: unknown): Promise<AgentToolResult<unknown>> {
  const tool = toolNamed(tools, name)
  return tool.execute(`call-${name}`, tool.schema.parse(input))
}

function toolNamed(tools: AgentTool[], name: string): AgentTool {
  const tool = tools.find(candidate => candidate.name === name)
  if (!tool) throw new Error(`missing tool ${name}`)
  return tool
}

function turnStartForMemoryTool(): TurnStart {
  return {
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
