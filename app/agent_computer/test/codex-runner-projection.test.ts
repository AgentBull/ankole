import { describe, expect, it } from 'bun:test'
import { z } from 'zod'
import { defineWorkerTool, type WorkerAgentTool } from '../src/core'
import { buildCodexJobProjection } from '../src/core/codex-runner/job/projection'
import { projectCodexNotification } from '../src/core/codex-runner/protocol'
import { createWebTools } from '../src/tools/web/web-tools'

describe('@ankole/agent-computer Codex job capability projection', () => {
  it('projects the exact Job allowlist and rejects browser and foreground-only tools', async () => {
    const calls: unknown[] = []
    const tools: WorkerAgentTool[] = [
      tool('skill_view', z.object({ name: z.string() }), () => 'loaded Skill'),
      tool('scratch_note', z.object({ content: z.string() }), () => 'must stay hidden'),
      tool('web_search', z.object({ query: z.string().min(1) }), params => {
        calls.push(params)
        return 'search result'
      }),
      tool('web_fetch', z.object({ urls: z.array(z.string()) }), () => 'x'.repeat(20_000)),
      tool('recall', z.object({ query: z.string() }), () => 'recalled memory'),
      tool('get_page', z.object({ reference: z.string() }), () => 'memory page'),
      ...['remember', 'forget', 'entity', 'whoknows', 'synthesize', 'delta'].map(name =>
        tool(name, z.object({ value: z.string() }), () => 'must stay hidden')
      ),
      tool('browser_navigate', z.object({ url: z.string() }), () => 'page snapshot'),
      imageTool('browser_screenshot'),
      ...['browser_run', 'command', 'interactive_terminal', 'read_file', 'apply_patch', 'reply_attachment'].map(name =>
        tool(name, z.object({ value: z.string() }), () => 'must stay hidden')
      ),
      tool(
        'browser_snapshot',
        z.string().transform(value => value.trim()),
        () => 'quarantined'
      )
    ]

    const projection = buildCodexJobProjection({
      tools
    })

    expect(projection.dynamicTools.map(spec => ('name' in spec ? spec.name : undefined)).sort()).toEqual(
      ['web_search', 'web_fetch', 'skill_view'].sort()
    )
    expect(projection.quarantinedTools).toEqual([])

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

  it('does not resolve a namespaced call to a local Job tool', async () => {
    const projection = buildCodexJobProjection({
      tools: [namespacedTool('analysis_tools', 'web_search'), tool('web_search', z.object({}), () => 'local')]
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

  it('executes a Background web call through its AIGateway semantic selector', async () => {
    const requests: Array<{ url: string; body: unknown }> = []
    const webTools = await createWebTools({
      aiGateway: {
        baseURL: 'https://control.test/api/v1/ai-gateway',
        fetch: async (input, init) => {
          requests.push({
            url: input instanceof Request ? input.url : String(input),
            body: JSON.parse(String(init?.body))
          })
          return new Response(
            JSON.stringify({
              success: true,
              results: [{ title: 'Ankole', url: 'https://example.com', snippet: 'Result' }]
            }),
            { status: 200, headers: { 'content-type': 'application/json' } }
          )
        }
      },
      workspaceRoot: '/tmp',
      repeatFetchSessionKey: 'codex-runner-projection-test'
    })
    const projection = buildCodexJobProjection({ tools: webTools })

    const result = await projection.handleToolCall(
      {
        threadId: 'thread-1',
        turnId: 'turn-1',
        callId: 'call-web-search',
        namespace: null,
        tool: 'web_search',
        arguments: { query: 'ankole' }
      },
      new AbortController().signal
    )

    expect(result.success).toBe(true)
    expect(requests).toEqual([
      {
        url: 'https://control.test/api/v1/ai-gateway/web_search',
        body: { model: 'web_search.default', query: 'ankole' }
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
    ).toEqual({ type: 'agent_completed', threadID: 'thread-1', text: 'done' })

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
})

function namespacedTool(namespace: string, name: string): WorkerAgentTool {
  return defineWorkerTool({
    executionMode: 'sequential',
    name,
    description: 'Inspect data.',
    schema: z.object({}),
    jsonSchema: { type: 'object', properties: {} },
    namespace,
    namespaceDescription: `${namespace} tools`,
    deferLoading: true,
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => 'Inspect data',
    async execute() {
      return { content: [{ type: 'text', text: 'inspected' }], details: {} }
    }
  })
}

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
