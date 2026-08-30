import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { jsonObject, type JsonObject as JSONObject } from '@agentbull/active-support'
import { jsonFromBytes } from '../src/fabric/envelope_proto'
import { BackgroundAgentJobTurnUpsertResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { ActorTurnRef } from '../src/lanes/actor_lane'
import type { RPCRequestInit } from '../src/lanes/rpc_lane'
import { CODEX_OPT_OUT_NOTIFICATION_METHODS } from '../src/core/codex-runner/runtime/app-server-client'
import type { ThreadItem } from '../src/core/codex-runner/generated/protocol/v2/ThreadItem'
import { BackgroundAgentJobTurnRecorder } from '../src/core/codex-runner/job/turn-recorder'
import { RPCRejectedError } from '../src/lanes/rpc_lane'
import {
  configureWorkerTracing,
  forceFlushWorkerTracing,
  workerTurnTrace,
  type WorkerTurnTrace
} from '../src/observability/turn-tracing'

/**
 * Decoded snake_case view of one recorded upsert so assertions read the JSON
 * documents directly.
 */
type DecodedUpsert = {
  job_id?: string
  attempt?: number
  runtime_thread_id?: string
  runtime_turn_id?: string
  kind?: string
  status?: string
  revision?: number
  trajectory: JSONObject
  turn_items: Array<JSONObject & { position: number; item_key: string; item: JSONObject }>
  progress: JSONObject
  usage?: JSONObject
  error: JSONObject
  started_at?: string
  completed_at?: string
}

type CollabAgentToolItem = Extract<ThreadItem, { type: 'collabAgentToolCall' }>

function decodedUpsert(request: RPCRequestInit<'background_agent_job.turn.upsert'>): DecodedUpsert {
  const doc = (bytes: Uint8Array | undefined) => (bytes?.length ? (jsonFromBytes(bytes) as JSONObject) : undefined)
  const usage = doc(request.usageJson)
  return {
    job_id: request.jobId,
    attempt: request.attempt,
    runtime_thread_id: request.runtimeThreadId,
    runtime_turn_id: request.runtimeTurnId,
    kind: request.kind,
    status: request.status,
    revision: request.revision,
    trajectory: doc(request.trajectoryJson) ?? {},
    turn_items: (doc(request.turnItemsJson) ?? []) as unknown as Array<
      JSONObject & { position: number; item_key: string; item: JSONObject }
    >,
    progress: doc(request.progressJson) ?? {},
    ...(usage ? { usage } : {}),
    error: doc(request.errorJson) ?? {},
    started_at: request.startedAt,
    ...(request.completedAt ? { completed_at: request.completedAt } : {})
  }
}

const actorTurn: ActorTurnRef = {
  actor: { agent_uid: 'agent-1', session_id: 'job:1000' },
  activation_uid: 'activation-1',
  actor_epoch: 1,
  actor_event_id: 'event-1',
  revision: 0
}

describe('@ankole/agent-computer durable BackgroundAgentJob Turn recorder', () => {
  it('keeps the exact app-server delta opt-out contract', () => {
    expect(CODEX_OPT_OUT_NOTIFICATION_METHODS).toEqual([
      'item/agentMessage/delta',
      'item/plan/delta',
      'item/reasoning/summaryPartAdded',
      'item/reasoning/summaryTextDelta',
      'item/reasoning/textDelta',
      'item/commandExecution/outputDelta',
      'item/commandExecution/terminalInteraction',
      'item/fileChange/outputDelta',
      'item/fileChange/patchUpdated',
      'item/mcpToolCall/progress'
    ])
  })

  it('retries an explicitly retryable control-plane checkpoint failure and preserves its failure id', async () => {
    const { recorder, attempts } = rejectingFixture({
      code: 'rpc_handler_failed',
      details: { failure_id: 'failure-read-1', retryable: true }
    })
    recorder.recordTurnStarted('thread-1', startedTurn(), '原始任务', 'event-1')

    await expect(recorder.flush()).rejects.toMatchObject({
      code: 'background_agent_job_turn_persistence_failed',
      retryable: true,
      details: {
        retryable: true,
        rpc_code: 'rpc_handler_failed',
        rpc_details: { failure_id: 'failure-read-1', retryable: true }
      }
    })
    expect(attempts()).toBe(3)
  })

  it('commits the same terminal checkpoint after one retryable control-plane handler failure', async () => {
    const attempts: DecodedUpsert[] = []
    const persisted: DecodedUpsert[] = []
    const recorder = new BackgroundAgentJobTurnRecorder({
      jobID: '1000',
      attempt: 1,
      actorTurn,
      checkpointDelayMs: 0,
      upsert: async request => {
        attempts.push(decodedUpsert(request))
        if (attempts.length === 2) {
          throw new RPCRejectedError('checkpoint handler failed', {
            code: 'rpc_handler_failed',
            details: { failure_id: 'failure-upsert-1', retryable: true }
          })
        }
        persisted.push(decodedUpsert(request))
        return create(BackgroundAgentJobTurnUpsertResponseSchema, { jobId: request.jobId })
      }
    })
    recorder.recordTurnStarted('thread-1', startedTurn(), '原始任务', 'event-1')
    await recorder.flush()
    recorder.handleNotification(
      notification('turn/completed', {
        turn: {
          ...startedTurn(),
          status: 'completed',
          items: [{ type: 'agentMessage', id: 'answer-1', text: '任务已完成。' }],
          completedAt: Date.now() / 1_000
        }
      })
    )

    await recorder.flush()

    expect(attempts).toHaveLength(3)
    expect(attempts[1]).toEqual(attempts[2])
    expect(persisted).toHaveLength(2)
    expect(persisted[0]?.turn_items).toEqual([expect.objectContaining({ position: 0, item_key: 'client:event-1' })])
    expect(persisted[1]).toMatchObject({ revision: 1, status: 'completed' })
    expect(persisted[1]?.turn_items).toEqual([expect.objectContaining({ position: 1, item_key: 'answer-1' })])
  })

  it('does not retry an authoritative domain checkpoint rejection', async () => {
    const { recorder, attempts } = rejectingFixture({
      code: 'background_agent_job_turn_stale_revision',
      details: { retryable: false }
    })
    recorder.recordTurnStarted('thread-1', startedTurn(), '原始任务', 'event-1')

    await expect(recorder.flush()).rejects.toMatchObject({
      code: 'background_agent_job_turn_persistence_rejected',
      retryable: false,
      details: {
        retryable: false,
        rpc_code: 'background_agent_job_turn_stale_revision'
      }
    })
    expect(attempts()).toBe(1)
  })

  it('ignores opted-out notifications without changing revision, trajectory, progress, or checkpoint count', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '原始任务', 'event-1')
    await recorder.flush()
    const baseline = structuredClone(upserts.at(-1)!)
    const checkpointCount = upserts.length
    expect(baseline.trajectory).toEqual({ format: 'ankole_chatml', version: 1 })

    for (const method of CODEX_OPT_OUT_NOTIFICATION_METHODS) {
      recorder.handleNotification(notification(method, { itemId: 'item-1', delta: 'ignored', patch: 'ignored' }))
    }
    await recorder.flush()

    expect(upserts).toHaveLength(checkpointCount)
    expect(upserts.at(-1)).toEqual(baseline)
  })

  it('ships the initial input as one client-keyed user item exactly once', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '执行命令', 'event-1')
    await recorder.flush()

    const entries = turnItems(upserts)
    expect(entries).toEqual([
      expect.objectContaining({
        position: 0,
        item_key: 'client:event-1',
        item: expect.objectContaining({
          type: 'userMessage',
          clientId: 'event-1',
          content: [{ type: 'text', text: '执行命令' }]
        })
      })
    ])

    const checkpointCount = upserts.length
    await recorder.flush()
    expect(upserts).toHaveLength(checkpointCount)
  })

  it('uses item start only for active progress and completion for one canonical item', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '执行命令', 'event-1')
    await recorder.flush()

    recorder.handleNotification(
      notification('item/started', {
        item: commandItem('command-1', 'printf hello', '', 'inProgress')
      })
    )
    await recorder.flush()

    expect(upserts.at(-1)?.progress).toMatchObject({
      completed_items: 0,
      tool_calls: 0,
      tools_used: [],
      active_item: { id: 'command-1', name: 'shell' }
    })
    expect(turnItems(upserts).map(entry => entry.item.type)).toEqual(['userMessage'])

    recorder.handleNotification(
      notification('item/completed', {
        item: commandItem('command-1', 'printf hello', 'hello', 'completed')
      })
    )
    await recorder.flush()
    const completed = upserts.at(-1)!

    expect(completed.progress).toEqual({
      completed_items: 1,
      tool_calls: 1,
      tools_used: [{ name: 'shell', calls: 1 }],
      files_changed: []
    })
    expect(turnItems(upserts).at(-1)).toEqual(
      expect.objectContaining({
        position: 1,
        item_key: 'command-1',
        item: expect.objectContaining({
          type: 'commandExecution',
          command: 'printf hello',
          aggregatedOutput: 'hello',
          status: 'completed'
        })
      })
    )

    const checkpointCount = upserts.length
    recorder.handleNotification(
      notification('item/completed', {
        item: commandItem('command-1', 'printf hello', 'hello', 'completed')
      })
    )
    await recorder.flush()
    expect(upserts).toHaveLength(checkpointCount)
  })

  it('records Codex turns and tool items under the explicit worker turn parent', async () => {
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
      request_context: {
        traceparent: '00-11111111111111111111111111111111-1111111111111111-01'
      }
    })
    const { recorder } = fixture(0, turnTrace)

    recorder.recordTurnStarted('thread-1', startedTurn(), '执行命令', 'event-1')
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
          completedAt: Date.now() / 1_000
        }
      })
    )

    await recorder.flush()
    await forceFlushWorkerTracing()

    expect(exports).toHaveLength(1)
    const wireText = new TextDecoder().decode(exports[0])
    expect(wireText).toContain('codex.turn')
    expect(wireText).toContain('tool shell')
    expect(wireText).toContain('ankole.codex.duration_ms')
  })

  it('distinguishes provider-hosted search from a same-name local dynamic tool', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '搜索并核对', 'event-1')

    recorder.handleNotification(
      notification('item/completed', {
        item: {
          type: 'webSearch',
          id: 'hosted-search',
          query: 'example query',
          action: null,
          results: null
        }
      })
    )
    recorder.handleNotification(
      notification('item/completed', {
        item: {
          type: 'dynamicToolCall',
          id: 'local-search',
          namespace: null,
          tool: 'web_search',
          arguments: { query: 'example query' },
          status: 'completed',
          contentItems: [],
          success: true,
          durationMs: 3
        }
      })
    )
    await recorder.flush()

    expect(turnItems(upserts).map(entry => entry.item.type)).toEqual(['userMessage', 'webSearch', 'dynamicToolCall'])
    expect(upserts.at(-1)?.progress.tool_execution_mechanisms).toEqual([
      { name: 'web_search', execution_mechanism: 'local_dynamic', calls: 1 },
      { name: 'web_search', execution_mechanism: 'provider_hosted', calls: 1 }
    ])
  })

  it('persists the model-visible MCP namespace and name for durable replay', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '查询指标', 'event-1')

    recorder.handleNotification(
      notification('rawResponseItem/completed', {
        item: {
          type: 'function_call',
          call_id: 'mcp-call-1',
          namespace: 'mcp__metrics_server',
          name: 'lookup_metric',
          arguments: '{"metric":"latency"}'
        }
      })
    )
    recorder.handleNotification(
      notification('item/completed', {
        item: {
          type: 'mcpToolCall',
          id: 'mcp-call-1',
          server: 'metrics-server',
          tool: 'lookup.metric',
          arguments: { metric: 'latency' },
          result: '42',
          error: null,
          status: 'completed'
        }
      })
    )
    await recorder.flush()

    expect(turnItems(upserts).at(-1)?.item).toEqual(
      expect.objectContaining({
        type: 'mcpToolCall',
        id: 'mcp-call-1',
        namespace: 'mcp__metrics_server',
        name: 'lookup_metric'
      })
    )
    expect(upserts.at(-1)?.progress.tools_used).toEqual([
      { namespace: 'mcp__metrics_server', name: 'lookup_metric', calls: 1 }
    ])
  })

  it('reconstructs legacy MCP progress with the Codex name sanitizer', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '查询价格', 'event-1')

    recorder.handleNotification(
      notification('item/completed', {
        item: {
          type: 'mcpToolCall',
          id: 'mcp-legacy',
          server: 'my-server',
          tool: 'get-price',
          arguments: {},
          result: '42',
          error: null,
          status: 'completed'
        }
      })
    )
    await recorder.flush()

    expect(upserts.at(-1)?.progress.tools_used).toEqual([{ namespace: 'mcp__my_server', name: 'get_price', calls: 1 }])
  })

  it('records the exact MultiAgentV2 calls, outputs, and stable child identities', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '委派并收取结果', 'event-1')

    const calls = [
      {
        id: 'collab-spawn',
        tool: 'spawn_agent',
        arguments: { task_name: 'research', message: '研究 B2', fork_turns: 'none' },
        output: { task_name: '/root/research' },
        activity: { kind: 'started', agentThreadId: 'thread-child-1', agentPath: '/root/research' }
      },
      {
        id: 'collab-send',
        tool: 'send_message',
        arguments: { target: '/root/research', message: '补充核对 qm' },
        output: '',
        activity: { kind: 'interacted', agentThreadId: 'thread-child-1', agentPath: '/root/research' }
      },
      {
        id: 'collab-followup',
        tool: 'followup_task',
        arguments: { target: '/root/research', message: '继续核对' },
        output: '',
        activity: { kind: 'interacted', agentThreadId: 'thread-child-1', agentPath: '/root/research' }
      },
      {
        id: 'collab-interrupt',
        tool: 'interrupt_agent',
        arguments: { target: '/root/research' },
        output: { status: 'interrupted' },
        activity: { kind: 'interrupted', agentThreadId: 'thread-child-1', agentPath: '/root/research' }
      },
      {
        id: 'collab-list',
        tool: 'list_agents',
        arguments: {},
        output: { agents: [{ task_name: '/root/research', status: 'completed' }] }
      },
      {
        id: 'collab-wait',
        tool: 'wait_agent',
        arguments: { timeout_ms: 60_000 },
        output: { message: 'Wait completed.', timed_out: false }
      }
    ]

    for (const call of calls) {
      recorder.handleNotification(
        notification('rawResponseItem/completed', {
          item: {
            type: 'function_call',
            name: call.tool,
            namespace: 'collaboration',
            arguments: JSON.stringify(call.arguments),
            call_id: call.id
          }
        })
      )
      if (call.activity) {
        recorder.handleNotification(
          notification('item/completed', {
            item: { type: 'subAgentActivity', id: call.id, ...call.activity }
          })
        )
      }
      if (call.tool === 'wait_agent') {
        recorder.handleNotification(
          notification('item/completed', {
            item: collabItem(call.id, 'wait', { receiverThreadIds: [], agentsStates: {} })
          })
        )
      }
      recorder.handleNotification(
        notification('rawResponseItem/completed', {
          item: {
            type: 'function_call_output',
            call_id: call.id,
            output: typeof call.output === 'string' ? call.output : JSON.stringify(call.output)
          }
        })
      )
    }
    await recorder.flush()

    const entries = turnItems(upserts).filter(entry => String(entry.item_key).startsWith('collab-'))

    expect(entries).toHaveLength(calls.length)
    for (const [index, call] of calls.entries()) {
      expect(entries[index]?.item).toEqual(
        expect.objectContaining({
          type: 'dynamicToolCall',
          id: call.id,
          namespace: 'collaboration',
          tool: call.tool,
          arguments: call.arguments,
          status: 'completed'
        })
      )
    }
    expect(jsonObject(entries[0]?.item.contentItems as JSONObject)).toEqual({
      output: { task_name: '/root/research' },
      agents: [{ thread_id: 'thread-child-1', path: '/root/research', activity: 'started' }]
    })
    expect(entries.at(-1)?.item.contentItems).toEqual({
      message: 'Wait completed.',
      timed_out: false
    })
    expect(upserts.at(-1)?.progress).toMatchObject({
      tool_calls: 6,
      tools_used: [
        { namespace: 'collaboration', name: 'followup_task', calls: 1 },
        { namespace: 'collaboration', name: 'interrupt_agent', calls: 1 },
        { namespace: 'collaboration', name: 'list_agents', calls: 1 },
        { namespace: 'collaboration', name: 'send_message', calls: 1 },
        { namespace: 'collaboration', name: 'spawn_agent', calls: 1 },
        { namespace: 'collaboration', name: 'wait_agent', calls: 1 }
      ]
    })
  })

  it('keeps a stable child identity when a resumed thread has no raw response events', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '观察子 Agent', 'event-1')
    const activity = {
      type: 'subAgentActivity',
      id: 'activity-1',
      kind: 'interacted',
      agentThreadId: 'thread-child-1',
      agentPath: '/root/researcher'
    }

    recorder.handleNotification(notification('item/started', { item: activity }))
    recorder.handleNotification(notification('item/completed', { item: activity }))
    await recorder.flush()

    expect(upserts.at(-1)?.progress).toMatchObject({
      completed_items: 1,
      tool_calls: 1,
      tools_used: [{ namespace: 'collaboration', name: 'agent_interaction', calls: 1 }],
      files_changed: []
    })
    const entry = turnItems(upserts).find(candidate => candidate.item_key === 'activity-1')
    expect(entry?.item).toEqual(
      expect.objectContaining({
        type: 'dynamicToolCall',
        namespace: 'collaboration',
        tool: 'agent_interaction',
        status: 'completed'
      })
    )
    expect(entry?.item.contentItems).toEqual({
      output: '',
      agents: [{ thread_id: 'thread-child-1', path: '/root/researcher', activity: 'interacted' }]
    })
  })

  it('checkpoints the bounded set of Skills with runtime usage evidence', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), 'Use $pdf.', 'event-1')
    recorder.recordSkillUsed('turn-1', 'pdf')
    recorder.recordSkillUsed('turn-1', 'pdf')
    recorder.recordSkillUsed('turn-1', 'docx')
    await recorder.flush()

    expect(upserts.at(-1)?.progress.skills_used).toEqual(['docx', 'pdf'])
  })

  it('coalesces plan, usage, and diff snapshots and flushes them on a terminal Turn', async () => {
    const { recorder, upserts } = fixture(60_000)
    recorder.recordTurnStarted('thread-1', startedTurn(), '实现并验证', 'event-1')
    await recorder.flush()
    const baselineCount = upserts.length

    recorder.handleNotification(
      notification('turn/plan/updated', {
        explanation: '按顺序执行',
        plan: [
          { step: '修改代码', status: 'completed' },
          { step: '运行测试', status: 'inProgress' }
        ]
      })
    )
    recorder.handleNotification(
      notification('thread/tokenUsage/updated', {
        tokenUsage: tokenUsage()
      })
    )
    recorder.handleNotification(
      notification('turn/diff/updated', {
        diff: '--- a/removed.md\n+++ /dev/null\n--- /dev/null\n+++ b/brief.md\n'
      })
    )
    await Bun.sleep(5)
    expect(upserts).toHaveLength(baselineCount)

    recorder.handleNotification(
      notification('turn/completed', {
        turn: { ...startedTurn(), status: 'completed', completedAt: Date.now() / 1_000 }
      })
    )
    await recorder.flush()

    expect(upserts.at(-1)).toMatchObject({
      status: 'completed',
      progress: {
        files_changed: ['brief.md', 'removed.md'],
        plan: {
          explanation: '按顺序执行',
          steps: [
            { step: '修改代码', status: 'completed' },
            { step: '运行测试', status: 'in_progress' }
          ]
        }
      },
      usage: {
        thread_total: {
          total_tokens: 55,
          input_tokens: 40,
          cached_input_tokens: 10,
          output_tokens: 15,
          reasoning_output_tokens: 5
        },
        last_model_call: {
          total_tokens: 21,
          input_tokens: 16,
          cached_input_tokens: 2,
          output_tokens: 5,
          reasoning_output_tokens: 3
        },
        model_context_window: 200_000
      }
    })
  })

  it('persists every completed tool without a total item eviction limit', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '执行批量任务', 'event-1')

    for (let index = 0; index < 270; index += 1) {
      recorder.handleNotification(
        notification('item/completed', {
          item:
            index % 2 === 0
              ? commandItem(`command-${index}`, 'true', '', 'completed')
              : {
                  type: 'dynamicToolCall',
                  id: `dynamic-${index}`,
                  namespace: null,
                  tool: 'zeta_tool',
                  arguments: {},
                  status: 'completed',
                  contentItems: [],
                  success: true,
                  durationMs: 1
                }
        })
      )
    }
    await recorder.flush()

    const latest = upserts.at(-1)!
    expect(latest.progress).toMatchObject({
      completed_items: 270,
      tool_calls: 270,
      tools_used: [
        { name: 'shell', calls: 135 },
        { name: 'zeta_tool', calls: 135 }
      ]
    })
    const entries = turnItems(upserts)
    expect(entries).toHaveLength(271)
    expect(new Set(entries.map(entry => entry.position)).size).toBe(271)
    expect(latest.trajectory.metadata).toBeUndefined()
  })

  it('sorts tool names with the same deterministic order enforced by PostgreSQL changesets', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '执行工具', 'event-1')

    for (const [id, tool] of [
      ['upper', 'Zeta_tool'],
      ['lower', 'alpha_tool']
    ]) {
      recorder.handleNotification(
        notification('item/completed', {
          item: {
            type: 'dynamicToolCall',
            id,
            namespace: null,
            tool,
            arguments: {},
            status: 'completed',
            contentItems: [],
            success: true,
            durationMs: 1
          }
        })
      )
    }

    await recorder.flush()
    expect(upserts.at(-1)?.progress.tools_used).toEqual([
      { name: 'Zeta_tool', calls: 1 },
      { name: 'alpha_tool', calls: 1 }
    ])
  })

  it('persists pending request_user_input as one in-progress dynamic tool item', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '需要时提问', 'event-1')
    recorder.recordRequestUserInput(
      'turn-1',
      jsonObject({
        threadId: 'thread-1',
        turnId: 'turn-1',
        itemId: 'request-user-input-1',
        questions: [{ id: 'scope', question: '范围？' }]
      }),
      42
    )
    await recorder.flush()

    const entry = turnItems(upserts).find(candidate => candidate.item_key === 'request-user-input-1')
    expect(entry?.item).toEqual(
      expect.objectContaining({
        type: 'dynamicToolCall',
        tool: 'request_user_input',
        status: 'inProgress',
        arguments: { questions: [{ id: 'scope', question: '范围？' }] }
      })
    )
  })

  it('keeps only reasoning summaries and never raw reasoning text', async () => {
    const { recorder, upserts } = fixture()
    recorder.recordTurnStarted('thread-1', startedTurn(), '分析问题', 'event-1')
    recorder.handleNotification(
      notification('item/completed', {
        item: {
          type: 'reasoning',
          id: 'reasoning-1',
          summary: ['可公开的推理摘要'],
          content: ['RAW_PRIVATE_REASONING']
        }
      })
    )
    await recorder.flush()

    const entry = turnItems(upserts).find(candidate => candidate.item_key === 'reasoning-1')
    expect(entry?.item).toEqual({
      type: 'reasoning',
      id: 'reasoning-1',
      summary: ['可公开的推理摘要']
    })
    expect(JSON.stringify(turnItems(upserts))).not.toContain('RAW_PRIVATE_REASONING')
  })

  it('redacts secrets while retaining the full sequence across append-only items', async () => {
    const { recorder, upserts } = fixture()
    const secret = 'sk-secret-value-1234567890'
    recorder.recordTurnStarted('thread-1', startedTurn(), `Use api_key=${secret}`, 'event-1')

    for (let index = 0; index < 80; index += 1) {
      recorder.handleNotification(
        notification('item/completed', {
          item: commandItem(
            `command-${index}`,
            `curl -H "Authorization: Bearer ${secret}" https://example.test`,
            `${'大'.repeat(20_000)}\npassword=${secret}\nFINAL_TAIL_${index}`,
            'completed'
          )
        })
      )
    }
    await recorder.flush()

    const trajectory = upserts.at(-1)!.trajectory
    const entries = turnItems(upserts)
    const serialized = JSON.stringify(entries)
    expect(serialized).not.toContain(secret)
    expect(serialized).toContain('[REDACTED]')
    expect(serialized).toContain('FINAL_TAIL_79')
    expect(entries).toHaveLength(81)
    expect(trajectory.metadata).toMatchObject({ redacted: true, content_truncated: true })
  })
})

