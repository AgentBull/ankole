import { describe, expect, it } from 'bun:test'
import { configureWorkerTracing, forceFlushWorkerTracing, workerTurnTrace } from '../src/observability/turn-tracing'
import {
  actorTurn,
  fixture,
  startedTurn,
  notification,
  commandItem,
  collabItem,
  turnItems
} from './support/codex-turn-recorder'

describe('Codex observations from accepted recorder events', () => {
  it.each([true, false])('exports one tool span across repeated notifications, with start = %s', async withStart => {
    const { recorder, upserts, exports } = traceFixture()
    recorder.recordTurnStarted({ threadId: 'thread-1', turn: startedTurn() }, 'agent', 'execute once')
    const start = notification('item/started', {
      item: commandItem('deduplicated-call', 'printf hello', '', 'inProgress')
    })
    const completedItem = commandItem('deduplicated-call', 'printf hello', 'hello', 'completed')
    const complete = notification('item/completed', { item: completedItem })
    if (withStart) recorder.handleNotification(start)
    recorder.handleNotification(complete)
    recorder.handleNotification(complete)
    await recorder.flush()
    recorder.handleNotification(start)
    recorder.handleNotification(complete)
    recorder.handleNotification(
      notification('turn/completed', {
        turn: { ...startedTurn(), status: 'completed', items: [completedItem] }
      })
    )
    recorder.handleNotification(start)
    recorder.handleNotification(complete)
    await recorder.flush()

    const wireText = await exportedText(exports)
    expect([...wireText.matchAll(/execute_tool shell/g)]).toHaveLength(1)
    expect([...wireText.matchAll(/invoke_agent codex/g)]).toHaveLength(1)
    expect(wireText).toContain('hello')
    expect(wireText).not.toContain('codex_turn_ended')
    expect(turnItems(upserts).filter(entry => entry.item_key === 'deduplicated-call')).toHaveLength(1)
    expect(upserts.at(-1)?.progress.tool_calls).toBe(1)
  })

  it('redacts Codex content before OTLP export while retaining the larger observation window', async () => {
    const { recorder, upserts, exports } = traceFixture()
    const secret = 'sk-sensitive-value-1234567890'
    const content = `${'A'.repeat(18_000)}TRACE_ONLY_MIDDLE${'B'.repeat(18_000)}`
    recorder.recordTurnStarted({ threadId: 'thread-1', turn: startedTurn() }, 'agent', `inspect ${secret}`)
    recorder.handleNotification(
      notification('rawResponseItem/completed', {
        item: {
          type: 'function_call',
          call_id: 'mcp-call',
          namespace: 'mcp__prices',
          name: 'get_quote',
          arguments: '{}'
        }
      })
    )
    const item = {
      type: 'mcpToolCall',
      id: 'mcp-call',
      server: 'backend',
      tool: 'internal-name',
      status: 'completed',
      arguments: {
        query: 'visible-query',
        apiKey: secret,
        headers: { 'x-custom': 'PRIVATE_HEADER' },
        metadata: { memo: 'PRIVATE_METADATA' }
      },
      result: {
        content,
        credential: secret,
        text: `Bearer ${secret}`,
        image_url: 'data:image/png;base64,PRIVATE_IMAGE',
        encrypted_content: 'PRIVATE_REASONING',
        __ankole_context: 'PRIVATE_CONTROL'
      }
    }
    recorder.handleNotification(notification('item/started', { item: { ...item, status: 'inProgress', result: null } }))
    recorder.handleNotification(notification('item/completed', { item }))
    recorder.handleNotification(
      notification('turn/completed', {
        turn: {
          ...startedTurn(),
          status: 'completed',
          items: [{ type: 'agentMessage', id: 'answer', text: `done ${secret}` }]
        }
      })
    )
    await recorder.flush()

    const wireText = await exportedText(exports)
    for (const privateValue of [
      secret,
      'PRIVATE_HEADER',
      'PRIVATE_METADATA',
      'PRIVATE_IMAGE',
      'PRIVATE_REASONING',
      'PRIVATE_CONTROL'
    ]) {
      expect(wireText).not.toContain(privateValue)
    }
    expect(wireText).toContain('[REDACTED]')
    expect(wireText).toContain('[inline media omitted]')
    expect(wireText).toContain('visible-query')
    expect(wireText).toContain('TRACE_ONLY_MIDDLE')
    expect(JSON.stringify(turnItems(upserts))).not.toContain('TRACE_ONLY_MIDDLE')
    expect(JSON.stringify(turnItems(upserts))).not.toContain(secret)
    expect(item.arguments.apiKey).toBe(secret)
    expect(item.result.content).toBe(content)
    expect(wireText).toContain('execute_tool mcp__prices.get_quote')
    expect(upserts.at(-1)?.progress.tools_used).toEqual([{ namespace: 'mcp__prices', name: 'get_quote', calls: 1 }])
  })

  it('deduplicates raw collaboration pairs and preserves exact content over summary events', async () => {
    const { recorder, upserts, exports } = traceFixture()
    recorder.recordTurnStarted({ threadId: 'thread-1', turn: startedTurn() }, 'agent', 'delegate')
    const args = { task_name: 'research', message: '研究 B2', api_key: 'PRIVATE_COLLABORATION_KEY' }
    const call = notification('rawResponseItem/completed', {
      item: {
        type: 'function_call',
        call_id: 'spawn-call',
        namespace: 'collaboration',
        name: 'spawn_agent',
        arguments: JSON.stringify(args)
      }
    })
    const activity = notification('item/completed', {
      item: {
        type: 'subAgentActivity',
        id: 'spawn-call',
        kind: 'started',
        agentThreadId: 'child-1',
        agentPath: '/root/research'
      }
    })
    const output = notification('rawResponseItem/completed', {
      item: {
        type: 'function_call_output',
        call_id: 'spawn-call',
        output: JSON.stringify({ task_name: '/root/research' })
      }
    })
    const summary = collabItem('spawn-call', 'spawnAgent', { prompt: 'SUMMARY_ONLY' })
    recorder.handleNotification(notification('item/started', { item: summary }))
    for (const event of [
      call,
      call,
      activity,
      activity,
      notification('item/completed', { item: summary }),
      output,
      output
    ])
      recorder.handleNotification(event)
    await recorder.flush()
    for (const event of [call, activity, output]) recorder.handleNotification(event)
    recorder.handleNotification(notification('turn/completed', { turn: { ...startedTurn(), status: 'completed' } }))
    await recorder.flush()

    const wireText = await exportedText(exports)
    expect([...wireText.matchAll(/execute_tool collaboration.spawn_agent/g)]).toHaveLength(1)
    expect(wireText).toContain('"message":"研究 B2"')
    expect(wireText).toContain('"task_name":"/root/research"')
    expect(wireText).toContain('"thread_id":"child-1"')
    expect(wireText).not.toContain('SUMMARY_ONLY')
    expect(wireText).not.toContain('PRIVATE_COLLABORATION_KEY')
    expect(turnItems(upserts).filter(entry => entry.item_key === 'spawn-call')).toHaveLength(1)
    expect(upserts.at(-1)?.progress.tool_calls).toBe(1)
  })

  it('exports the retained activity fallback once when a resumed thread has no raw pairs', async () => {
    const { recorder, upserts, exports } = traceFixture()
    recorder.recordTurnStarted({ threadId: 'thread-1', turn: startedTurn() }, 'agent', 'resume')
    const activity = notification('item/completed', {
      item: {
        type: 'subAgentActivity',
        id: 'activity-1',
        kind: 'interacted',
        agentThreadId: 'child-1',
        agentPath: '/root/research'
      }
    })
    recorder.handleNotification(activity)
    recorder.handleNotification(activity)
    recorder.handleNotification(notification('turn/completed', { turn: { ...startedTurn(), status: 'completed' } }))
    await recorder.flush()
    const wireText = await exportedText(exports)
    expect([...wireText.matchAll(/execute_tool collaboration.agent_interaction/g)]).toHaveLength(1)
    expect(wireText).toContain('"thread_id":"child-1"')
    expect(turnItems(upserts).filter(entry => entry.item_key === 'activity-1')).toHaveLength(1)
  })

  it('closes an interrupted tool and ignores late starts after the turn ends', async () => {
    const { recorder, exports } = traceFixture()
    recorder.recordTurnStarted({ threadId: 'thread-1', turn: startedTurn() }, 'agent', 'execute')
    const start = notification('item/started', { item: commandItem('interrupted-call', 'sleep 10', '', 'inProgress') })
    recorder.handleNotification(start)
    recorder.interruptTurn('turn-1', { code: 'operator_interrupt' })
    recorder.handleNotification(start)
    recorder.handleNotification(
      notification('item/completed', { item: commandItem('interrupted-call', 'sleep 10', '', 'completed') })
    )
    await recorder.flush()
    const wireText = await exportedText(exports)
    expect([...wireText.matchAll(/execute_tool shell/g)]).toHaveLength(1)
    expect([...wireText.matchAll(/invoke_agent codex/g)]).toHaveLength(1)
    expect(wireText).toContain('operator_interrupt')
  })

  it('records Codex turns and tool items under the explicit worker turn parent', async () => {
    const { recorder, exports } = traceFixture()

    recorder.recordTurnStarted({ threadId: 'thread-1', turn: startedTurn() }, 'agent', '执行命令', 'event-1')
    recorder.handleNotification(
      notification('item/started', {
        item: commandItem('command-1', 'printf hello', '', 'inProgress')
      })
    )
    recorder.handleNotification(
      notification('item/completed', {
        item: commandItem('command-1', 'printf hello', 'hello', 'completed')
      })
    )
    recorder.handleNotification(
      notification('turn/completed', {
        turn: {
          ...startedTurn(),
          status: 'completed',
          items: [{ type: 'agentMessage', id: 'answer-1', text: '命令执行完成。' }],
          completedAt: Date.now() / 1_000
        }
      })
    )

    await recorder.flush()
    await forceFlushWorkerTracing()

    expect(exports).toHaveLength(1)
    const wireText = new TextDecoder().decode(exports[0])
    expect(wireText).toContain('invoke_agent codex')
    expect(wireText).toContain('execute_tool shell')
    expect(wireText).toContain('ankole.agent.input')
    expect(wireText).toContain('ankole.agent.output')
    expect(wireText).toContain('gen_ai.tool.call.arguments')
    expect(wireText).toContain('gen_ai.tool.call.result')
    expect(wireText).toContain('执行命令')
    expect(wireText).toContain('printf hello')
    expect(wireText).toContain('hello')
    expect(wireText).toContain('命令执行完成。')
    expect(wireText).toContain('ankole.codex.duration_ms')
    expect(wireText).not.toContain('langfuse.')
    expect(wireText).not.toContain('langsmith.')
  })
})

function traceFixture() {
  const exports: Uint8Array[] = []
  configureWorkerTracing(async payload => {
    exports.push(payload)
  })
  const turnTrace = workerTurnTrace({
    workspace_id: 10_000,
    turn: actorTurn,
    actor_event: {
      actor_event_id: actorTurn.actor_event_id,
      queue_sequence: 1,
      type: 'background_agent_job.dispatch',
      source_event_id: 'job-1000'
    },
    request_context: { traceparent: '00-11111111111111111111111111111111-1111111111111111-01' }
  })
  expect(turnTrace).toBeDefined()
  return { ...fixture(0, turnTrace), exports }
}

async function exportedText(exports: Uint8Array[]): Promise<string> {
  await forceFlushWorkerTracing()
  return exports.map(payload => new TextDecoder().decode(payload)).join('\n')
}
