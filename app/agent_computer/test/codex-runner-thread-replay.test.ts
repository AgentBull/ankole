import { describe, expect, it } from 'bun:test'
import { wireItemsFromTurnItems, replayCallID } from '../src/core/codex-runner/thread-replay'

describe('@ankole/agent-computer thread replay conversion', () => {
  it('converts user, assistant, and paired tool items to wire response items', () => {
    const wire = wireItemsFromTurnItems([
      { type: 'userMessage', id: 'u1', content: [{ type: 'text', text: '创建标记文件' }] },
      {
        type: 'commandExecution',
        id: 'c1',
        command: 'printf marker > context-marker.txt',
        cwd: '/workdir',
        status: 'completed',
        aggregatedOutput: '',
        exitCode: 0,
        durationMs: 3
      },
      { type: 'agentMessage', id: 'a1', text: 'SOURCE_DONE' }
    ])

    expect(wire).toEqual([
      { type: 'message', role: 'user', content: [{ type: 'input_text', text: '创建标记文件' }] },
      {
        type: 'function_call',
        call_id: 'c1',
        name: 'shell',
        arguments: JSON.stringify({ command: 'printf marker > context-marker.txt', cwd: '/workdir' })
      },
      { type: 'function_call_output', call_id: 'c1', output: '\n[exit_code: 0]' },
      { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'SOURCE_DONE' }] }
    ])
  })

  it('always pairs a function call with an output, including interrupted user-input requests', () => {
    const wire = wireItemsFromTurnItems([
      {
        type: 'dynamicToolCall',
        id: 'ask-1',
        namespace: null,
        tool: 'request_user_input',
        arguments: { questions: [{ id: 'scope', question: '范围？' }] },
        status: 'inProgress',
        contentItems: null
      }
    ])

    const calls = wire.filter(item => item.type === 'function_call')
    const outputs = wire.filter(item => item.type === 'function_call_output')
    expect(calls).toHaveLength(1)
    expect(outputs).toHaveLength(1)
    expect(outputs[0]?.output).toContain('interrupted')
  })

  it('preserves namespaced dynamic and collaboration identities as separate wire fields', () => {
    const wire = wireItemsFromTurnItems([
      {
        type: 'dynamicToolCall',
        id: 'spawn-1',
        namespace: 'collaboration',
        tool: 'spawn_agent',
        arguments: { message: 'review' },
        status: 'completed',
        contentItems: [{ type: 'inputText', text: 'started' }]
      },
      {
        type: 'collabAgentToolCall',
        id: 'send-1',
        tool: 'sendInput',
        receiverThreadIds: ['thread-2'],
        agentsStates: {}
      }
    ])

    expect(wire[0]).toMatchObject({
      type: 'function_call',
      call_id: 'spawn-1',
      namespace: 'collaboration',
      name: 'spawn_agent'
    })
    expect(wire[2]).toMatchObject({
      type: 'function_call',
      call_id: 'send-1',
      namespace: 'collaboration',
      name: 'send_message'
    })
    expect(wire[0]).not.toHaveProperty('name', 'collaboration.spawn_agent')
  })

  it('uses persisted MCP wire identity and keeps the legacy reconstruction namespaced', () => {
    const wire = wireItemsFromTurnItems([
      {
        type: 'mcpToolCall',
        id: 'mcp-current',
        server: 'raw-server',
        tool: 'raw-tool',
        namespace: 'mcp__model_server',
        name: 'model_tool',
        arguments: {},
        result: 'ok'
      },
      {
        type: 'mcpToolCall',
        id: 'mcp-legacy',
        server: 'legacy-server',
        tool: 'lookup-metric',
        arguments: {},
        result: 'ok'
      }
    ])

    expect(wire[0]).toMatchObject({ namespace: 'mcp__model_server', name: 'model_tool' })
    expect(wire[2]).toMatchObject({ namespace: 'mcp__legacy_server', name: 'lookup_metric' })
  })

  it('drops reasoning, compaction markers, and empty content instead of inventing wire items', () => {
    const wire = wireItemsFromTurnItems([
      { type: 'reasoning', id: 'r1', summary: ['摘要'] },
      { type: 'contextCompaction', id: 'compact-1' },
      { type: 'agentMessage', id: 'empty', text: '' },
      { type: 'sleep', id: 's1', durationMs: 5 }
    ])
    expect(wire).toEqual([])
  })

  it('replaces non-text user parts with an omission marker instead of dropping the message', () => {
    const wire = wireItemsFromTurnItems([
      {
        type: 'userMessage',
        id: 'u1',
        content: [
          { type: 'text', text: '看这张图：' },
          { type: 'image', url: 'data:image/png;base64,AAAA' }
        ]
      }
    ])
    expect(wire).toEqual([
      {
        type: 'message',
        role: 'user',
        content: [{ type: 'input_text', text: '看这张图：[image omitted]' }]
      }
    ])
  })

  it('caps replayed call ids at the wire limit deterministically', () => {
    const long = 'x'.repeat(80)
    expect(replayCallID('short')).toBe('short')
    expect(replayCallID(long)).toHaveLength(64)
    expect(replayCallID(long)).toBe(replayCallID(long))
  })
})
