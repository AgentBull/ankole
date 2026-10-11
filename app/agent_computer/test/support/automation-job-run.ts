import { create } from '@bufbuild/protobuf'
import { mkdirSync, mkdtempSync, readdirSync, realpathSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect } from 'bun:test'
import { mkdirAgentSync } from '../../src/common/agent-user'
import { AutomationJobRunRequestSchema } from '../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { jsonBytes, jsonObjectFromBytes } from '../../src/fabric/envelope_proto'
import { LARK_TENANT_TOKEN_ENV } from '../../src/core/execution/lark-credential'
import { WORKER_SHARE_ROOT } from '../../src/core/agent-home-paths'
import type { RPCRequester } from '../../src/lanes/rpc_lane'
import type { WorkerConfig } from '../../src/worker/config'
import { FakeDrive } from './fake-drive'

const attemptId = '019fb2b4-1fd1-7d30-8b3d-c5e2250f6b9c'

export type RunFixture = {
  root: string
  drive: FakeDrive
  drivePrefix: string
  runDirectory: string
  config: WorkerConfig
  sdkPath: string
}

/** The script lives in the Agent's drive; each run copies it to a fresh run directory. */
export function runFixture(source: string): RunFixture {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'ankole-automation-run-')))
  mkdirAgentSync(root, 0o700)
  const agentHomeRoot = `${root}/workspace`
  const agentHome = agentHomeRoot
  mkdirSync(agentHome, { recursive: true })
  const drive = new FakeDrive(agentHome)
  const drivePrefix = 'automation/integration'
  drive.put(`${drivePrefix}/main.ts`, source)

  return {
    root,
    sdkPath: join(import.meta.dir, '../../src/automation-jobs/sdk.ts'),
    drive,
    drivePrefix,
    runDirectory: join(agentHome, '.ankole', 'automation-runs', attemptId),
    config: {
      endpoint: 'ws://127.0.0.1:4000/runtime-fabric/worker',
      workerAuthKey: 'test-secret',
      workerID: 'agent-1',
      incarnationID: 'incarnation-1',
      agentHomeRoot,
      builtinSkillsRoot: join(import.meta.dir, '../../../library'),
      browser: { daemonEntry: '/bin/true', runnerPath: '/bin/true', localChromiumExecutable: '/bin/true' },
      maxConcurrentSlots: 4
    }
  }
}

export function putInstalledSkill(fixture: RunFixture, fixtureServer: string): void {
  fixture.drive.put('skills/fixture-data/SKILL.md', '---\nname: fixture-data\ndescription: Echo a test value.\n---\n')
  fixture.drive.put(
    'skills/fixture-data/agents/openai.yaml',
    `dependencies:\n  tools:\n    - type: mcp\n      value: fixture-data\n      transport: stdio\n      command: bun ${fixtureServer}\n`
  )
}

export function request(fixture: RunFixture, data: Record<string, unknown>) {
  return create(AutomationJobRunRequestSchema, {
    automationJobRunId: '1000',
    automationJobId: '1001',
    attemptId,
    drivePrefix: fixture.drivePrefix,
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

export function rpcStub(
  fixture: RunFixture,
  emitted: unknown[],
  opts: { larkToken?: string; bindingName?: string } = {}
): RPCRequester {
  const driveRPC = fixture.drive.rpc as unknown as (...args: unknown[]) => Promise<unknown>
  const requester = async (method: string, payload: unknown, ...rest: unknown[]) => {
    if (method.startsWith('files.')) return driveRPC(method, payload, ...rest)
    if (method === 'worker_env.resolve') {
      expect(payload).toMatchObject({ bindingName: opts.bindingName ?? '' })
      const operatorVars = { AUTOMATION_TEST_VALUE: 'available' }
      const bindingVars = opts.larkToken
        ? {
            LARKSUITE_CLI_APP_ID: 'cli_worker',
            LARKSUITE_CLI_BRAND: 'feishu',
            [LARK_TENANT_TOKEN_ENV]: opts.larkToken
          }
        : {}
      return { vars: { ...operatorVars, ...bindingVars }, operatorVars, bindingVars }
    }
    if (method === 'automation_job.emit') {
      const request = payload as { payloadJson: Uint8Array }
      emitted.push(jsonObjectFromBytes(request.payloadJson, 'payload_json'))
      return {}
    }
    throw new Error(`unexpected RPC method ${method}`)
  }

  return requester as unknown as RPCRequester
}

export function failingRPC(rpc: RPCRequester, failingMethod: string, message: string): RPCRequester {
  const call = rpc as unknown as (method: string, ...rest: unknown[]) => Promise<unknown>
  const requester = async (method: string, ...rest: unknown[]) => {
    if (method === failingMethod) throw new Error(message)
    return call(method, ...rest)
  }

  return requester as unknown as RPCRequester
}

export function mcporterConfigNames(): string[] {
  return readdirSync(WORKER_SHARE_ROOT)
    .filter(name => name.startsWith('ankole-mcporter-'))
    .sort()
}