function fixture(delayMs = 5, turnTrace?: WorkerTurnTrace) {
  const upserts: DecodedUpsert[] = []
  const recorder = new BackgroundAgentJobTurnRecorder({
    jobID: '1000',
    attempt: 1,
    actorTurn,
    turnTrace,
    checkpointDelayMs: delayMs,
    upsert: async request => {
      upserts.push(decodedUpsert(request))
      return create(BackgroundAgentJobTurnUpsertResponseSchema, {
        jobId: request.jobId,
        turn: {
          id: `stored:${request.runtimeTurnId}`,
          attempt: request.attempt,
          runtimeThreadId: request.runtimeThreadId,
          runtimeTurnId: request.runtimeTurnId,
          kind: request.kind,
          status: request.status,
          revision: request.revision,
          trajectoryJson: request.trajectoryJson,
          progressJson: request.progressJson,
          usageJson: request.usageJson,
          errorJson: request.errorJson,
          startedAt: request.startedAt,
          completedAt: request.completedAt ?? ''
        }
      })
    }
  })
  return { recorder, upserts }
}

function rejectingFixture(rejection: { code: string; message?: string; details?: JSONObject }): {
  recorder: BackgroundAgentJobTurnRecorder
  attempts: () => number
} {
  let attemptCount = 0
  const recorder = new BackgroundAgentJobTurnRecorder({
    jobID: '1000',
    attempt: 1,
    actorTurn,
    checkpointDelayMs: 0,
    upsert: async () => {
      attemptCount += 1
      throw new RPCRejectedError('checkpoint rejected', rejection)
    }
  })
  return { recorder, attempts: () => attemptCount }
}

