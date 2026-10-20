import { create } from '@bufbuild/protobuf'
import { afterEach, describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  AutomationJobRunRequestSchema,
  RuntimeSkillSummarySchema
} from '../../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { removeAbandonedRunDirectories, runAutomationJob } from '../../../src/automation-jobs/run'
import { WORKER_SHARE_ROOT } from '../../../src/core/agent-home-paths'
import type { RPCRequester } from '../../../src/lanes/rpc_lane'
import {
  runFixture,
  request,
  rpcStub,
  putInstalledSkill,
  failingRPC,
  mcporterConfigNames
} from '../../support/automation-job-run'

describe('automation job run as an Agent process', () => {
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

    const result = await runAutomationJob(request(fixture, { value: 42 }), {
      config: fixture.config,
      sdkPath: fixture.sdkPath,
      rpc: rpcStub(fixture, emitted)
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
    expect(existsSync(fixture.runDirectory)).toBe(false)
  })

  it('fails the run when the drive folder has no main.ts', async () => {
    const fixture = runFixture('console.log("never runs")\n')
    root = fixture.root
    fixture.drive.files.delete(`${fixture.drivePrefix}/main.ts`)
    fixture.drive.put(`${fixture.drivePrefix}/README.md`, 'notes')

    const result = await runAutomationJob(request(fixture, {}), {
      config: fixture.config,
      sdkPath: fixture.sdkPath,
      rpc: rpcStub(fixture, [])
    })

    expect(result.status).toBe('failed')
    expect(result.error).toContain('main.ts is missing from automation/integration in the drive')
    expect(existsSync(fixture.runDirectory)).toBe(false)
  })

  it('throws on a drive failure during the copy, so the control plane retries the attempt', async () => {
    const fixture = runFixture('console.log("never runs")\n')
    root = fixture.root
    fixture.drive.put(`${fixture.drivePrefix}/lib/helper.ts`, 'export const value = 1\n')
    const rpc = failingRPC(rpcStub(fixture, []), 'files.get', 'object store unavailable')

    await expect(
      runAutomationJob(request(fixture, {}), { config: fixture.config, sdkPath: fixture.sdkPath, rpc })
    ).rejects.toThrow('object store unavailable')
    expect(existsSync(fixture.runDirectory)).toBe(false)
  })

  it('throws when the WorkerEnv RPC fails, so the control plane retries the attempt', async () => {
    const fixture = runFixture('console.log("never runs")\n')
    root = fixture.root
    const rpc = failingRPC(rpcStub(fixture, []), 'worker_env.resolve', 'control plane unavailable')

    await expect(
      runAutomationJob(request(fixture, {}), { config: fixture.config, sdkPath: fixture.sdkPath, rpc })
    ).rejects.toThrow('control plane unavailable')
    expect(existsSync(fixture.runDirectory)).toBe(false)
  })

  it('throws before the script runs when installed Skills cannot be downloaded', async () => {
    const fixture = runFixture('await emitEvent({ ran: true })\n')
    root = fixture.root
    putInstalledSkill(fixture, join(import.meta.dir, '../../fixtures/mcp-stdio-server.ts'))
    const emitted: unknown[] = []
    const baseRPC = rpcStub(fixture, emitted)
    const rpc = (async (method, payload, frame, options) => {
      if (method === 'files.get' && (payload as { path: string }).path.startsWith('skills/')) {
        throw new Error('Skill download unavailable')
      }
      return baseRPC(method, payload, frame, options)
    }) as RPCRequester

    await expect(
      runAutomationJob(request(fixture, {}), { config: fixture.config, sdkPath: fixture.sdkPath, rpc })
    ).rejects.toThrow('Skill download unavailable')
    expect(emitted).toEqual([])
    expect(existsSync(fixture.runDirectory)).toBe(false)
  })

  it('removes the run directories that a former Worker process left at startup', () => {
    const fixture = runFixture('console.log("never runs")\n')
    root = fixture.root
    mkdirSync(fixture.runDirectory, { recursive: true })
    writeFileSync(join(fixture.runDirectory, 'main.ts'), 'console.log("abandoned")\n')

    removeAbandonedRunDirectories({ agentHomeRoot: fixture.config.agentHomeRoot })

    expect(existsSync(join(fixture.runDirectory, '..'))).toBe(false)
  })

  it('downloads installed Skills into an empty cache and calls the MCP dependency through MCPorter', async () => {
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
    const fixtureServer = join(import.meta.dir, '../../fixtures/mcp-stdio-server.ts')
    putInstalledSkill(fixture, fixtureServer)
    expect(existsSync(join(fixture.config.agentHomeRoot, 'installed-skills'))).toBe(false)

    const result = await runAutomationJob(
      create(AutomationJobRunRequestSchema, {
        ...request(fixture, {}),
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
        sdkPath: fixture.sdkPath,
        rpc: rpcStub(fixture, [])
      }
    )

    expect(result.status, result.stderr || result.error).toBe('succeeded')
    const output = JSON.parse(result.stdout)
    expect(output.config).toStartWith(`${WORKER_SHARE_ROOT}/ankole-mcporter-`)
    expect(output.result).toMatchObject({
      content: [{ type: 'text', text: 'stdio response' }]
    })
    expect(existsSync(output.config)).toBe(false)
  })

  it('treats a script exception as one terminal script result', async () => {
    const fixture = runFixture(`
console.log(JSON.stringify({ config: process.env.MCPORTER_CONFIG, marker: "before failure" }))
throw new Error("source schema changed")
`)
    root = fixture.root

    const result = await runAutomationJob(request(fixture, {}), {
      config: fixture.config,
      sdkPath: fixture.sdkPath,
      rpc: rpcStub(fixture, [])
    })

    expect(result.status).toBe('failed')
    expect(result.exitCode).not.toBe(0)
    expect(result.error).toContain('source schema changed')
    expect(result.stdout).toContain('before failure')
    expect(result.stderr).toContain('source schema changed')
    expect(existsSync(JSON.parse(result.stdout).config)).toBe(false)
  })

  for (const exitCode of [0, 17]) {
    for (const inheritedOutput of [false, true]) {
      it(`cleans descendants after leader exit ${exitCode}, inherited output ${inheritedOutput}`, async () => {
        const fixture = runFixture(`
const child = Bun.spawn(['/bin/sh', '-c', 'trap "" TERM; sleep 30'], { stdin: 'ignore', stdout: ${inheritedOutput ? '1' : "'ignore'"}, stderr: ${inheritedOutput ? '2' : "'ignore'"} })
child.unref()
console.log(child.pid)
process.exit(${exitCode})
`)
        root = fixture.root
        const started = performance.now()
        const result = await runAutomationJob(request(fixture, {}), {
          config: fixture.config,
          sdkPath: fixture.sdkPath,
          rpc: rpcStub(fixture, [])
        })
        expect(result.exitCode).toBe(exitCode)
        expect(performance.now() - started).toBeLessThan(2_000)
        const childPID = Number(result.stdout.trim())
        expect(childPID).toBeGreaterThan(0)
        for (let i = 0; i < 100 && alive(childPID); i++) await Bun.sleep(10)
        expect(alive(childPID)).toBe(false)
        expect(existsSync(fixture.runDirectory)).toBe(false)
      })
    }
  }

  it('cancels the owned process group before removing its execution materials', async () => {
    const fixture = runFixture('')
    root = fixture.root
    const pidFile = join(fixture.root, 'pid')
    fixture.drive.put(
      `${fixture.drivePrefix}/main.ts`,
      `await Bun.write(${JSON.stringify(pidFile)}, String(process.pid)); await new Promise(() => {})`
    )
    const controller = new AbortController()
    const pending = runAutomationJob(request(fixture, {}), {
      config: fixture.config,
      sdkPath: fixture.sdkPath,
      rpc: rpcStub(fixture, []),
      signal: controller.signal
    })
    for (let i = 0; i < 200 && !existsSync(pidFile); i++) await Bun.sleep(10)
    expect(existsSync(pidFile)).toBe(true)
    const pid = Number(readFileSync(pidFile, 'utf8'))
    controller.abort(new DOMException('caller cancelled', 'AbortError'))
    expect((await pending).status).toBe('failed')
    expect(alive(pid)).toBe(false)
    expect(existsSync(fixture.runDirectory)).toBe(false)
  })

  it('spends one budget on preparation and never starts after preparation expires', async () => {
    const fixture = runFixture('throw new Error("must never execute")')
    root = fixture.root
    const base = rpcStub(fixture, [])
    let preparationSignal: AbortSignal | undefined
    const rpc: RPCRequester = (method, payload, frame, options) => {
      if (method !== 'files.list') return base(method, payload, frame, options)
      preparationSignal = options?.signal
      expect(options?.timeoutMs).toBeLessThanOrEqual(50)
      return new Promise((_resolve, reject) =>
        preparationSignal!.addEventListener('abort', () => reject(preparationSignal!.reason), { once: true })
      )
    }
    const pending = runAutomationJob(
      { ...request(fixture, {}), timeoutMs: 50 },
      { config: fixture.config, sdkPath: fixture.sdkPath, rpc }
    )
    await expect(pending).rejects.toMatchObject({ code: 'automation_preparation_failed' })
    expect(preparationSignal?.aborted).toBe(true)
    expect(existsSync(fixture.runDirectory)).toBe(false)
  })

  it('kills a hung script at the supplied resource deadline', async () => {
    const fixture = runFixture('await new Promise(() => {})\n')
    root = fixture.root
    const configsBefore = mcporterConfigNames()

    const result = await runAutomationJob(
      {
        ...request(fixture, {}),
        timeoutMs: 50
      },
      {
        config: fixture.config,
        sdkPath: fixture.sdkPath,
        rpc: rpcStub(fixture, [])
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

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}
