import { describe, expect, it } from 'bun:test'
import { z } from 'zod'
import { defineWorkerTool, type WorkerAgentTool } from '../src/core'
import { buildCodexJobProjection } from '../src/core/codex-runner/job/projection'
import { projectCodexNotification } from '../src/core/codex-runner/protocol'
import { createWebTools } from '../src/tools/web/web-tools'

describe('@ankole/agent-computer Codex job capability projection', () => {
  it('projects the tools supplied by Job setup and rejects undeclared calls', async () => {
    const calls: unknown[] = []
    const tools: WorkerAgentTool[] = [
      tool('skill_view', z.object({ name: z.string() }), () => 'loaded Skill'),
      tool('web_search', z.object({ query: z.string().min(1) }), params => {
        calls.push(params)
        return 'search result'
      }),
      tool('web_fetch', z.object({ urls: z.array(z.string()) }), () => 'x'.repeat(20_000)),
      {
        ...tool('recall', z.record(z.string(), z.unknown()), () => 'recalled memory'),
        inputSchema: { type: 'object', properties: { query: { type: 'string', minLength: 1 } }, required: ['query'] }
      },
      tool('get_page', z.object({ reference: z.string() }), () => 'memory page'),
      ...['entity', 'whoknows', 'delta', 'future_brain_read'].map(name =>
        tool(name, z.object({ value: z.string() }), () => 'declared read')
      )
    ]

    const projection = buildCodexJobProjection({
      tools
    })

    expect(projection.dynamicTools.map(spec => ('name' in spec ? spec.name : undefined)).sort()).toEqual(
      [
        'web_search',
        'web_fetch',
        'skill_view',
        'recall',
        'get_page',
        'entity',
        'whoknows',
        'delta',
        'future_brain_read'
      ].sort()
    )
    expect(projection.quarantinedTools).toEqual([])
    // A tool that carries its owner's schema is declared with that schema, not a zod conversion.
    const recallSpec = projection.dynamicTools.find(spec => spec.name === 'recall')
    expect(recallSpec && 'inputSchema' in recallSpec ? recallSpec.inputSchema : undefined).toEqual({
      type: 'object',
      properties: { query: { type: 'string', minLength: 1 } },
      required: ['query']
    })

    const invalid = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-invalid',
        namespace: null,
        tool: 'web_search',
        arguments: { query: '' }
      },
      new AbortController().signal
    )
    expect(invalid.success).toBe(false)
    expect(calls).toHaveLength(0)

    const valid = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-valid',
        namespace: null,
        tool: 'web_search',
        arguments: { query: 'decision' }
      },
      new AbortController().signal
    )
    expect(valid).toEqual({ contentItems: [{ type: 'inputText', text: 'search result' }], success: true })
    expect(calls).toEqual([{ query: 'decision' }])

    const hidden = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-hidden',
        namespace: null,
        tool: 'command',
        arguments: { value: 'pwd' }
      },
      new AbortController().signal
    )
    expect(hidden.success).toBe(false)
    expect(hidden.contentItems[0]).toEqual({
      type: 'inputText',
      text: 'Dynamic tool is unavailable: command'
    })

    const brainRead = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-brain-read',
        namespace: null,
        tool: 'recall',
        arguments: { query: 'decision' }
      },
      new AbortController().signal
    )
    expect(brainRead).toEqual({ contentItems: [{ type: 'inputText', text: 'recalled memory' }], success: true })

    const brainWrite = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-brain-write',
        namespace: null,
        tool: 'remember',
        arguments: { value: 'durable claim' }
      },
      new AbortController().signal
    )
    expect(brainWrite.success).toBe(false)
    expect(brainWrite.contentItems[0]).toEqual({
      type: 'inputText',
      text: 'Dynamic tool is unavailable: remember'
    })

    const bounded = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-bounded',
        namespace: null,
        tool: 'web_fetch',
        arguments: { urls: ['https://example.com'] }
      },
      new AbortController().signal
    )
    expect(bounded.success).toBe(true)
    const boundedText = bounded.contentItems[0]?.type === 'inputText' ? bounded.contentItems[0].text : ''
    expect(new TextEncoder().encode(boundedText).byteLength).toBeLessThanOrEqual(16_384)
    expect(boundedText).toEndWith('...[truncated]')

    const screenshot = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-image',
        namespace: null,
        tool: 'browser_screenshot',
        arguments: {}
      },
      new AbortController().signal
    )
    expect(screenshot).toEqual({
      contentItems: [{ type: 'inputText', text: 'Dynamic tool is unavailable: browser_screenshot' }],
      success: false
    })
  })

  it('projects images returned by a declared tool', async () => {
    const projection = buildCodexJobProjection({ tools: [imageTool('declared_image')] })
    const result = await projection.handleToolCall(
      {
        threadId: 'thread-1',
        turnId: 'turn-1',
        callId: 'image-1',
        namespace: null,
        tool: 'declared_image',
        arguments: {}
      },
      new AbortController().signal
    )
    expect(result.success).toBe(true)
    expect(result.contentItems.some(item => item.type === 'inputImage')).toBe(true)
  })

  it('does not resolve a namespaced call to a local Job tool', async () => {
    const projection = buildCodexJobProjection({
      tools: [tool('web_search', z.object({}), () => 'local')]
    })
    expect(projection.dynamicTools).toHaveLength(1)
    const result = await projection.handleToolCall(
      {
        threadId: 'thread-1',
        turnId: 'turn-1',
        callId: 'call-1',
        namespace: 'analysis_tools',
        tool: 'web_search',
        arguments: {}
      },
      new AbortController().signal
    )
    expect(result.success).toBe(false)
  })

  it('executes a Background web call through the fenced shared owner', async () => {
    const requests: unknown[] = []
    const webTools = await createWebTools({
      turn: { session: { session_id: 'job:1000' }, job_id: 1000, attempt: 1, signal_id: 'input-1' },
      rpc: (async (method: unknown, payload: unknown, scope: unknown) => {
        requests.push({ method, name: (payload as { name: string }).name, scope })
        return { bodyJson: new TextEncoder().encode(JSON.stringify({ output: 'Search result', details: {} })) }
      }) as unknown as import('../src/lanes/rpc_lane').RPCRequester
    })
    const result = await buildCodexJobProjection({ tools: webTools }).handleToolCall(
      {
        threadId: 'thread-1',
        turnId: 'turn-1',
        callId: 'search-1',
        namespace: null,
        tool: 'web_search',
        arguments: { query: 'ankole' }
      },
      new AbortController().signal
    )
    expect(result.success).toBe(true)
    expect(requests).toEqual([
      {
        method: 'tools.read',
        name: 'web_search',
        scope: {
          jobTurn: {
            session: { session_id: 'job:1000' },
            job_id: 1000,
            attempt: 1,
            signal_id: 'input-1'
          }
        }
      }
    ])
  })

  it('quarantines duplicate tools and schemas that cannot cross the JSON boundary', () => {
    const projection = buildCodexJobProjection({
      tools: [
        tool('web_search', z.object({}), () => 'first'),
        tool('web_search', z.object({}), () => 'duplicate'),
        tool(
          'skill_view',
          z.string().transform(value => value.trim()),
          () => 'invalid schema'
        )
      ]
    })
    expect(projection.dynamicTools.map(spec => spec.name)).toEqual(['web_search'])
    expect(projection.quarantinedTools).toEqual(['web_search', 'skill_view'])
  })
})

