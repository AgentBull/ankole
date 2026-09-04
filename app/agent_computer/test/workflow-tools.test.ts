import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { zodToJSONSchema } from '../src/core/llm/tool-schema'
import { actorEventText } from '../src/core/turns/actor_event_text'
import { createTextTurnTools } from '../src/core/turns/text_turn_tools'
import { jsonBytes, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import {
  AgentConversationContextResponseSchema,
  WorkflowCancelResponseSchema,
  WorkflowCreateResponseSchema,
  WorkflowGetResponseSchema,
  WorkflowListResponseSchema,
  WorkflowTaskMessageSendResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import { buildAgentSystemPrompt } from '../src/prompts/system_prompt'
import { createCancelWorkflowTool } from '../src/tools/workflow/cancel-workflow'
import { createListWorkflowsTool } from '../src/tools/workflow/list-workflows'
import { createSendMessageToWorkflowTaskTool } from '../src/tools/workflow/send-message-to-workflow-task'
import { createShowWorkflowTool } from '../src/tools/workflow/show-workflow'
import { createWorkflowTool } from '../src/tools/workflow/workflow'
import { turnStartForTest } from './support/llm'

const runID = 1000
const rawCursor = 'workflow-cursor-1000'

describe('@ankole/agent-computer Workflow parent tools', () => {
  it('publishes the bounded Workflow creation contract and projected model profiles', () => {
    const turnStart = {
      ...turnStartForTest(),
      request_context: {
        ai_agent: { max_iterations: 90 },
        custom_model_profiles: [
          { name: 'kimi', description: 'Long-context synthesis.' },
          { name: 'deepseek', description: 'Low-cost verification.' }
        ]
      }
    }
    const tool = createWorkflowTool({ turnStart, rpc: rpcReturning(createResponse()) })
    const jsonSchema = zodToJSONSchema(tool.schema) as Record<string, any>

    expect(tool.name).toBe('workflow')
    expect(Object.keys(jsonSchema.properties).sort()).toEqual([
      'args',
      'concurrency',
      'max_agent_calls',
      'model_profile',
      'script',
      'title'
    ])
    expect(jsonSchema.required.sort()).toEqual(['script', 'title'])
    expect(jsonSchema.properties.model_profile.enum).toEqual(['deepseek', 'kimi'])
    expect(tool.description).toContain('failed call resolves to null')
    expect(tool.description).toContain('Each attempt is one real subagent turn')
    expect(tool.description).toContain('one agent() call can use up to three attempts')
    expect(tool.description).toContain('must terminate')
    expect(tool.description).toContain('Every object must set additionalProperties to false')
    expect(tool.description).toContain('list every property name in required')
    expect(tool.description).toContain('default primary profile')
    expect(tool.description).not.toContain('default coding profile')
    expect(tool.schema.safeParse({ title: 'Fanout', script: "return await agent('Check');" }).success).toBe(true)
    expect(tool.schema.safeParse({ title: 'Fanout', script: 'return 1;', concurrency: 33 }).success).toBe(false)
    expect(tool.schema.safeParse({ title: 'Fanout', script: 'return 1;', max_agent_calls: 1_025 }).success).toBe(false)
    expect(tool.schema.safeParse({ title: 'Fanout', script: 'return 1;', model_profile: 'missing' }).success).toBe(
      false
    )
    expect(tool.schema.safeParse({ title: 'Fanout', script: 'x'.repeat(262_145) }).success).toBe(false)
    expect(
      tool.schema.safeParse({ title: 'Fanout', script: 'return 1;', args: { input: '界'.repeat(22_000) } }).success
    ).toBe(false)
    expect(tool.schema.safeParse({ title: 'Fanout', script: 'return 1;', action: 'create' }).success).toBe(false)
  })

  it('creates one durable run and returns its decimal handle', async () => {
    const calls: Array<{ method: unknown; payload: Record<string, unknown> }> = []
    const tool = createWorkflowTool({
      turnStart: turnStartForTest(),
      rpc: (async (method: unknown, payload: unknown) => {
        calls.push({ method, payload: payload as Record<string, unknown> })
        return createResponse()
      }) as RPCRequester
    })

    expect(tool.description).toContain('default primary profile')
    expect(tool.description).not.toContain('default coding profile')

    const result = await tool.execute(
      'call-workflow',
      {
        title: '  Verify releases  ',
        script: "return await agent('Verify', {label: 'release'});",
        args: { releases: ['v1', 'v2'] },
        concurrency: 4,
        max_agent_calls: 12
      },
      abortSignal()
    )

    expect(calls).toHaveLength(1)
    expect(calls[0]!.method).toBe(rpcMethods.workflowCreate)
    expect(calls[0]!.payload).toMatchObject({
      sourceToolCallId: 'call-workflow',
      title: 'Verify releases',
      script: "return await agent('Verify', {label: 'release'});",
      concurrency: 4,
      maxAgentCalls: 12,
      modelProfile: ''
    })
    expect(jsonObjectFromBytes(calls[0]!.payload.argsJson as Uint8Array, 'args_json')).toEqual({
      releases: ['v1', 'v2']
    })
    expect(result.details).toEqual({ run_id: runID, status: 'running' })
  })

  it('shows durable counts and failures without requesting a result window', async () => {
    const calls: Array<Record<string, unknown>> = []
    const tool = createShowWorkflowTool({
      turnStart: turnStartForTest(),
      rpc: (async (method: unknown, payload: unknown) => {
        expect(method).toBe(rpcMethods.workflowGet)
        calls.push(payload as Record<string, unknown>)
        return getResponse({ status: 'failed', error: { code: 'program_timeout', summary: 'Timed out.' } })
      }) as RPCRequester
    })

    const result = await tool.execute('call-show', { run_id: runID }, abortSignal())

    expect(calls).toEqual([{ runId: String(runID), resultOffset: '' }])
    expect(result.details).toEqual({
      run_id: runID,
      title: 'Verify releases',
      status: 'failed',
      counts: { total: 3, queued: 0, running: 0, sleeping: 0, succeeded: 2, failed: 1, cancelled: 0 },
      live_tasks: [],
      failure_summaries: [{ call_seq: 2, label: 'v2', code: 'verification_failed', summary: 'Mismatch.' }],
      error: { code: 'program_timeout', summary: 'Timed out.' }
    })
  })

  it('shows sleeping tasks with their waiting notes and attention flags', async () => {
    const liveTasks = [
      {
        call_seq: 4,
        label: 'energy',
        status: 'sleeping' as const,
        note: 'Need a decision: include offshore assets?',
        attention: true,
        sleeping_until: '2026-08-29T00:00:00Z',
        wake_count: 2
      },
      {
        call_seq: 1,
        label: 'tech',
        status: 'running' as const,
        note: null,
        attention: false,
        sleeping_until: null,
        wake_count: 0
      }
    ]
    const tool = createShowWorkflowTool({
      turnStart: turnStartForTest(),
      rpc: rpcReturning(getResponse({ liveTasks, counts: { sleeping: 1, running: 1 } }))
    })

    const result = await tool.execute('call-show-live', { run_id: runID }, abortSignal())
    if (!('live_tasks' in result.details)) throw new Error('expected Workflow details')

    expect(result.details.live_tasks).toEqual(liveTasks)
    expect(result.details.counts.sleeping).toBe(1)
    expect(tool.description).toContain('A sleeping task is still executing')
    expect(tool.description).toContain('send_message_to_workflow_task')
  })

  it('sends one asynchronous owner message to a live task', async () => {
    const calls: Array<{ method: unknown; payload: unknown }> = []
    const tool = createSendMessageToWorkflowTaskTool({
      turnStart: turnStartForTest(),
      rpc: (async (method: unknown, payload: unknown) => {
        calls.push({ method, payload })
        return create(WorkflowTaskMessageSendResponseSchema, {
          runId: String(runID),
          callSeq: 4,
          taskStatus: 'sleeping'
        })
      }) as RPCRequester
    })

    expect(tool.schema.safeParse({ run_id: runID, call_seq: 4, message: 'Include offshore assets.' }).success).toBe(
      true
    )
    expect(tool.schema.safeParse({ run_id: runID, call_seq: -1, message: 'x' }).success).toBe(false)
    expect(tool.schema.safeParse({ run_id: runID, call_seq: 4, message: '' }).success).toBe(false)

    const result = await tool.execute(
      'call-task-message',
      { run_id: runID, call_seq: 4, message: 'Include offshore assets.' },
      abortSignal()
    )

    expect(calls).toEqual([
      {
        method: rpcMethods.workflowTaskMessageSend,
        payload: {
          runId: String(runID),
          callSeq: 4,
          message: 'Include offshore assets.',
          sourceToolCallId: 'call-task-message'
        }
      }
    ])
    expect(result.details).toEqual({ run_id: runID, call_seq: 4, task_status: 'sleeping' })
  })

  it('returns a model-bounded UTF-8 result page with a stable next offset', async () => {
    const outputWindow = `BEGIN\n${'季😀"\\\n'.repeat(700)}`
    const totalBytes = new TextEncoder().encode(outputWindow).byteLength + 100
    const tool = createShowWorkflowTool({
      turnStart: turnStartForTest(),
      rpc: rpcReturning(
        getResponse({
          status: 'completed',
          outputText: outputWindow,
          totalBytes
        })
      )
    })

    const result = await tool.execute('call-show-result', { run_id: runID, result_offset: 0 }, abortSignal())
    if (!('result' in result.details)) throw new Error('expected Workflow result page')

    expect(modelVisibleBytes(result)).toBeLessThanOrEqual(8_000)
    expect(result.details.result.offset).toBe(0)
    expect(outputWindow.startsWith(result.details.result.output_text)).toBe(true)
    expect(result.details.result.next_offset).toBe(
      new TextEncoder().encode(result.details.result.output_text).byteLength
    )
    expect(result.details.result.next_offset).toBeLessThan(totalBytes)
  })

  it('keeps Workflow list cursors turn-local and exposes only page references', async () => {
    const calls: Array<Record<string, unknown>> = []
    let callCount = 0
    const tool = createListWorkflowsTool({
      turnStart: turnStartForTest(),
      rpc: (async (method: unknown, payload: unknown) => {
        expect(method).toBe(rpcMethods.workflowList)
        calls.push(payload as Record<string, unknown>)
        callCount += 1
        return callCount === 1
          ? create(WorkflowListResponseSchema, {
              runsJson: jsonBytes([{ run_id: String(runID), title: 'Verify releases', status: 'running' }]),
              nextCursor: rawCursor
            })
          : create(WorkflowListResponseSchema, { runsJson: jsonBytes([]) })
      }) as RPCRequester
    })

    expect(tool.schema.safeParse({ status: 'live' }).success).toBe(true)
    expect(tool.schema.safeParse({ status: 'done', page: 'page_1' }).success).toBe(true)
    expect(tool.schema.safeParse({ status: 'failed' }).success).toBe(false)
    expect(tool.schema.safeParse({ cursor: rawCursor }).success).toBe(false)
    await expect(tool.execute('call-list-unknown', { status: 'done', page: 'page_1' }, abortSignal())).rejects.toThrow(
      'unknown Workflow page page_1; use next_page from this turn'
    )

    const first = await tool.execute('call-list-first', {}, abortSignal())
    const second = await tool.execute('call-list-second', { status: 'done', page: 'page_1' }, abortSignal())

    expect(calls).toEqual([
      { status: 'live', cursor: '' },
      { status: 'done', cursor: rawCursor }
    ])
    expect(first.details).toEqual({
      workflows: [{ run_id: runID, title: 'Verify releases', status: 'running' }],
      next_page: 'page_1'
    })
    expect(JSON.stringify(first.details)).not.toContain(rawCursor)
    expect(second.details).toEqual({ workflows: [], next_page: null })
  })

  it('cancels idempotently through the Workflow RPC', async () => {
    const calls: Array<{ method: unknown; payload: unknown }> = []
    const tool = createCancelWorkflowTool({
      turnStart: turnStartForTest(),
      rpc: (async (method: unknown, payload: unknown) => {
        calls.push({ method, payload })
        return create(WorkflowCancelResponseSchema, { runId: String(runID), status: 'cancelled' })
      }) as RPCRequester
    })

    expect(tool.schema.safeParse({ run_id: runID }).success).toBe(true)
    expect(tool.schema.safeParse({ run_id: runID, reason: 'no longer needed' }).success).toBe(false)
    const result = await tool.execute('call-cancel', { run_id: runID }, abortSignal())

    expect(calls).toEqual([{ method: rpcMethods.workflowCancel, payload: { runId: String(runID) } }])
    expect(result.details).toEqual({ run_id: runID, status: 'cancelled' })
  })

  it('registers all four parent tools only on Text Turns', () => {
    const tools = createTextTurnTools({
      turnStart: turnStartForTest(),
      agentsRoot: '/agents',
      agentHome: '/agents/agent-1',
      workspaceRoot: '/agents/agent-1/workspace',
      userFilesRoot: '/agents/agent-1/user-files',
      enabledSkills: [],
      agentPluginCatalog: [],
      skillRoots: {
        builtinSkillsRoot: '/skills',
        agentInstalledSkillsRoot: '/agents/agent-1/skills'
      },
      rpc: (async (method: unknown) => {
        throw new Error(`unexpected RPC during tool registration: ${String(method)}`)
      }) as RPCRequester,
      workerEnv: {},
      runtimeEnv: {},
      webTools: []
    })
    const names = tools.map(tool => tool.name)

    expect(names).toEqual(
      expect.arrayContaining([
        'workflow',
        'show_workflow',
        'list_workflows',
        'send_message_to_workflow_task',
        'cancel_workflow'
      ])
    )
    expect(names).not.toContain('submit_result')
    expect(names).not.toContain('sleep')
  })
})

describe('@ankole/agent-computer Workflow prompt and terminal event context', () => {
  it('gates the bounded fanout policy on the workflow tool', () => {
    const prompt = (availableToolNames: string[]) =>
      buildAgentSystemPrompt({
        userFilesRoot: '/agents/agent-1/user-files',
        workspaceRoot: '/agents/agent-1/workspace',
        turnStart: turnStartForTest(),
        agentConversationContext: create(AgentConversationContextResponseSchema, {
          agent: { displayName: 'Test Agent' },
          conversation: { timezone: 'UTC' }
        }),
        availableToolNames
      })

    const withWorkflow = prompt(['workflow', 'show_workflow', 'list_workflows', 'cancel_workflow'])
    expect(withWorkflow).toContain('<workflow_policy>')
    expect(withWorkflow).toContain('Each attempt is one real subagent turn')
    expect(withWorkflow).toContain('one agent() call can use up to three attempts')
    expect(withWorkflow).toContain('handle a failed agent() result as null')
    expect(withWorkflow).toContain('completion or failure wakes this conversation automatically')
    expect(withWorkflow).toContain('check_back_later')
    expect(prompt(['show_workflow'])).not.toContain('<workflow_policy>')
    expect(prompt([])).not.toContain('<workflow_policy>')
  })

  it('renders completed and failed Workflow wakeups as actionable owner input', () => {
    const payload = {
      data: {
        run_id: runID,
        title: 'Verify releases',
        counts: { total: 3, succeeded: 2, failed: 1 },
        failure_summaries: [{ call_seq: 2, label: 'v2', code: 'verification_failed', summary: 'Mismatch.' }],
        result_preview: 'Two releases passed verification.'
      }
    }

    const completed = actorEventText(payload, 'workflow.run.completed')
    expect(completed).toContain('A Workflow completed.')
    expect(completed).toContain('Workflow run: 1000')
    expect(completed).toContain('Task counts: {"total":3,"succeeded":2,"failed":1}')
    expect(completed).toContain('"code":"verification_failed"')
    expect(completed).toContain('Result preview: Two releases passed verification.')
    expect(completed).toContain('result_offset 0')
    expect(completed).toContain('result.next_offset')

    const failed = actorEventText(payload, 'workflow.run.failed')
    expect(failed).toContain('A Workflow failed.')
    expect(failed).toContain('Use show_workflow with Workflow run 1000')
    expect(failed).toContain('durable error and task failures')
    expect(failed).not.toContain('result_offset 0')
  })

  it('renders a run attention wakeup as a pointer to show_workflow', () => {
    const text = actorEventText(
      {
        data: {
          run_id: runID,
          title: 'Verify releases',
          call_seq: 4,
          attention_note: 'Need a decision: include offshore assets?'
        }
      },
      'workflow.run.attention'
    )

    expect(text).toContain('A Workflow task is waiting for your input.')
    expect(text).toContain('Workflow run: 1000')
    expect(text).toContain('First waiting note: Need a decision: include offshore assets?')
    expect(text).toContain('show_workflow')
    expect(text).toContain('send_message_to_workflow_task')
    expect(text).toContain('More tasks may have started waiting')
  })
})

function createResponse() {
  return create(WorkflowCreateResponseSchema, { runId: String(runID), status: 'running' })
}

function getResponse(
  opts: {
    status?: string
    error?: Record<string, unknown>
    outputText?: string
    totalBytes?: number
    liveTasks?: Array<Record<string, unknown>>
    counts?: Record<string, number>
  } = {}
) {
  return create(WorkflowGetResponseSchema, {
    runId: String(runID),
    title: 'Verify releases',
    status: opts.status ?? 'running',
    countsJson: jsonBytes({
      total: 3,
      queued: 0,
      running: 0,
      sleeping: 0,
      succeeded: 2,
      failed: 1,
      cancelled: 0,
      ...opts.counts
    }),
    failureSummariesJson: jsonBytes([{ call_seq: 2, label: 'v2', code: 'verification_failed', summary: 'Mismatch.' }]),
    liveTasksJson: jsonBytes(opts.liveTasks ?? []),
    errorJson: jsonBytes(opts.error ?? {}),
    resultOutputText: opts.outputText ?? '',
    resultOutputTotalBytes: opts.totalBytes === undefined ? '' : String(opts.totalBytes)
  })
}

function rpcReturning(response: unknown): RPCRequester {
  return (async () => response) as RPCRequester
}

function abortSignal(): AbortSignal {
  return new AbortController().signal
}

function modelVisibleBytes(result: { content: Array<{ type: string; text?: string }> }): number {
  return new TextEncoder().encode(result.content[0]?.text ?? '').byteLength
}
