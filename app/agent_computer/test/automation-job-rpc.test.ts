import { create, fromBinary, toBinary } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import {
  AutomationJobRunRequestSchema,
  AutomationJobRunResponseSchema,
  RuntimeSkillSummarySchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import {
  decodeEnvelope,
  encodeEnvelope,
  ProtocolVersion,
  RPCRequestSchema,
  type Envelope
} from '../src/fabric/envelope_proto'
import { handleWorkerRPCRequest } from '../src/lanes/rpc_lane'

describe('automation job worker RPC', () => {
  it('decodes the typed request and returns the typed run result on the same request id', async () => {
    const sent: Envelope[] = []
    const runRequest = create(AutomationJobRunRequestSchema, {
      automationJobRunId: '1000',
      automationJobId: '1001',
      attemptId: '019fb2b4-1fd1-7d30-8b3d-c5e2250f6b9c',
      drivePrefix: 'automation/test',
      label: 'Test consumer',
      eventJson: new TextEncoder().encode('{}'),
      timeoutMs: 600_000,
      bindingName: 'lark-secondary',
      skills: [
        create(RuntimeSkillSummarySchema, {
          skillName: 'bullx-financial-data',
          sourceKind: 'builtin',
          relativePath: 'bullx-financial-data'
        })
      ]
    })

    await handleWorkerRPCRequest(
      async envelope => {
        sent.push(envelope)
      },
      create(RPCRequestSchema, {
        requestId: 'automation-run-request',
        deadlineUnixMs: BigInt(Date.now() + 5_000),
        method: 'automation_job.run',
        payload: toBinary(AutomationJobRunRequestSchema, runRequest)
      }),
      {
        runAutomationJob: async request => {
          expect(request).toMatchObject({
            automationJobRunId: '1000',
            automationJobId: '1001',
            bindingName: 'lark-secondary',
            skills: [expect.objectContaining({ skillName: 'bullx-financial-data' })]
          })
          return {
            status: 'succeeded',
            exitCode: 0,
            stdout: 'done',
            stderr: '',
            stdoutTruncated: false,
            stderrTruncated: false
          }
        }
      }
    )

    expect(sent).toHaveLength(1)
    // The host writes the version at send time; assert the wire header shape.
    expect(decodeEnvelope(encodeEnvelope({ ...sent[0]!, protocolVersion: ProtocolVersion.CURRENT }))).toMatchObject({})

    const body = sent[0]!.body
    if (body.case !== 'rpcResponse') throw new Error('expected rpcResponse')
    expect(body.value.requestId).toBe('automation-run-request')
    expect(fromBinary(AutomationJobRunResponseSchema, body.value.payload)).toMatchObject({
      status: 'succeeded',
      exitCode: 0,
      stdout: 'done'
    })
  })

  it('returns a bounded RPC error when execution setup throws', async () => {
    const sent: Envelope[] = []

    await handleWorkerRPCRequest(
      async envelope => {
        sent.push(envelope)
      },
      create(RPCRequestSchema, {
        requestId: 'automation-run-failed',
        deadlineUnixMs: BigInt(Date.now() + 5_000),
        method: 'automation_job.run',
        payload: toBinary(
          AutomationJobRunRequestSchema,
          create(AutomationJobRunRequestSchema, {
            automationJobRunId: '1000',
            automationJobId: '1001'
          })
        )
      }),
      {
        runAutomationJob: async () => {
          throw new Error('WorkerEnv RPC unavailable')
        }
      }
    )

    const body = sent[0]!.body
    if (body.case !== 'rpcError') throw new Error('expected rpcError')
    expect(body.value).toMatchObject({
      requestId: 'automation-run-failed',
      code: 'worker_rpc_failed',
      message: 'WorkerEnv RPC unavailable'
    })
  })
  it('rejects an expired request without decoding or starting its handler', async () => {
    const sent: Envelope[] = []
    let started = false
    await handleWorkerRPCRequest(
      async envelope => {
        sent.push(envelope)
      },
      create(RPCRequestSchema, {
        requestId: 'expired',
        method: 'automation_job.run',
        deadlineUnixMs: BigInt(Date.now() - 1),
        payload: new Uint8Array([255])
      }),
      {
        runAutomationJob: async () => {
          started = true
          return {}
        }
      }
    )
    expect(started).toBe(false)
    expect(sent[0]!.body).toMatchObject({
      case: 'rpcError',
      value: { code: 'worker_rpc_deadline_exceeded', retryable: true }
    })
  })

  it('waits for deadline cancellation cleanup before replying', async () => {
    const sent: Envelope[] = []
    let cleaned = false
    await handleWorkerRPCRequest(
      async envelope => {
        expect(cleaned).toBe(true)
        sent.push(envelope)
      },
      create(RPCRequestSchema, {
        requestId: 'held',
        method: 'automation_job.run',
        deadlineUnixMs: BigInt(Date.now() + 50),
        payload: toBinary(AutomationJobRunRequestSchema, create(AutomationJobRunRequestSchema, {}))
      }),
      {
        runAutomationJob: async (_request, { signal }) => {
          await new Promise<void>(resolve => signal.addEventListener('abort', () => resolve(), { once: true }))
          await Bun.sleep(10)
          cleaned = true
          signal.throwIfAborted()
          return {}
        }
      }
    )
    expect(sent[0]!.body).toMatchObject({
      case: 'rpcError',
      value: { code: 'worker_rpc_deadline_exceeded', retryable: false }
    })
  })

  it('rejects a late result even when synchronous work delays the deadline timer', async () => {
    const sent: Envelope[] = []
    const deadlineUnixMs = Date.now() + 100
    let started = false
    await handleWorkerRPCRequest(
      async envelope => {
        sent.push(envelope)
      },
      create(RPCRequestSchema, {
        requestId: 'blocked-timer',
        method: 'automation_job.run',
        deadlineUnixMs: BigInt(deadlineUnixMs),
        payload: toBinary(AutomationJobRunRequestSchema, create(AutomationJobRunRequestSchema, {}))
      }),
      {
        runAutomationJob: async () => {
          started = true
          while (Date.now() <= deadlineUnixMs) {
            // Keep the timer queued until the handler returns its late result.
          }
          return { status: 'succeeded', exitCode: 0 }
        }
      }
    )
    expect(started).toBe(true)
    expect(sent).toHaveLength(1)
    expect(sent[0]!.body).toMatchObject({
      case: 'rpcError',
      value: { code: 'worker_rpc_deadline_exceeded', retryable: false }
    })
  })
})
