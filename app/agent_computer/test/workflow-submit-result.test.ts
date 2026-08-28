import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { jsonFromBytes } from '../src/fabric/envelope_proto'
import { WorkflowTaskResultSubmitResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { RPCRejectedError, rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import {
  createWorkflowSubmitResultTool,
  submitWorkflowTaskFailure,
  WorkflowTaskRequeuedError
} from '../src/tools/workflow/submit-result'
import { turnStartForTest } from './support/llm'

describe('@ankole/agent-computer submit_result tool', () => {
  it('publishes the task schema under one strict result property and commits flat RPC fields', async () => {
    const requests: Array<{ method: unknown; payload: Record<string, unknown>; frame: unknown }> = []
    let terminal = false
    const tool = createWorkflowSubmitResultTool({
      callId: '42',
      resultSchema: {
        type: 'object',
        properties: { score: { type: 'integer' } },
        required: ['score'],
        additionalProperties: false
      },
      rpc: (async (method: unknown, payload: unknown, frame: unknown) => {
        requests.push({ method, payload: payload as Record<string, unknown>, frame })
        return response(true, 'succeeded')
      }) as RPCRequester,
      turn: turnStartForTest().turn,
      onTerminal: () => {
        terminal = true
      },
      onRequeued: () => {
        throw new Error('unexpected requeue')
      }
    })

    expect(tool.jsonSchema).toEqual({
      type: 'object',
      properties: {
        result: {
          type: 'object',
          properties: { score: { type: 'integer' } },
          required: ['score'],
          additionalProperties: false
        }
      },
      required: ['result'],
      additionalProperties: false
    })
    expect(tool.strict).toBe(true)
    expect(tool.schema.safeParse({}).success).toBe(false)
    expect(tool.schema.safeParse({ result: { score: 9 }, extra: true }).success).toBe(false)

    const result = await tool.execute('submit-1', { result: { score: 9 } }, new AbortController().signal)

    expect(requests).toHaveLength(1)
    expect(requests[0]!.method).toBe(rpcMethods.workflowTaskResultSubmit)
    expect(requests[0]!.frame).toEqual({ turn: turnStartForTest().turn })
    expect(requests[0]!.payload).toMatchObject({
      callId: '42',
      ok: true,
      code: '',
      summary: '',
      retryable: false
    })
    expect(jsonFromBytes(requests[0]!.payload.valueJson as Uint8Array)).toEqual({ score: 9 })
    expect(result).toMatchObject({
      details: { accepted: true, task_status: 'succeeded' },
      terminate: true
    })
    expect(terminal).toBe(true)
  })

  it('leaves a control-plane schema rejection as a recoverable tool error', async () => {
    const rejection = new RPCRejectedError('workflow.task.result.submit', {
      code: 'workflow_result_schema_mismatch',
      message: 'score must be an integer'
    })
    let terminal = false
    const tool = createWorkflowSubmitResultTool({
      callId: '42',
      resultSchema: { type: 'integer' },
      rpc: (async () => {
        throw rejection
      }) as RPCRequester,
      turn: turnStartForTest().turn,
      onTerminal: () => {
        terminal = true
      },
      onRequeued: () => {
        throw new Error('unexpected requeue')
      }
    })

    await expect(tool.execute('submit-2', { result: 'wrong' }, new AbortController().signal)).rejects.toBe(rejection)
    expect(terminal).toBe(false)
  })

  it('turns a queued retry response into a tagged turn-abort error', async () => {
    const controller = new AbortController()
    let terminal = false
    let observed: WorkflowTaskRequeuedError | undefined
    const tool = createWorkflowSubmitResultTool({
      callId: '42',
      resultSchema: { type: 'string' },
      rpc: (async () => response(true, 'queued')) as RPCRequester,
      turn: turnStartForTest().turn,
      onTerminal: () => {
        terminal = true
      },
      onRequeued: error => {
        observed = error
        controller.abort(error)
      }
    })

    await expect(tool.execute('submit-3', { result: 'retry me' }, controller.signal)).rejects.toMatchObject({
      code: 'workflow_task_requeued',
      retryable: true,
      callId: '42'
    })
    expect(controller.signal.reason).toBe(observed)
    expect(terminal).toBe(false)
  })

  it('ends cleanly when cancellation wins the submission race', async () => {
    let terminal = false
    const tool = createWorkflowSubmitResultTool({
      callId: '42',
      resultSchema: { type: 'string' },
      rpc: (async () => response(false, 'cancelled')) as RPCRequester,
      turn: turnStartForTest().turn,
      onTerminal: () => {
        terminal = true
      },
      onRequeued: () => {
        throw new Error('unexpected requeue')
      }
    })

    const result = await tool.execute('submit-4', { result: 'late' }, new AbortController().signal)

    expect(result).toMatchObject({ details: { accepted: false, task_status: 'cancelled' }, terminate: true })
    expect(terminal).toBe(true)
  })

  it('commits an unsubmitted failure with flat fields and propagates retry requeue', async () => {
    const requests: Array<Record<string, unknown>> = []
    const rpc = (async (_method: unknown, payload: unknown) => {
      requests.push(payload as Record<string, unknown>)
      return response(true, 'failed')
    }) as RPCRequester

    const details = await submitWorkflowTaskFailure(
      { callId: '42', rpc, turn: turnStartForTest().turn },
      { code: 'schema_noncompliance', summary: 'Use submit_result.', retryable: false }
    )

    expect(requests).toEqual([
      {
        callId: '42',
        ok: false,
        valueJson: new Uint8Array(0),
        code: 'schema_noncompliance',
        summary: 'Use submit_result.',
        retryable: false
      }
    ])
    expect(details).toEqual({ accepted: true, task_status: 'failed' })

    await expect(
      submitWorkflowTaskFailure(
        {
          callId: '43',
          rpc: (async () => response(true, 'queued')) as RPCRequester,
          turn: turnStartForTest().turn
        },
        { code: 'empty_output', summary: 'No result.', retryable: true }
      )
    ).rejects.toMatchObject({ code: 'workflow_task_requeued', retryable: true })
  })
})

function response(accepted: boolean, taskStatus: string) {
  return create(WorkflowTaskResultSubmitResponseSchema, { accepted, taskStatus })
}
