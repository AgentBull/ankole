import { create, fromBinary, toBinary } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import {
  AutomationJobRunRequestSchema,
  AutomationJobRunResponseSchema,
  RuntimeSkillSummarySchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import {
  decodeEnvelope,
  DurabilityClass,
  encodeEnvelope,
  Lane,
  RPCRequestSchema,
  type Envelope
} from '../src/fabric/envelope_proto'
import { runtimeFabricSealEnvelope } from '@ankole/kernel'
import { handleWorkerRPCRequest, rpcMethods } from '../src/lanes/rpc_lane'

describe('automation job worker RPC', () => {
  it('decodes the typed request and returns the typed run result on the same request id', async () => {
    const sent: Envelope[] = []
    const runRequest = create(AutomationJobRunRequestSchema, {
      automationJobRunId: '1000',
      automationJobId: '1001',
      attemptId: '019fb2b4-1fd1-7d30-8b3d-c5e2250f6b9c',
      agentUid: 'agent-1',
      directoryPath: '/agents/agent-1/automation/test',
      label: 'Test consumer',
      eventJson: new TextEncoder().encode('{}'),
      timeoutMs: 600_000,
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
        method: rpcMethods.automationJobRun,
        payload: toBinary(AutomationJobRunRequestSchema, runRequest)
      }),
      {
        runAutomationJob: async request => {
          expect(request).toMatchObject({
            automationJobRunId: '1000',
            automationJobId: '1001',
            agentUid: 'agent-1',
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
    // The kernel seals the reply at send time; assert the wire header shape.
    expect(decodeEnvelope(runtimeFabricSealEnvelope(encodeEnvelope(sent[0]!)))).toMatchObject({
      correlationId: 'automation-run-request',
      lane: Lane.RPC,
      durability: DurabilityClass.CONTROL_EPHEMERAL
    })

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
        method: rpcMethods.automationJobRun,
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
})
