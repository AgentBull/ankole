import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { jsonObject, type JsonObject as JSONObject } from '@agentbull/active-support'
import { jsonFromBytes } from '../src/fabric/envelope_proto'
import { BackgroundAgentJobTurnUpsertResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { ActorTurnRef } from '../src/lanes/actor_lane'
import type { RPCRequestInit } from '../src/lanes/rpc_lane'
import { CODEX_OPT_OUT_NOTIFICATION_METHODS } from '../src/tools/codex/app-server-client'
import { BackgroundAgentJobTurnRecorder } from '../src/core/codex-runner/turn-recorder'

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
  trajectory_groups: Array<JSONObject & { messages: JSONObject[] }>
  progress: JSONObject
  usage?: JSONObject
  error: JSONObject
  started_at?: string
  completed_at?: string
}

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
    trajectory_groups: (doc(request.trajectoryGroupsJson) ?? []) as unknown as Array<
      JSONObject & { messages: JSONObject[] }
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

  it('uses item start only for active progress and completion for one canonical tool pair', async () => {
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
    expect(trajectoryMessages(upserts)).toEqual([expect.objectContaining({ role: 'user', content: '执行命令' })])

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
    expect(completed.trajectory_groups.flatMap(group => group.messages)).toEqual([
      expect.objectContaining({ role: 'assistant', tool_calls: [expect.objectContaining({ id: 'command-1' })] }),
      expect.objectContaining({ role: 'tool', tool_call_id: 'command-1', name: 'shell', content: 'hello' })
    ])

    const checkpointCount = upserts.length
    recorder.handleNotification(
      notification('item/completed', {
        item: commandItem('command-1', 'printf hello', 'hello', 'completed')
      })
    )
    await recorder.flush()
    expect(upserts).toHaveLength(checkpointCount)
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

  it('persists every completed tool without a total trajectory eviction limit', async () => {
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
    const groups = upserts.flatMap(request => request.trajectory_groups)
    expect(groups).toHaveLength(271)
    expect(new Set(groups.map(group => group.position)).size).toBe(271)
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

  it('persists pending request_user_input as the only unmatched tool call', async () => {
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

    const messages = trajectoryMessages(upserts)
    expect(messages).toContainEqual(
      expect.objectContaining({
        role: 'assistant',
        metadata: { status: 'pending_user_input' },
        tool_calls: [
          expect.objectContaining({
            id: 'request-user-input-1',
            function: expect.objectContaining({ name: 'request_user_input' })
          })
        ]
      })
    )
    expect(messages.some(message => message.role === 'tool' && message.tool_call_id === 'request-user-input-1')).toBe(
      false
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

    const serialized = JSON.stringify(trajectoryMessages(upserts))
    expect(serialized).toContain('可公开的推理摘要')
    expect(serialized).toContain('reasoning_summary')
    expect(serialized).not.toContain('RAW_PRIVATE_REASONING')
  })

  it('redacts secrets while retaining the full sequence across append-only groups', async () => {
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
    const groups = upserts.flatMap(request => request.trajectory_groups)
    const serialized = JSON.stringify(groups)
    expect(serialized).not.toContain(secret)
    expect(serialized).toContain('[REDACTED]')
    expect(serialized).toContain('FINAL_TAIL_79')
    expect(groups).toHaveLength(81)
    expect(trajectory.metadata).toMatchObject({ redacted: true, content_truncated: true })
  })
})

function fixture(delayMs = 5) {
  const upserts: DecodedUpsert[] = []
  const recorder = new BackgroundAgentJobTurnRecorder({
    jobID: '1000',
    attempt: 1,
    actorTurn,
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

function trajectoryMessages(upserts: DecodedUpsert[]) {
  return upserts.flatMap(request => request.trajectory_groups.flatMap(group => group.messages))
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
