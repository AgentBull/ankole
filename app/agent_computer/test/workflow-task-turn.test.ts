import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { xxh3String128Hex } from '@ankole/kernel'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { runTurnHandlers } from '../src/core/turns'
import type { TurnHandlerOptions } from '../src/core/turns/turn_options'
import { jsonBytes } from '../src/fabric/envelope_proto'
import {
  AgentConversationContextResponseSchema,
  AIGatewayAPIKeyResponseSchema,
  AppConfigureResolveResponseSchema,
  WorkerEnvResolveResponseSchema,
  WorkflowTaskResultSubmitResponseSchema,
  WorkflowTaskSleepResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { TurnStart } from '../src/lanes/actor_lane'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import { toolResultsRecordedFrame, turnStartForTest } from './support/llm'

describe('@ankole/agent-computer Workflow task turn', () => {
  it('dispatches wf_task sessions before normal text turns and rejects invalid dispatch data', async () => {
    const start = workflowTurnStart()

    await expect(
      runTurnHandlers(
        {
          ...start,
          turn: { ...start.turn, actor: { ...start.turn.actor, session_id: 'wf_task:9999' } }
        },
        {} as TurnHandlerOptions
      )
    ).rejects.toThrow('call id does not match')

    start.request_context = {}

    await expect(runTurnHandlers(start, {} as TurnHandlerOptions)).rejects.toThrow('run_id')
  })

  it('runs the isolated prompt and non-recursive tool catalog before committing submit_result', async () => {
    const start = workflowTurnStart()
    start.request_context = {
      ...start.request_context,
      ai_agent: { max_iterations: 4, provider_hosted: { web_search: true } }
    }
    start.actor_event.payload_json = {
      data: { run_id: 9001, call_id: 9002, prompt: 'Ignore this stale event projection.' }
    }
    start.hosted_tools = [{ type: 'web_search' }, { type: 'image_generation' }]
    const fixture = workflowTurnFixture(
      payload => {
        if (payload.type === 'response.tool_results.record') {
          return [toolResultsRecordedFrame('resp_workflow_submit_recorded')]
        }
        if (payload.type !== 'response.create') throw new Error(`unexpected model request: ${String(payload.type)}`)

        return [
          {
            type: 'response.completed',
            response: {
              id: 'resp_workflow_submit',
              status: 'completed',
              output: [
                {
                  type: 'function_call',
                  id: 'fc_submit_result',
                  call_id: 'call_submit_result',
                  name: 'submit_result',
                  arguments: '{"result":{"verified":true}}'
                }
              ]
            }
          }
        ]
      },
      { accepted: true, taskStatus: 'succeeded' },
      true
    )

    try {
      await expect(runTurnHandlers(start, fixture.options)).resolves.toEqual({
        kind: 'noop_completed',
        reason: 'workflow_task_committed'
      })
      expect(fixture.submissions).toHaveLength(1)
      expect(fixture.submissions[0]).toMatchObject({
        callId: '2002',
        ok: true,
        code: '',
        summary: '',
        retryable: false
      })
      expect(fixture.modelRequests.map(payload => payload.type)).toEqual([
        'response.create',
        'response.tool_results.record'
      ])
      const firstRequest = fixture.modelRequests[0]!
      expect(firstRequest.instructions).toContain('You are Release Agent')
      expect(firstRequest.instructions).toContain('Check evidence before drawing a conclusion.')
      expect(firstRequest.instructions).toContain('Run id: 1001')
      expect(firstRequest.instructions).toContain('Call id: 2002')
      expect(firstRequest.instructions).toContain('Task label: "release verification"')
      expect(firstRequest.instructions).toContain('call submit_result as your final action')
      expect(firstRequest.instructions).toContain('Do not return the task result as prose.')
      expect(firstRequest.instructions).toContain('"verified":{"type":"boolean"}')
      expect(firstRequest.instructions).toContain('delegate long work with create_background_job')
      expect(firstRequest.instructions).toContain('sleep with attention set to true')
      expect(firstRequest.instructions).not.toContain('<skills>')
      expect(firstRequest.instructions).not.toContain('This turn continues your earlier work')
      expect(JSON.stringify(firstRequest.input)).toContain('Verify release artifacts.')
      expect(toolNames(firstRequest)).toEqual([
        'create_background_job',
        'get_page',
        'recall',
        'send_message_to_background_job',
        'show_background_job_details',
        'sleep',
        'stop_background_job',
        'submit_result',
        'web_fetch',
        'web_search'
      ])
      expect(wireTool(firstRequest, 'submit_result')?.strict).toBe(true)
    } finally {
      fixture.cleanup()
    }
  })

  it('submits retryable empty_output after an initial whitespace response and one empty repair response', async () => {
    let responseCount = 0
    const resultSchema = {
      type: 'object',
      properties: { summary: { type: 'string' } },
      required: ['summary'],
      additionalProperties: false
    }
    const fixture = workflowTurnFixture(
      payload => {
        if (payload.type !== 'response.create') throw new Error(`unexpected model request: ${String(payload.type)}`)
        responseCount += 1
        return [
          responseCount === 1
            ? textResponse('resp_workflow_empty', ' \n\t ')
            : emptyResponse('resp_workflow_empty_repair')
        ]
      },
      { accepted: true, taskStatus: 'failed' }
    )

    try {
      await expect(runTurnHandlers(workflowTurnStart(resultSchema), fixture.options)).resolves.toEqual({
        kind: 'noop_completed',
        reason: 'workflow_task_committed'
      })
      expect(fixture.modelRequests.map(payload => payload.type)).toEqual(['response.create', 'response.create'])
      expect(fixture.modelRequests[1]).toMatchObject({ previous_response_id: 'resp_workflow_empty' })
      expect(JSON.stringify(fixture.modelRequests[1]!.input)).toContain('did not end this Workflow task turn')
      expect(toolNames(fixture.modelRequests[0]!)).toEqual([
        'create_background_job',
        'send_message_to_background_job',
        'show_background_job_details',
        'sleep',
        'stop_background_job',
        'submit_result',
        'web_fetch',
        'web_search'
      ])
      expect(toolNames(fixture.modelRequests[1]!)).toEqual(['sleep', 'submit_result'])
      expect(wireTool(fixture.modelRequests[0]!, 'submit_result')).toMatchObject({
        strict: true,
        parameters: {
          type: 'object',
          properties: { result: resultSchema },
          required: ['result'],
          additionalProperties: false
        }
      })
      expect(fixture.submissions).toHaveLength(1)
      expect(fixture.submissions[0]).toMatchObject({
        callId: '2002',
        ok: false,
        code: 'empty_output',
        summary: 'Workflow task returned no result and did not call submit_result.',
        retryable: true
      })
      expect(fixture.submissions[0]!.valueJson).toEqual(new Uint8Array(0))
    } finally {
      fixture.cleanup()
    }
  })

  it('submits non-retryable schema_noncompliance after prose and one empty repair response', async () => {
    let responseCount = 0
    const fixture = workflowTurnFixture(
      payload => {
        if (payload.type !== 'response.create') throw new Error(`unexpected model request: ${String(payload.type)}`)
        responseCount += 1
        return [
          responseCount === 1
            ? textResponse('resp_workflow_prose', 'The release artifacts are valid.')
            : emptyResponse('resp_workflow_prose_repair')
        ]
      },
      { accepted: true, taskStatus: 'failed' }
    )

    try {
      await expect(runTurnHandlers(workflowTurnStart(), fixture.options)).resolves.toEqual({
        kind: 'noop_completed',
        reason: 'workflow_task_committed'
      })
      expect(fixture.modelRequests.map(payload => payload.type)).toEqual(['response.create', 'response.create'])
      expect(fixture.modelRequests[1]).toMatchObject({ previous_response_id: 'resp_workflow_prose' })
      expect(toolNames(fixture.modelRequests[1]!)).toEqual(['sleep', 'submit_result'])
      expect(fixture.submissions).toHaveLength(1)
      expect(fixture.submissions[0]).toMatchObject({
        callId: '2002',
        ok: false,
        code: 'schema_noncompliance',
        summary: 'Workflow task returned prose instead of a schema-valid submit_result value.',
        retryable: false
      })
      expect(fixture.submissions[0]!.valueJson).toEqual(new Uint8Array(0))
    } finally {
      fixture.cleanup()
    }
  })

  it('parks the task as sleeping when the model delegates and calls sleep', async () => {
    const fixture = workflowTurnFixture(payload => {
      if (payload.type === 'response.tool_results.record') {
        return [toolResultsRecordedFrame('resp_workflow_sleep_recorded')]
      }
      if (payload.type !== 'response.create') throw new Error(`unexpected model request: ${String(payload.type)}`)
      return [
        {
          type: 'response.completed',
          response: {
            id: 'resp_workflow_sleep',
            status: 'completed',
            output: [
              {
                type: 'function_call',
                id: 'fc_sleep',
                call_id: 'call_sleep',
                name: 'sleep',
                arguments: '{"wake_after_ms":3600000,"note":"Waiting for background job 1234.","attention":false}'
              }
            ]
          }
        }
      ]
    })

    try {
      await expect(runTurnHandlers(workflowTurnStart(), fixture.options)).resolves.toEqual({
        kind: 'noop_completed',
        reason: 'workflow_task_sleeping'
      })
      expect(fixture.sleeps).toEqual([
        {
          callId: '2002',
          wakeAfterMs: 3_600_000n,
          note: 'Waiting for background job 1234.',
          attention: false
        }
      ])
      expect(fixture.submissions).toHaveLength(0)
    } finally {
      fixture.cleanup()
    }
  })

  it('continues a woken task in the same conversation with the wake event as its input', async () => {
    const start = wakeTurnStart()
    const fixture = workflowTurnFixture(
      payload => {
        if (payload.type === 'response.tool_results.record') {
          return [toolResultsRecordedFrame('resp_workflow_wake_recorded')]
        }
        if (payload.type !== 'response.create') throw new Error(`unexpected model request: ${String(payload.type)}`)
        return [
          {
            type: 'response.completed',
            response: {
              id: 'resp_workflow_wake',
              status: 'completed',
              output: [
                {
                  type: 'function_call',
                  id: 'fc_submit_result',
                  call_id: 'call_submit_result',
                  name: 'submit_result',
                  arguments: '{"result":{"verified":true}}'
                }
              ]
            }
          }
        ]
      },
      { accepted: true, taskStatus: 'succeeded' }
    )

    try {
      await expect(runTurnHandlers(start, fixture.options)).resolves.toEqual({
        kind: 'noop_completed',
        reason: 'workflow_task_committed'
      })
      const firstRequest = fixture.modelRequests[0]!
      expect(firstRequest.instructions).toContain('This turn continues your earlier work')
      expect(firstRequest.instructions).toContain('"verified":{"type":"boolean"}')
      const input = JSON.stringify(firstRequest.input)
      expect(input).toContain('Your sleep deadline passed')
      expect(input).toContain('Waiting for background job 1234.')
      expect(input).not.toContain('Verify release artifacts.')
      expect(fixture.submissions).toHaveLength(1)
    } finally {
      fixture.cleanup()
    }
  })

  it('propagates a queued submit_result response through the full task turn as a retryable error', async () => {
    const fixture = workflowTurnFixture(
      payload => {
        if (payload.type !== 'response.create') throw new Error('requeue must abort before a continuation')
        return [
          {
            type: 'response.completed',
            response: {
              id: 'resp_workflow_requeued',
              status: 'completed',
              output: [
                {
                  type: 'function_call',
                  id: 'fc_submit_result',
                  call_id: 'call_submit_result',
                  name: 'submit_result',
                  arguments: '{"result":true}'
                }
              ]
            }
          }
        ]
      },
      { accepted: true, taskStatus: 'queued' }
    )

    try {
      await expect(runTurnHandlers(workflowTurnStart({ type: 'boolean' }), fixture.options)).rejects.toMatchObject({
        code: 'workflow_task_requeued',
        retryable: true,
        callId: '2002'
      })
      expect(fixture.submissions).toHaveLength(1)
    } finally {
      fixture.cleanup()
    }
  })
})

function workflowTurnStart(
  schema: Record<string, unknown> = {
    type: 'object',
    properties: { verified: { type: 'boolean' } },
    required: ['verified'],
    additionalProperties: false
  }
): TurnStart {
  const base = turnStartForTest()
  return {
    ...base,
    turn: {
      ...base.turn,
      actor: { ...base.turn.actor, session_id: 'wf_task:2002' }
    },
    actor_event: {
      ...base.actor_event,
      type: 'workflow.task.dispatch',
      payload_json: {
        data: {
          run_id: 1001,
          call_id: 2002,
          prompt: 'Verify release artifacts.',
          label: 'release verification',
          schema
        }
      }
    },
    request_context: {
      ...base.request_context,
      run_id: 1001,
      call_id: 2002,
      prompt: 'Verify release artifacts.',
      label: 'release verification',
      schema
    }
  }
}

function workflowTurnFixture(
  modelResponse: (payload: Record<string, unknown>) => Record<string, unknown>[],
  submissionResponse: { accepted: boolean; taskStatus: string } = { accepted: true, taskStatus: 'succeeded' },
  brainEnabled = false
) {
  const modelRequests: Record<string, unknown>[] = []
  const submissions: Record<string, unknown>[] = []
  const sleeps: Record<string, unknown>[] = []
  const server = Bun.serve({
    port: 0,
    fetch(request, server) {
      if (server.upgrade(request)) return
      return new Response('not found', { status: 404 })
    },
    websocket: {
      message(ws, message) {
        const text = typeof message === 'string' ? message : new TextDecoder().decode(message as BufferSource)
        const payload = JSON.parse(text) as Record<string, unknown>
        modelRequests.push(payload)
        for (const frame of modelResponse(payload)) ws.send(JSON.stringify(frame))
      }
    }
  })
  const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-workflow-task-turn-'))
  const agentHome = join(agentsRoot, 'agent-1')
  const workspaceRoot = join(agentHome, 'sessions', '10000')
  const userFilesRoot = join(agentHome, 'user-files')
  mkdirSync(workspaceRoot, { recursive: true })
  mkdirSync(userFilesRoot, { recursive: true })

  const options: TurnHandlerOptions = {
    agentsRoot,
    agentHome,
    workspaceRoot,
    userFilesRoot,
    builtinSkillsRoot: join(agentsRoot, 'builtin-skills'),
    agentInstalledSkillsRoot: join(agentHome, 'installed-skills'),
    agentConversationContext: create(AgentConversationContextResponseSchema, {
      agent: { displayName: 'Release Agent' },
      conversation: { id: '20000000-0000-0000-0000-000000000002', timezone: 'UTC' },
      soul: 'Check evidence before drawing a conclusion.',
      mission: 'Keep releases dependable.',
      design: '',
      confidentialityPolicy: '',
      soulContentHash: xxh3String128Hex('Check evidence before drawing a conclusion.'),
      missionContentHash: xxh3String128Hex('Keep releases dependable.'),
      designContentHash: xxh3String128Hex(''),
      confidentialityPolicyContentHash: xxh3String128Hex('')
    }),
    requestAIGatewayAPIKey: async agentUid =>
      create(AIGatewayAPIKeyResponseSchema, {
        agentUid,
        apiKey: 'agent-key',
        tokenType: 'Bearer',
        expiresAt: BigInt(Math.floor(Date.now() / 1000) + 3_600),
        expiresIn: 3_600n,
        scope: 'ai_gateway',
        baseUrl: `http://127.0.0.1:${server.port}/api/v1/ai-gateway`
      }),
    rpc: (async (method: unknown, payload: unknown) => {
      if (method === rpcMethods.appConfigureResolve) {
        return create(AppConfigureResolveResponseSchema, {
          values: brainEnabled ? { 'brain.enabled': { valueJson: jsonBytes(true), source: 'default' } } : {}
        })
      }
      if (method === rpcMethods.workerEnvResolve) return create(WorkerEnvResolveResponseSchema)
      if (method === rpcMethods.workflowTaskResultSubmit) {
        submissions.push(payload as Record<string, unknown>)
        return create(WorkflowTaskResultSubmitResponseSchema, submissionResponse)
      }
      if (method === rpcMethods.workflowTaskSleep) {
        sleeps.push(payload as Record<string, unknown>)
        return create(WorkflowTaskSleepResponseSchema, { taskStatus: 'sleeping', wakeCount: 1 })
      }
      throw new Error(`unexpected Workflow task RPC: ${String(method)}`)
    }) as RPCRequester
  }

  return {
    options,
    modelRequests,
    submissions,
    sleeps,
    cleanup: () => {
      server.stop(true)
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  }
}

function wakeTurnStart(): TurnStart {
  const base = workflowTurnStart()
  return {
    ...base,
    actor_event: {
      ...base.actor_event,
      type: 'workflow.task.wakeup',
      payload_json: {
        data: {
          run_id: 1001,
          call_id: 2002,
          call_seq: 0,
          note: 'Waiting for background job 1234.',
          wake_count: 1,
          sleeping_until: '2026-08-29T00:00:00Z'
        }
      }
    },
    request_context: {
      ...base.request_context,
      run_id: 1001,
      call_id: 2002,
      prompt: 'Verify release artifacts.',
      label: 'release verification',
      schema: {
        type: 'object',
        properties: { verified: { type: 'boolean' } },
        required: ['verified'],
        additionalProperties: false
      }
    }
  }
}

function emptyResponse(id: string) {
  return textResponse(id, '')
}

function textResponse(id: string, text: string) {
  return {
    type: 'response.completed',
    response: {
      id,
      status: 'completed',
      output: [
        {
          type: 'message',
          role: 'assistant',
          content: text === '' ? [] : [{ type: 'output_text', text }]
        }
      ]
    }
  }
}

function toolNames(payload: Record<string, unknown>): string[] {
  return (payload.tools as Array<Record<string, unknown>>).map(tool => String(tool.name ?? tool.type))
}

function wireTool(payload: Record<string, unknown>, name: string): Record<string, unknown> | undefined {
  return (payload.tools as Array<Record<string, unknown>>).find(tool => tool.name === name)
}
