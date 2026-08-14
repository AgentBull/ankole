import { create } from '@bufbuild/protobuf'
import { afterEach, describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  AutomationJobRunRequestSchema,
  RuntimeSkillSummarySchema
} from '../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { jsonBytes, jsonObjectFromBytes } from '../../src/fabric/envelope_proto'
import { runAutomationJob } from '../../src/automation-jobs/run'
import { LARK_TENANT_TOKEN_ENV } from '../../src/core/turns/lark-credential'
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

  it('calls an enabled Skill MCP dependency through the generated MCPorter config', async () => {
    const fixture = runFixture(`
const proc = Bun.spawn(
  ["mcporter", "call", "fixture-data.stdio_echo", "--json", "-", "--output", "json", "--timeout", "10000"],
  { stdin: "pipe", stdout: "pipe", stderr: "pipe" }
)
proc.stdin.write(JSON.stringify({ text: "复杂参数 with \\"quotes\\"" }))
proc.stdin.end()
const [exitCode, stdout, stderr] = await Promise.all([
  proc.exited,
  new Response(proc.stdout).text(),
  new Response(proc.stderr).text()
])
if (exitCode !== 0) throw new Error(stderr || \`mcporter exited with code \${exitCode}\`)
console.log(JSON.stringify({ config: process.env.MCPORTER_CONFIG, result: JSON.parse(stdout) }))
`)
    root = fixture.root
    const fixtureServer = '/repo/app/agent_computer/test/fixtures/mcp-stdio-server.ts'
    writeInstalledSkill(fixture, fixtureServer)

    const result = await runAutomationJob(
      create(AutomationJobRunRequestSchema, {
        ...request(fixture.directory, {}),
        skills: [
          create(RuntimeSkillSummarySchema, {
            skillName: 'fixture-data',
            sourceKind: 'installed',
            relativePath: 'fixture-data'
          })
        ]
      }),
      {
        config: fixture.config,
        rpc: rpcStub([])
      }
    )

    expect(result.status).toBe('succeeded')
    const output = JSON.parse(result.stdout)
    expect(output.config).toStartWith('/var/share/ankole-mcporter-')
    expect(output.result).toMatchObject({
      content: [{ type: 'text', text: 'stdio response' }]
    })
    expect(existsSync(output.config)).toBe(false)
  })

  it('projects a refreshed Lark file instead of a raw token across bubblewrap', async () => {
    const fixture = runFixture(`
const proc = Bun.spawn(["lark-cli", "--version"], { stdout: "pipe", stderr: "pipe" })
const [exitCode, stdout, stderr] = await Promise.all([
  proc.exited,
  new Response(proc.stdout).text(),
  new Response(proc.stderr).text()
])
console.log(JSON.stringify({
  appID: process.env.LARKSUITE_CLI_APP_ID,
  rawToken: process.env.LARKSUITE_CLI_TENANT_ACCESS_TOKEN ?? null,
  tokenFile: process.env.ANKOLE_RUNTIME_LARK_TENANT_ACCESS_TOKEN_FILE,
  exitCode,
  stdout,
  stderr
}))
`)
    root = fixture.root

    const result = await runAutomationJob(request(fixture.directory, {}), {
      config: fixture.config,
      rpc: rpcStub([], { larkToken: 'tenant-token' })
    })

    expect(result.status).toBe('succeeded')
    const output = JSON.parse(result.stdout)
    expect(output).toMatchObject({
      appID: 'cli_worker',
      rawToken: null,
      exitCode: 0,
      stdout: 'lark-cli version 1.0.86\n',
      stderr: ''
    })
    expect(output.tokenFile).toStartWith(`${fixture.config.agentsRoot}/agent-1/runtime-materials/credentials/`)
    expect(existsSync(output.tokenFile)).toBe(false)
  })

  it('treats a script exception as one terminal script result', async () => {
    const fixture = runFixture(`
console.log(JSON.stringify({ config: process.env.MCPORTER_CONFIG, marker: "before failure" }))
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
    expect(existsSync(JSON.parse(result.stdout).config)).toBe(false)
  })

  it('kills a hung script at the supplied resource deadline', async () => {
    const fixture = runFixture('await new Promise(() => {})\n')
    root = fixture.root
    const configsBefore = mcporterConfigNames()

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
    expect(mcporterConfigNames()).toEqual(configsBefore)
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

function writeInstalledSkill(fixture: ReturnType<typeof runFixture>, fixtureServer: string): void {
  const agentsRoot = join(fixture.config.agentsRoot, 'agent-1', 'installed-skills', 'fixture-data', 'agents')
  mkdirSync(agentsRoot, { recursive: true })
  writeFileSync(
    join(agentsRoot, 'openai.yaml'),
    `dependencies:\n  tools:\n    - type: mcp\n      value: fixture-data\n      transport: stdio\n      command: bun ${fixtureServer}\n`
  )
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

function rpcStub(emitted: unknown[], opts: { larkToken?: string } = {}): RPCRequester {
  const requester = async (method: string, payload: unknown) => {
    if (method === rpcMethods.workerEnvResolve) {
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
    if (method === rpcMethods.automationJobEmit) {
      const request = payload as { payloadJson: Uint8Array }
      emitted.push(jsonObjectFromBytes(request.payloadJson, 'payload_json'))
      return {}
    }
    throw new Error(`unexpected RPC method ${method}`)
  }

  return requester as unknown as RPCRequester
}

function mcporterConfigNames(): string[] {
  return readdirSync('/var/share')
    .filter(name => name.startsWith('ankole-mcporter-'))
    .sort()
}
