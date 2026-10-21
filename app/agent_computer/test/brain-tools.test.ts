import { describe, expect, it } from 'bun:test'
import { brainToolDeclarations, createBrainTools } from '../src/tools/library/brain-tools'
import { buildCodexJobProjection } from '../src/core/codex-runner/job/projection'
import type { DynamicToolCallParams } from '../src/core/codex-runner/generated/protocol/v2/DynamicToolCallParams'
import { jsonBytes, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import type { RPCRequester } from '../src/lanes/rpc_lane'
import type { JobTurnRef } from '../src/lanes/session_lane'

const turn: JobTurnRef = {
  session: { session_id: 'job:1000' },
  job_id: 1000,
  attempt: 2,
  signal_id: '00000000-0000-0000-0000-000000000000'
}
const unusedRPC = (async () => {
  throw new Error('unexpected RPC')
}) as unknown as RPCRequester

// The shape `Ankole.Sessions.Tools.Brain.declarations/0` projects into the turn start.
const recallSchema = {
  type: 'object',
  properties: {
    query: { type: 'string', minLength: 1, description: 'What to search for.' },
    budget_tokens: { type: 'integer', minimum: 1, maximum: 12_000 }
  },
  required: ['query'],
  additionalProperties: false
}
const getPageSchema = {
  type: 'object',
  properties: { reference: { type: 'string', minLength: 1 } },
  required: ['reference'],
  additionalProperties: false
}
const requestContext = {
  original_human_request: 'remember the wire format',
  brain_tools: [
    {
      type: 'function',
      name: 'recall',
      description: 'Search the Brain memory.',
      parameters: recallSchema,
      activity: 'memory_recall',
      read_only: true
    },
    { type: 'function', name: 'get_page', description: 'Read one memory page.', parameters: getPageSchema }
  ]
}

describe('Job Brain read adapter', () => {
  it('projects the control-plane declarations unchanged and treats an absent list as memory off', () => {
    expect(brainToolDeclarations(undefined)).toEqual([])
    expect(brainToolDeclarations({ original_human_request: 'x' })).toEqual([])
    expect(brainToolDeclarations({ brain_tools: [] })).toEqual([])

    const declarations = brainToolDeclarations(requestContext)
    const tools = createBrainTools({ turn, rpc: unusedRPC, declarations })
    expect(tools.map(tool => tool.name)).toEqual(['recall', 'get_page'])
    for (const tool of tools) {
      expect(tool.isReadOnly).toBe(true)
      expect(tool.isDestructive).toBe(false)
    }
    expect(tools[0]!.describeActivity({})).toEqual({ key: 'conversations.delivery.reply.activity.memory_recall' })
    expect(tools[1]!.describeActivity({})).toEqual({ key: 'conversations.delivery.reply.activity.get_page' })

    const projection = buildCodexJobProjection({ tools })
    expect(projection.quarantinedTools).toEqual([])
    expect(projection.dynamicTools).toEqual([
      { type: 'function', name: 'recall', description: 'Search the Brain memory.', inputSchema: recallSchema },
      { type: 'function', name: 'get_page', description: 'Read one memory page.', inputSchema: getPageSchema }
    ])
  })

  it('rejects a malformed declaration list instead of inventing a schema', () => {
    expect(() => brainToolDeclarations({ brain_tools: {} })).toThrow('must be a list')
    expect(() => brainToolDeclarations({ brain_tools: [{ name: 'recall' }] })).toThrow('invalid declaration')
    expect(() => brainToolDeclarations({ brain_tools: [{ name: '', description: 'x', parameters: {} }] })).toThrow(
      'invalid declaration'
    )
  })

  it('executes recall and get_page through the fenced tools.read owner without local validation', async () => {
    const calls: Array<{ name: string; args: unknown; scope: unknown }> = []
    const rpc = (async (method: unknown, payload: unknown, scope: unknown) => {
      expect(method).toBe('tools.read')
      const request = payload as { name: string; argumentsJson: Uint8Array; webCacheJson?: Uint8Array }
      expect(request.webCacheJson).toBeUndefined()
      const args = jsonObjectFromBytes(request.argumentsJson, 'args')!
      calls.push({ name: request.name, args, scope })
      return request.name === 'recall'
        ? { bodyJson: jsonBytes({ output: '{"claims":[]}', details: { claims: [] } }) }
        : {
            bodyJson: jsonBytes({
              output: 'Use skill_view to load lazyload-agent-skills/ results.\n{"page":{}}',
              details: { page: { slug: 'lazyload-agent-skills/pdf' } }
            })
          }
    }) as unknown as RPCRequester
    const projection = buildCodexJobProjection({
      tools: createBrainTools({ turn, rpc, declarations: brainToolDeclarations(requestContext) })
    })
    const call = (callId: string, tool: string, args: DynamicToolCallParams['arguments']) =>
      projection.handleToolCall(
        { threadId: 'thread-1', turnId: 'turn-1', callId, namespace: null, tool, arguments: args },
        new AbortController().signal
      )

    expect(await call('call-1', 'recall', { query: 'wire format', entity: 'concepts/wire-format' })).toEqual({
      contentItems: [{ type: 'inputText', text: '{"claims":[]}' }],
      success: true
    })
    expect(await call('call-2', 'get_page', { reference: 'pdf' })).toEqual({
      contentItems: [
        { type: 'inputText', text: 'Use skill_view to load lazyload-agent-skills/ results.\n{"page":{}}' }
      ],
      success: true
    })
    // The owner validates arguments against its declaration; the Worker does not keep a second schema.
    expect(await call('call-3', 'recall', { budget_tokens: 0 })).toMatchObject({ success: true })

    expect(calls).toEqual([
      { name: 'recall', args: { query: 'wire format', entity: 'concepts/wire-format' }, scope: { jobTurn: turn } },
      { name: 'get_page', args: { reference: 'pdf' }, scope: { jobTurn: turn } },
      { name: 'recall', args: { budget_tokens: 0 }, scope: { jobTurn: turn } }
    ])
  })

  it('propagates the owner refusal without a local fallback', async () => {
    const rpc = (async () => {
      throw new Error('signal_not_owned')
    }) as unknown as RPCRequester
    const [recall] = createBrainTools({ turn, rpc, declarations: brainToolDeclarations(requestContext) })
    await expect(recall!.execute('call-1', { query: 'wire format' })).rejects.toThrow('signal_not_owned')
  })
})