describe('@ankole/agent-computer Codex notification projection', () => {
  it('projects item and turn notifications with their thread scope and turn identity', () => {
    const item = { type: 'commandExecution', cwd: '/workspace', command: 'ls' }
    expect(
      projectCodexNotification({
        method: 'item/started',
        params: { threadId: 'thread-2', turnId: 'turn-9', item }
      })
    ).toEqual({ type: 'item_started', threadID: 'thread-2', turnID: 'turn-9', item })

    expect(
      projectCodexNotification({
        method: 'item/completed',
        params: { threadId: 'thread-1', turnId: 'turn-3', item: { type: 'contextCompaction' } }
      })
    ).toEqual({ type: 'compaction_completed', threadID: 'thread-1', turnID: 'turn-3' })

    expect(
      projectCodexNotification({
        method: 'item/completed',
        params: {
          threadId: 'thread-1',
          turnId: 'turn-3',
          item: { type: 'agentMessage', id: 'message-1', text: 'done' }
        }
      })
    ).toEqual({ type: 'agent_completed', threadID: 'thread-1', text: 'done', phase: null })

    expect(
      projectCodexNotification({
        method: 'turn/completed',
        params: { threadId: 'thread-1', turn: { id: 'turn-3', status: 'completed' } }
      })
    ).toEqual({
      type: 'turn_completed',
      threadID: 'thread-1',
      turnID: 'turn-3',
      codexTurnStatus: 'completed',
      terminalStatus: 'succeeded',
      error: {}
    })
  })

  it('preserves assistant phases without treating intermediate or unknown phases as legacy', () => {
    for (const phase of ['commentary', 'partial_answer', 'final_answer', 'future_phase', '', null]) {
      expect(
        projectCodexNotification({
          method: 'item/completed',
          params: {
            threadId: 'thread-1',
            turnId: 'turn-3',
            item: { type: 'agentMessage', id: 'message-1', text: 'public assistant text', phase }
          }
        })
      ).toEqual({ type: 'agent_completed', threadID: 'thread-1', text: 'public assistant text', phase })
    }
  })

  it('projects a failed MCP server startup with a bounded diagnostic and ignores other statuses', () => {
    const failed = projectCodexNotification({
      method: 'mcpServer/startupStatus/updated',
      params: {
        threadId: 'thread-1',
        name: 'job-data',
        status: 'failed',
        failureReason: 'handshake',
        error: 'x'.repeat(3_000)
      }
    })
    expect(failed).toMatchObject({
      type: 'mcp_server_startup_failed',
      threadID: 'thread-1',
      server: 'job-data',
      failureReason: 'handshake'
    })
    const diagnostic = failed.type === 'mcp_server_startup_failed' ? failed.error : ''
    expect(new TextEncoder().encode(diagnostic).byteLength).toBeLessThanOrEqual(2_048)
    expect(diagnostic).toEndWith('...[truncated]')

    expect(
      projectCodexNotification({
        method: 'mcpServer/startupStatus/updated',
        params: { threadId: 'thread-1', name: 'job-data', status: 'starting', error: null, failureReason: null }
      })
    ).toEqual({ type: 'ignored' })
  })

  it('projects only the credential-pool terminal from an error notification', () => {
    expect(
      projectCodexNotification({
        method: 'error',
        params: {
          threadId: 'thread-1',
          error: {
            codexErrorInfo: 'usageLimitExceeded',
            message: 'AIGateway credential pool exhausted. retry_at=2026-07-29T08:15:00Z'
          }
        }
      })
    ).toEqual({
      type: 'credential_pool_exhausted',
      threadID: 'thread-1',
      exhaustion: { retryAt: '2026-07-29T08:15:00.000Z' }
    })

    expect(
      projectCodexNotification({
        method: 'error',
        params: { threadId: 'thread-1', error: { message: 'response stream closed before completion' } }
      })
    ).toEqual({ type: 'ignored' })
  })

  it('projects a usage-limit rejection as credential-pool exhaustion', () => {
    expect(
      projectCodexNotification({
        method: 'error',
        params: {
          threadId: 'thread-1',
          error: {
            codexErrorInfo: 'usageLimitExceeded',
            message: "You've hit your usage limit. retry_at=2030-09-16T08:00:00Z",
            additionalDetails: null
          }
        }
      })
    ).toEqual({
      type: 'credential_pool_exhausted',
      threadID: 'thread-1',
      exhaustion: { retryAt: '2030-09-16T08:00:00.000Z' }
    })
  })
})

function tool(name: string, schema: z.ZodType, execute: (params: unknown) => string): WorkerAgentTool {
  return defineWorkerTool({
    executionMode: 'sequential',
    name,
    description: `${name} description`,
    schema,
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => `测试工具：${name}`,
    async execute(_callId, params) {
      const text = execute(params)
      return { content: [{ type: 'text', text }], details: { text } }
    }
  })
}

function imageTool(name: string): WorkerAgentTool {
  return defineWorkerTool({
    executionMode: 'sequential',
    name,
    description: `${name} description`,
    schema: z.object({}),
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => `测试工具：${name}`,
    async execute() {
      return {
        content: [
          { type: 'text', text: 'screenshot saved' },
          { type: 'image', image: 'data:image/png;base64,iVBORw0KGgo=', mimeType: 'image/png' }
        ],
        details: { path: '/agents/agent-1/user-files/screenshot.png' }
      }
    }
  })
}
