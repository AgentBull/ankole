import { create } from '@bufbuild/protobuf'
import { afterEach, describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { AutomationJobRunRequestSchema } from '../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { jsonBytes, jsonObjectFromBytes } from '../../src/fabric/envelope_proto'
import { runAutomationJob } from '../../src/automation-jobs/run'
import { rpcMethods, type RPCRequester } from '../../src/lanes/rpc_lane'
import type { WorkerConfig } from '../../src/worker/config'

describe('automation job run across the real bubblewrap boundary', () => {
  let root: string | undefined

  afterEach(() => {
    if (root) rmSync(root, { recursive: true, force: true })
    root = undefined
  })

  it('provides context, current Agent WorkerEnv, and a durable emit bridge', async () => {
    const fixture = runFixture(`
const ctx = context()
console.log(JSON.stringify({ event: ctx.event, job: ctx.job, worker: process.env.AUTOMATION_TEST_VALUE }))
await emitEvent({ observed: ctx.event.data.value, job_id: ctx.job.id })
`)
    root = fixture.root
    const emitted: unknown[] = []

    const result = await runAutomationJob(request(fixture.directory, { value: 42 }), {
      config: fixture.config,
      rpc: rpcStub(emitted)
    })

    expect(result).toMatchObject({
      status: 'succeeded',
      exitCode: 0,
      stderr: '',
      stdoutTruncated: false,
      stderrTruncated: false
    })
    expect(JSON.parse(result.stdout)).toEqual({
      event: {
        specversion: '1.0',
        id: 'trigger-1',
        source: 'test://automation',
        type: 'test.triggered',
        data: { value: 42 }
      },
      job: { id: 1001, label: 'Integration consumer' },
      worker: 'available'
    })
    expect(emitted).toEqual([{ observed: 42, job_id: 1001 }])
  })

  it('treats a script exception as one terminal script result', async () => {
    const fixture = runFixture(`
console.log("before failure")
throw new Error("source schema changed")
`)
    root = fixture.root

    const result = await runAutomationJob(request(fixture.directory, {}), {
      config: fixture.config,
      rpc: rpcStub([])
    })

    expect(result.status).toBe('failed')
    expect(result.exitCode).not.toBe(0)
    expect(result.error).toContain('source schema changed')
    expect(result.stdout).toContain('before failure')
    expect(result.stderr).toContain('source schema changed')
  })

  it('kills a hung script at the supplied resource deadline', async () => {
    const fixture = runFixture('await new Promise(() => {})\n')
    root = fixture.root

    const result = await runAutomationJob(
      {
        ...request(fixture.directory, {}),
        timeoutMs: 50
      },
      {
        config: fixture.config,
        rpc: rpcStub([])
      }
    )

    expect(result).toMatchObject({
      status: 'failed',
      exitCode: 124,
      error: 'automation job timed out after 50 ms'
    })
  })
})

function runFixture(source: string): {
  root: string
  directory: string
  config: WorkerConfig
} {
  const root = mkdtempSync('/agents/ankole-automation-run-')
  const agentsRoot = `${root}/agents`
  const agentHome = `${agentsRoot}/agent-1`
  const directory = `${agentHome}/automation/integration`
  mkdirSync(directory, { recursive: true })
  writeFileSync(`${directory}/main.ts`, source)

  return {
    root,
    directory,
    config: {
      endpoint: 'tcp://127.0.0.1:6010',
      workerAuthKey: 'test-secret',
      workerID: 'worker-1',
      incarnationID: 'incarnation-1',
      agentsRoot,
      builtinSkillsRoot: '/repo/app/library',
      maxConcurrentTurns: 4
    }
  }
}

function request(directoryPath: string, data: Record<string, unknown>) {
  return create(AutomationJobRunRequestSchema, {
    automationJobRunId: '1000',
    automationJobId: '1001',
    attemptId: '019fb2b4-1fd1-7d30-8b3d-c5e2250f6b9c',
    agentUid: 'agent-1',
    directoryPath,
    label: 'Integration consumer',
    eventJson: jsonBytes({
      specversion: '1.0',
      id: 'trigger-1',
      source: 'test://automation',
      type: 'test.triggered',
      data
    }),
    timeoutMs: 5_000
  })
}

function rpcStub(emitted: unknown[]): RPCRequester {
  const requester = async (method: string, payload: unknown) => {
    if (method === rpcMethods.workerEnvResolve) {
      return { vars: { AUTOMATION_TEST_VALUE: 'available' } }
    }
    if (method === rpcMethods.automationJobEmit) {
      const request = payload as { payloadJson: Uint8Array }
      emitted.push(jsonObjectFromBytes(request.payloadJson, 'payload_json'))
      return {}
    }
    throw new Error(`unexpected RPC method ${method}`)
  }

  return requester as unknown as RPCRequester
}
