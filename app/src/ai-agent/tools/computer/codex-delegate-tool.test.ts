import { afterAll, beforeAll, describe, expect, it } from 'bun:test'
import { inArray } from 'drizzle-orm'
import type { Computer } from '@agentbull/bullx-computer'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { Principals } = await import('@/common/db-schema')
const { createAgent } = await import('@/principals/agents/service')
const { setRuntimeCredential } = await import('@/runtime-credentials/service')
const { createCodexDelegateTool } = await import('./codex-delegate-tool')
const { createComputerTools } = await import('.')
const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const agentUid = `codex_tool_${suffix}`

beforeAll(async () => {
  await createAgent({ uid: agentUid })
  await setRuntimeCredential({
    consumerKind: 'skill',
    consumerName: 'codex',
    credentialName: 'auth_json',
    scope: { kind: 'agent', agentUid },
    payload: `{"refresh_token":"secret-${suffix}"}`,
    payloadMediaType: 'application/json'
  })
})

afterAll(async () => {
  await DB.delete(Principals).where(inArray(Principals.uid, [agentUid]))
})

describe('codex_delegate tool', () => {
  it('materializes Codex auth and runs codex with CODEX_HOME', async () => {
    const writes: Array<{ path: string; content: string; mode?: number }[]> = []
    const commands: unknown[] = []
    const computer = {
      async writeFiles(files: Array<{ path: string; content: string; mode?: number }>) {
        writes.push(files)
      },
      async runCommand(params: unknown) {
        commands.push(params)
        return {
          exitCode: 0,
          async output() {
            return '{"msg":"done"}\n'
          }
        }
      },
      async readFileToBuffer() {
        return Buffer.from('Codex finished')
      }
    } as unknown as Computer

    const tool = createCodexDelegateTool({
      agentUid,
      executionScopeId: 'test-scope',
      backgroundIds: new Set(),
      getComputer: async () => computer
    })
    const result = await tool.execute('tc_codex', {
      prompt: 'Change the docs',
      workdir: '/workspace/user-files/repo',
      timeoutSeconds: 12
    })

    expect(result.details?.status).toBe('completed')
    expect(result.details?.exitCode).toBe(0)
    expect(writes[0]).toEqual([
      {
        path: 'temp/.codex/auth.json',
        content: `{"refresh_token":"secret-${suffix}"}`,
        mode: 0o600
      }
    ])
    expect(writes[1]?.[0]).toMatchObject({ path: expect.stringContaining('temp/codex-runs/') })
    expect(commands).toHaveLength(1)
    expect(commands[0]).toMatchObject({
      cmd: 'bash',
      cwd: '/workspace',
      env: { CODEX_HOME: '/workspace/temp/.codex' },
      timeoutMs: 12000
    })
    const args = (commands[0] as { args: string[] }).args
    expect(args[1]).toContain("codex' 'exec'")
    expect(args[1]).toContain('--dangerously-bypass-approvals-and-sandbox')
    expect(args[1]).toContain("--cd' '/workspace/user-files/repo'")
    expect(result.details?.lastMessage).toBe('Codex finished')
  })

  it('registers detached Codex runs with process-compatible session ids', async () => {
    const backgroundIds = new Set<string>()
    const computer = {
      async writeFiles() {},
      async runCommand() {
        return { cmdId: 'cmd_codex_1' }
      }
    } as unknown as Computer
    const tool = createCodexDelegateTool({
      agentUid,
      executionScopeId: 'test-scope',
      backgroundIds,
      getComputer: async () => computer
    })
    const result = await tool.execute('tc_codex_bg', { prompt: 'Work in background', wait: false })

    expect(result.details?.sessionId).toBe('cmd_codex_1')
    expect(backgroundIds.has('cmd_codex_1')).toBe(true)
  })

  it('exposes codex_delegate in the computer tool set', () => {
    const tools = createComputerTools(
      { agentUid: 'agent_123' },
      {
        resolveWorker: async () => ({
          agentUid: 'agent_123',
          executionScopeId: 'test-scope',
          worker: { workerId: 'dev', instanceId: 'i0', baseUrl: 'https://worker.local' },
          binding: { kind: 'implicit', reason: 'test' },
          tls: { caCert: 'CA', cert: 'CERT', key: 'KEY' }
        })
      }
    )

    expect(tools.map(tool => tool.name)).toContain('codex_delegate')
  })
})
