import { afterAll, beforeAll, describe, expect, it } from 'bun:test'
import { inArray } from 'drizzle-orm'
import type { Computer } from '@agentbull/bullx-computer'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { Principals } = await import('@/common/db-schema')
const { createAgent } = await import('@/principals/agents/service')
const { setRuntimeCredential } = await import('@/runtime-credentials/service')
const { setAgentSkillEnabled, syncBuiltinLibraryFromAppDirectory } = await import('@/ai-agent/library/service')
const { createCodexDelegateTool } = await import('./codex-delegate-tool')
const { createComputerTools } = await import('.')
const { materializeComputerRuntimeCredentials } = await import('./runtime-credential-materialization')
const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const agentUid = `codex_tool_${suffix}`

beforeAll(async () => {
  await syncBuiltinLibraryFromAppDirectory({ force: true })
  await createAgent({ uid: agentUid })
  await setAgentSkillEnabled({
    agentUid,
    skillName: 'github-auth',
    enabled: true,
    reason: 'computer materialization test'
  })
  await setRuntimeCredential({
    consumerKind: 'skill',
    consumerName: 'codex',
    credentialName: 'auth_json',
    scope: { kind: 'agent', agentUid },
    payload: `{"refresh_token":"secret-${suffix}"}`,
    payloadMediaType: 'application/json'
  })
  await setRuntimeCredential({
    consumerKind: 'skill',
    consumerName: 'codex',
    credentialName: 'config_toml',
    scope: { kind: 'agent', agentUid },
    payload: `model = "gpt-test-${suffix}"\n`,
    payloadMediaType: 'text/x-toml'
  })
  await setRuntimeCredential({
    consumerKind: 'skill',
    consumerName: 'github',
    credentialName: 'env',
    scope: { kind: 'agent', agentUid },
    payload: `GITHUB_TOKEN=github-secret-${suffix}\n`,
    payloadMediaType: 'text/plain'
  })
})

afterAll(async () => {
  await DB.delete(Principals).where(inArray(Principals.uid, [agentUid]))
})

describe('codex_delegate tool', () => {
  // End-to-end of the foreground path against a fake computer: auth + config land at their fixed
  // 0o600 paths, the prompt is written under temp/codex-runs, and codex runs with the bypass flag,
  // the right --cd, and CODEX_HOME pointing at the materialized credentials.
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
    expect(writes[1]).toEqual([
      {
        path: 'temp/.codex/config.toml',
        content: `model = "gpt-test-${suffix}"\n`,
        mode: 0o600
      }
    ])
    expect(writes[2]?.[0]).toMatchObject({ path: expect.stringContaining('temp/codex-runs/') })
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
    expect(result.details?.configMaterialized).toBe(true)
  })

  // Covers the session-level seeding helper: all three secrets resolve true, library files are
  // written, and secrets land at 0o600 while library files land at 0o644 (non-secret).
  it('materializes shared computer runtime credentials for command-oriented skills', async () => {
    const writes: Array<{ path: string; content: string; mode?: number }[]> = []
    const computer = {
      async writeFiles(files: Array<{ path: string; content: string; mode?: number }>) {
        writes.push(files)
      }
    } as unknown as Computer

    const result = await materializeComputerRuntimeCredentials({ computer, agentUid })

    expect(result).toMatchObject({ codexAuth: true, codexConfig: true, githubEnv: true })
    expect(result.libraryFiles).toBeGreaterThan(0)
    expect(writes.flat()).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          path: 'library-containers/skills/github-auth/scripts/gh-env.sh',
          mode: 0o644
        }),
        {
          path: 'temp/.codex/auth.json',
          content: `{"refresh_token":"secret-${suffix}"}`,
          mode: 0o600
        },
        {
          path: 'temp/.codex/config.toml',
          content: `model = "gpt-test-${suffix}"\n`,
          mode: 0o600
        },
        {
          path: 'temp/.bullx/github.env',
          content: `GITHUB_TOKEN=github-secret-${suffix}\n`,
          mode: 0o600
        }
      ])
    )
  })

  // Background path (wait=false): the detached command's id is surfaced as session_id and recorded
  // in backgroundIds so the process tool can later manage the run.
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
