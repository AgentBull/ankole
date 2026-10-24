import { create } from '@bufbuild/protobuf'
import { afterEach, describe, expect, it } from 'bun:test'
import { existsSync, rmSync } from 'node:fs'
import { AutomationJobRunRequestSchema } from '../../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { runAutomationJob } from '../../../src/automation-jobs/run'
import { runFixture, request, rpcStub } from '../../support/automation-job-run'

describe('Automation Job in the Worker image', () => {
  let root: string | undefined
  afterEach(() => {
    if (root) rmSync(root, { recursive: true, force: true })
    root = undefined
  })
  it('projects a refreshed Lark file instead of a raw token into the script', async () => {
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

    const result = await runAutomationJob(
      create(AutomationJobRunRequestSchema, {
        ...request(fixture, {}),
        bindingName: 'lark-secondary'
      }),
      {
        config: fixture.config,
        rpc: rpcStub(fixture, [], { larkToken: 'tenant-token', bindingName: 'lark-secondary' })
      }
    )

    expect(result.status).toBe('succeeded')
    const output = JSON.parse(result.stdout)
    expect(output).toMatchObject({
      appID: 'cli_worker',
      rawToken: null,
      exitCode: 0,
      stdout: 'lark-cli version 1.0.98\n',
      stderr: ''
    })
    expect(output.tokenFile).toStartWith(`${fixture.config.agentHomeRoot}/runtime-materials/credentials/`)
    expect(existsSync(output.tokenFile)).toBe(false)
  })
})
