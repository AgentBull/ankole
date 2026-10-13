import { mkdirAgentSync } from '../../../src/common/agent-user'
import { resetCodexAgentRuntimeConfig } from '../../support/codex-runtime-config'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { appendFileSync, chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { AIGatewayAPIKeyResponseSchema } from '../../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { CodexAppServerClient } from '../../../src/core/codex-runner/runtime/app-server-client'
import { codexHomeRuntimeLockPath } from '../../../src/core/codex-runner/runtime/codex-home-lock'
import type { ListMcpServerStatusResponse } from '../../../src/core/codex-runner/generated/protocol/v2/ListMcpServerStatusResponse'
import type { McpServerToolCallResponse } from '../../../src/core/codex-runner/generated/protocol/v2/McpServerToolCallResponse'
import type { ThreadStartResponse } from '../../../src/core/codex-runner/generated/protocol/v2/ThreadStartResponse'
import {
  materializeCodexConfig,
  refreshCodexAgentRuntimeCredential
} from '../../../src/core/codex-runner/runtime/agent-home-config'
import { codexAppServerSpec, codexJobThreadEnv } from '../../../src/core/codex-runner/runtime/app-server-spec'
import { renderCodexJobAgents } from '../../../src/core/codex-runner/job/runtime-files'
import { prepareCodexJobProject } from '../../../src/core/codex-runner/job/job-project'
import {
  materializeCodexJobProjectConfig,
  readCodexJobProjectConfig
} from '../../../src/core/codex-runner/job/project-config'
import { codexJobThreadConfig } from '../../../src/core/codex-runner/job/thread-config'
import {
  AgentCodexRuntimeManager,
  type AgentCodexRuntimeLease
} from '../../../src/core/codex-runner/runtime/agent-runtime-manager'
import type { CodexRuntimeConfig } from '../../../src/core/codex-runner/runtime-config'
import { errorMessage } from '../../../src/common/errors'
import { agentProcessArgv } from '../../../src/core/execution/process-group'

if (process.platform !== 'linux' || !Bun.which(process.env.ANKOLE_FLOCK_BINARY ?? 'flock')) {
  throw new Error('Managed Codex runtime tests require a Linux host with flock; run bun run test:integration:linux')
}

const previousSQLiteHome = process.env.CODEX_SQLITE_HOME
let sqliteHome: string
beforeEach(() => {
  sqliteHome = mkdtempSync(join(tmpdir(), 'ankole-codex-sqlite-'))
  mkdirAgentSync(sqliteHome, 0o700)
  process.env.CODEX_SQLITE_HOME = sqliteHome
})
afterEach(() => {
  if (previousSQLiteHome === undefined) delete process.env.CODEX_SQLITE_HOME
  else process.env.CODEX_SQLITE_HOME = previousSQLiteHome
  rmSync(sqliteHome, { recursive: true, force: true })
})

describe('Codex Worker runtime on Linux', () => {
  it('releases the Agent Codex Home lock after each real app-server exit', async () => {
    const agentHomeRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-lock-contract-'))
    mkdirAgentSync(agentHomeRoot, 0o700)
    const materialized = materializeCodexConfig({ agentHomeRoot })
    mkdirAgentSync(materialized.agentHome)
    const appServer = codexAppServerSpec(materialized)
    const manager = new AgentCodexRuntimeManager()
    let lease: AgentCodexRuntimeLease | undefined

    try {
      for (let index = 0; index < 6; index += 1) {
        lease = await manager.acquire({
          agentUID: 'agent-1',
          agentHome: materialized.agentHome,
          codexHome: materialized.codexHome,
          sqliteHome: materialized.sqliteHome,
          aiGatewayBaseURL: 'http://control.test/api/v1/ai-gateway',
          aiGatewayAPIKey: `contract-key-${index}`,
          appServer
        })
        await lease.release()
        lease = undefined

        const probe = Bun.spawn(
          agentProcessArgv([
            process.env.ANKOLE_FLOCK_BINARY ?? 'flock',
            '-n',
            '-E',
            '75',
            '-F',
            codexHomeRuntimeLockPath(materialized.sqliteHome),
            process.execPath,
            '-e',
            'process.exit(0)'
          ]),
          { stdout: 'pipe', stderr: 'pipe' }
        )
        const [exitCode, stderr] = await Promise.all([probe.exited, new Response(probe.stderr).text()])
        if (exitCode !== 0) throw new Error(`Codex Home lock stayed busy after app-server exit: ${stderr}`)
      }
    } finally {
      await lease?.release()
      rmSync(agentHomeRoot, { recursive: true, force: true })
    }
  }, 90_000)

  it('uses real Job and MCP paths from the app-server process', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-contract-'))
    mkdirAgentSync(root, 0o700)
    const jobProjectRoot = join(root, 'agent-1', 'jobs', '1000')
    const fakeCodex = join(jobProjectRoot, 'fake-codex')
    const previousCodexBinary = process.env.ANKOLE_CODEX_BINARY
    mkdirAgentSync(jobProjectRoot)
    writeFileSync(
      fakeCodex,
      `#!/bin/sh
set -eu
grep -q 'TASK_AGENTS_MARKER' ${jobProjectRoot}/AGENTS.md
grep -q '^name: pdf$' '${join(import.meta.dir, '../../../../library/skills/pdf/SKILL.md')}'
! grep -q '^model = ' ${jobProjectRoot}/.codex/config.toml
grep -q 'native-fixture' ${jobProjectRoot}/.codex/config.toml
grep -q 'broken-optional' ${jobProjectRoot}/.codex/config.toml
grep -q '^model_provider = "ankole_aigateway"$' \${CODEX_HOME}/config.toml
test -z "\${ANKOLE_AIGATEWAY_MODEL_BINDING:-}"
printf 'command path works\n' > ${jobProjectRoot}/command-probe.txt
test ! -e ./AGENTS.override.md
`
    )
    chmodSync(fakeCodex, 0o755)

    const project = prepareCodexJobProject({ jobProjectRoot })
    const renderedAgents = renderCodexJobAgents({
      jobRoot: project.root,
      soul: 'TASK_AGENTS_MARKER',
      mission: 'Verify runtime mounts.'
    })
    writeFileSync(join(jobProjectRoot, 'AGENTS.md'), renderedAgents.content)
    const runtimeConfig: CodexRuntimeConfig = {
      modelProfile: {
        model: 'gpt-5.6-sol',
        selector: 'openrouter/openai/gpt-5.6-sol',
        providerOptions: { reasoningEffort: 'xhigh' },
        supportsParallelToolCalls: true,
        inputModalities: ['text'],
        modelReasoningEffort: 'xhigh'
      },
      aiGatewayKey: create(AIGatewayAPIKeyResponseSchema, {
        apiKey: 'unused-test-key',
        tokenType: 'Bearer',
        expiresAt: BigInt(Math.floor(Date.now() / 1_000) + 3_600),
        expiresIn: 3_600n,
        scope: 'ai_gateway',
        baseUrl: 'http://control.test/api/v1/ai-gateway'
      })
    }
    const materialized = materializeCodexConfig({
      agentHomeRoot: root
    })
    resetCodexAgentRuntimeConfig(materialized.codexHome, runtimeConfig.aiGatewayKey.baseUrl)
    refreshCodexAgentRuntimeCredential(materialized.codexHome, runtimeConfig.aiGatewayKey.apiKey)
    materializeCodexJobProjectConfig({
      projectRoot: project.root,
      hostedWebSearch: false
    })
    appendOptionalMCPFixtures(project.root)
    let realClient: CodexAppServerClient | undefined

    try {
      process.env.ANKOLE_CODEX_BINARY = fakeCodex
      const appServer = codexAppServerSpec(materialized)
      const proc = Bun.spawn(agentProcessArgv(appServer.commandArgv), {
        cwd: appServer.cwd,
        env: appServer.env,
        stdin: 'ignore',
        stdout: 'pipe',
        stderr: 'pipe'
      })
      const [exitCode, stdout, stderr] = await Promise.all([
        proc.exited,
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text()
      ])

      expect(stdout).toBe('')
      if (exitCode !== 0) throw new Error(`fake Codex app-server probe exited with ${exitCode}: ${stderr}`)
      expect(readFileSync(join(jobProjectRoot, 'command-probe.txt'), 'utf8')).toBe('command path works\n')
      expect(existsSync(join(jobProjectRoot, 'AGENTS.override.md'))).toBe(false)

      if (previousCodexBinary === undefined) delete process.env.ANKOLE_CODEX_BINARY
      else process.env.ANKOLE_CODEX_BINARY = previousCodexBinary
      const realAppServer = codexAppServerSpec(materialized)
      const stderrChunks: string[] = []
      const mcpStartupFailures: Array<Record<string, unknown>> = []
      realClient = new CodexAppServerClient({
        cwd: realAppServer.cwd,
        env: realAppServer.env,
        commandArgv: realAppServer.commandArgv,
        onNotification: message => {
          if (message.method === '$stderr' && typeof (message.params as { text?: unknown })?.text === 'string') {
            stderrChunks.push((message.params as { text: string }).text)
          }
          if (message.method === 'mcpServer/startupStatus/updated') {
            const params = message.params as Record<string, unknown>
            if (params.status === 'failed') mcpStartupFailures.push(params)
          }
        }
      })

      let stage = 'initialize'
      try {
        const initializeResponse = await realClient.initialize()
        expect(initializeResponse.userAgent).toStartWith('codex_cli_rs/0.162.1 ')
        const threadEnv = codexJobThreadEnv({ materialized, workerEnv: { ANKOLE_JOB_SCOPE: 'job-1000' } })
        const threadConfig = codexJobThreadConfig({
          cwd: project.root,
          codexHome: materialized.codexHome,
          env: threadEnv,
          runtime: runtimeConfig,
          projectConfig: readCodexJobProjectConfig(project.root)
        })
        stage = 'thread/start'
        const thread = (await realClient.request('thread/start', {
          cwd: project.root,
          approvalPolicy: 'never',
          sandbox: 'danger-full-access',
          model: runtimeConfig.modelProfile.model,
          modelProvider: 'ankole_aigateway',
          config: threadConfig
        })) as ThreadStartResponse
        expect(thread.instructionSources.some(path => path.endsWith('/AGENTS.md'))).toBe(true)
        expect(thread.instructionSources).toHaveLength(1)
        expect(thread.model).toBe('gpt-5.6-sol')
        expect(thread.modelProvider).toBe('ankole_aigateway')
        expect(thread.reasoningEffort).toBe('xhigh')

        stage = 'mcpServerStatus/list'
        const mcpStatus = (await realClient.request('mcpServerStatus/list', {
          threadId: thread.thread.id,
          detail: 'toolsAndAuthOnly'
        })) as ListMcpServerStatusResponse
        expect(mcpStatus.data.find(server => server.name === 'native-fixture')).toMatchObject({
          name: 'native-fixture',
          serverInfo: { name: 'ankole-test-stdio', version: '1.0.0' }
        })
        expect(Object.keys(mcpStatus.data.find(server => server.name === 'native-fixture')?.tools ?? {})).toEqual([
          'stdio_echo'
        ])
        expect(mcpStatus.data.find(server => server.name === 'broken-optional')).toMatchObject({
          name: 'broken-optional',
          serverInfo: null,
          tools: {}
        })
        expect(mcpStartupFailures).toContainEqual(
          expect.objectContaining({
            threadId: thread.thread.id,
            name: 'broken-optional',
            status: 'failed'
          })
        )

        stage = 'mcpServer/tool/call'
        const echo = (await realClient.request('mcpServer/tool/call', {
          threadId: thread.thread.id,
          server: 'native-fixture',
          tool: 'stdio_echo',
          arguments: { text: 'native Codex MCP' }
        })) as McpServerToolCallResponse
        expect(echo.isError).not.toBe(true)
        expect(echo.content).toEqual([{ type: 'text', text: 'stdio response' }])
      } catch (error) {
        throw new Error(`[${stage}] ${errorMessage(error)}\n${stderrChunks.join('')}`)
      }
    } finally {
      await realClient?.close()
      if (previousCodexBinary === undefined) delete process.env.ANKOLE_CODEX_BINARY
      else process.env.ANKOLE_CODEX_BINARY = previousCodexBinary
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)
})

function appendOptionalMCPFixtures(projectRoot: string): void {
  appendFileSync(
    join(projectRoot, '.codex', 'config.toml'),
    [
      '',
      '[mcp_servers.native-fixture]',
      'command = "bun"',
      `args = ${JSON.stringify([join(import.meta.dir, '../../fixtures/mcp-stdio-server.ts')])}`,
      `cwd = ${JSON.stringify(join(import.meta.dir, '../../..'))}`,
      'required = false',
      'tool_timeout_sec = 10',
      'enabled_tools = ["stdio_echo"]',
      '',
      '[mcp_servers.broken-optional]',
      'command = "/ankole-test-missing-mcp-command"',
      'args = []',
      `cwd = ${JSON.stringify(projectRoot)}`,
      'required = false',
      'tool_timeout_sec = 1',
      'enabled_tools = ["unused"]',
      ''
    ].join('\n')
  )
}