function turnItems(upserts: DecodedUpsert[]) {
  return upserts.flatMap(request => request.turn_items)
}

function startedTurn() {
  return jsonObject({
    id: 'turn-1',
    status: 'inProgress',
    itemsView: 'full',
    items: [],
    error: null,
    startedAt: Date.now() / 1_000,
    completedAt: null,
    durationMs: null
  })
}

function notification(method: string, params: Record<string, unknown>) {
  return {
    method,
    params: {
      threadId: 'thread-1',
      turnId: 'turn-1',
      ...params
    }
  }
}

function tokenUsage() {
  return {
    total: {
      totalTokens: 55,
      inputTokens: 40,
      cachedInputTokens: 10,
      outputTokens: 15,
      reasoningOutputTokens: 5
    },
    last: {
      totalTokens: 21,
      inputTokens: 16,
      cachedInputTokens: 2,
      outputTokens: 5,
      reasoningOutputTokens: 3
    },
    modelContextWindow: 200_000
  }
}

function commandItem(id: string, command: string, aggregatedOutput: string, status: string) {
  return {
    type: 'commandExecution',
    id,
    command,
    cwd: '/agents/agent-1/jobs/job-1',
    processId: null,
    source: 'unifiedExec',
    status,
    commandActions: [],
    aggregatedOutput,
    exitCode: status === 'completed' ? 0 : null,
    durationMs: status === 'completed' ? 1 : null
  }
}

function collabItem(
  id: string,
  tool: 'spawnAgent' | 'sendInput' | 'resumeAgent' | 'wait' | 'closeAgent',
  overrides: Partial<CollabAgentToolItem>
): CollabAgentToolItem {
  return {
    type: 'collabAgentToolCall',
    id,
    tool,
    status: 'completed',
    senderThreadId: 'thread-1',
    receiverThreadIds: [],
    prompt: null,
    model: null,
    reasoningEffort: null,
    agentsStates: {},
    ...overrides
  }
}
