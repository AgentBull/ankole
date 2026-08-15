import { TOML } from 'bun'
import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { estimateO200kBaseTokens } from '@ankole/kernel'
import { jsonBytes } from '../../src/fabric/envelope_proto'
import {
  AIGatewayAPIKeyResponseSchema,
  AgentPluginCatalogEntrySchema,
  RuntimeSkillSummarySchema,
  SkillOverlayResolveResponseSchema,
  SkillOverlayResponseSchema
} from '../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import {
  chmodSync,
  appendFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { CodexAppServerClient, type JSONRPCMessage } from '../../src/core/codex-runner/app-server-client'
import { codexHomeRuntimeLockPath } from '../../src/core/codex-runner/codex-home-lock'
import type { ListMcpServerStatusResponse } from '../../src/core/codex-runner/generated/protocol/v2/ListMcpServerStatusResponse'
import type { McpServerToolCallResponse } from '../../src/core/codex-runner/generated/protocol/v2/McpServerToolCallResponse'
import type { ThreadStartResponse } from '../../src/core/codex-runner/generated/protocol/v2/ThreadStartResponse'
import {
  materializeCodexConfig,
  refreshCodexAgentRuntimeCredential,
  resetCodexAgentRuntimeConfig
} from '../../src/core/codex-runner/agent-home-config'
import { codexAgentRuntimeSandboxSpec, codexJobThreadEnv } from '../../src/core/codex-runner/sandbox'
import { materializeCodexJobRuntimeFiles, renderCodexJobAgents } from '../../src/core/codex-runner/runtime-files'
import { prepareCodexJobProject } from '../../src/core/codex-runner/job-project'
import { materializeCodexJobProjectConfig, readCodexJobProjectConfig } from '../../src/core/codex-runner/project-config'
import { codexJobThreadConfig } from '../../src/core/codex-runner/thread-config'
import {
  materializeAgentPluginPackages,
  materializeSelectedAgentPlugins,
  prepareAgentPlugins,
  selectAgentPluginCapabilities
} from '../../src/core/codex-runner/agent-plugin-materializer'
import {
  AgentCodexRuntime,
  AgentCodexRuntimeManager,
  type AgentCodexRuntimeLease,
  type AgentCodexRuntimeSession
} from '../../src/core/codex-runner/agent-runtime-manager'
import { rpcMethods, type RPCRequester } from '../../src/lanes/rpc_lane'
import type { CodexRuntimeConfig } from '../../src/core/codex-runner/runtime-config'

const checkedInProtocolRoot = join(import.meta.dir, '../../src/core/codex-runner/generated/protocol')

describe('@ankole/agent-computer Codex app-server protocol contract', () => {
  it('runs the Codex version pinned by the worker image', async () => {
    const proc = Bun.spawn(['codex', '--version'], { stdout: 'pipe', stderr: 'pipe' })
    const [exitCode, stdout, stderr] = await Promise.all([
      proc.exited,
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text()
    ])

    expect(exitCode).toBe(0)
    expect(`${stdout}${stderr}`.trim()).toBe('codex-cli 0.147.0')
  })

  it('does not retry a canonical Provider validation failure', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-invalid-prompt-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requests: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createInvalidPromptResponsesProvider(requests)
    if (typeof provider.port !== 'number') throw new Error('Invalid prompt provider did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      const baseURL = `http://127.0.0.1:${provider.port}/v1`
      resetCodexAgentRuntimeConfig(codexHome, baseURL)
      refreshCodexAgentRuntimeCredential(codexHome, 'contract-key')

      const runtime = pluginTestRuntime(baseURL, 'gpt-5.6-sol')
      const config = codexJobThreadConfig({ cwd: workspace, codexHome, env: {}, runtime }) as Record<string, any>
      config.model_providers.ankole_aigateway.supports_websockets = false
      client = new CodexAppServerClient({
        cwd: workspace,
        env: {
          PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
          HOME: workspace,
          CODEX_HOME: codexHome,
          CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
          LANG: 'C.UTF-8'
        },
        onNotification: notification => notifications.push(notification)
      })

      await client.initialize()
      const thread = (await client.request('thread/start', {
        cwd: workspace,
        model: runtime.modelProfile.model,
        modelProvider: 'ankole_aigateway',
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        config
      })) as ThreadStartResponse
      const turn = (await client.request('turn/start', {
        threadId: thread.thread.id,
        input: [{ type: 'text', text: 'Trigger one permanent Provider failure.', text_elements: [] }],
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      })) as { turn: { id: string } }

      const completed = await waitForTerminalTurn(notifications, turn.turn.id)
      const completedTurn = isObject(completed.params) && isObject(completed.params.turn) ? completed.params.turn : {}

      expect(completedTurn.status).toBe('failed')
      expect(requests).toHaveLength(1)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)

  it('uses the standalone compact endpoint when the frozen projection disables v2', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-standalone-compaction-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requestPaths: string[] = []
    const requests: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createRemoteCompactionResponsesProvider(requestPaths, requests)
    if (typeof provider.port !== 'number') throw new Error('Remote compaction provider did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      const baseURL = `http://127.0.0.1:${provider.port}/v1`
      resetCodexAgentRuntimeConfig(codexHome, baseURL)
      refreshCodexAgentRuntimeCredential(codexHome, 'contract-key')

      const runtime = pluginTestRuntime(baseURL, 'gpt-5.6-sol')
      const config = codexJobThreadConfig({ cwd: workspace, codexHome, env: {}, runtime }) as Record<string, any>
      config.model_providers.ankole_aigateway.supports_websockets = false

      client = new CodexAppServerClient({
        cwd: workspace,
        env: {
          PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
          HOME: workspace,
          CODEX_HOME: codexHome,
          CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
          LANG: 'C.UTF-8'
        },
        onNotification: notification => notifications.push(notification)
      })

      await client.initialize()
      const thread = (await client.request('thread/start', {
        cwd: workspace,
        model: runtime.modelProfile.model,
        modelProvider: 'ankole_aigateway',
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        config
      })) as ThreadStartResponse
      const turn = (await client.request('turn/start', {
        threadId: thread.thread.id,
        input: [{ type: 'text', text: 'Create one response before compaction.', text_elements: [] }],
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      })) as { turn: { id: string } }
      await waitForPluginTurn(notifications, turn.turn.id)

      await client.request('thread/compact/start', { threadId: thread.thread.id })
      await waitForContextCompaction(notifications, thread.thread.id)

      expect(requestPaths).toEqual(['/v1/responses', '/v1/responses/compact'])
      expect(requests).toHaveLength(2)
      expect(requests[1]?.input).toBeArray()
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)

  it('uses compaction_trigger when the frozen ChatGPT Subscription projection enables v2', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-remote-compaction-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requestPaths: string[] = []
    const requests: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createRemoteCompactionResponsesProvider(requestPaths, requests)
    if (typeof provider.port !== 'number') throw new Error('Remote compaction provider did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      const baseURL = `http://127.0.0.1:${provider.port}/v1`
      resetCodexAgentRuntimeConfig(codexHome, baseURL)
      refreshCodexAgentRuntimeCredential(codexHome, 'contract-key')

      const runtime = pluginTestRuntime(baseURL, 'gpt-5.6-sol')
      const config = codexJobThreadConfig({ cwd: workspace, codexHome, env: {}, runtime }) as Record<string, any>
      config.model_providers.ankole_aigateway.supports_websockets = false
      expect(config.model_providers.ankole_aigateway.name).toBe('OpenAI')

      client = new CodexAppServerClient({
        cwd: workspace,
        env: {
          PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
          HOME: workspace,
          CODEX_HOME: codexHome,
          CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
          LANG: 'C.UTF-8'
        },
        onNotification: notification => notifications.push(notification)
      })

      await client.initialize()
      const thread = (await client.request('thread/start', {
        cwd: workspace,
        model: runtime.modelProfile.model,
        modelProvider: 'ankole_aigateway',
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        config
      })) as ThreadStartResponse
      const turn = (await client.request('turn/start', {
        threadId: thread.thread.id,
        input: [{ type: 'text', text: 'Create one response before compaction.', text_elements: [] }],
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      })) as { turn: { id: string } }
      await waitForPluginTurn(notifications, turn.turn.id)

      await client.request('thread/compact/start', { threadId: thread.thread.id })
      await waitForContextCompaction(notifications, thread.thread.id)

      const followUp = (await client.request('turn/start', {
        threadId: thread.thread.id,
        input: [{ type: 'text', text: 'Continue after compaction.', text_elements: [] }],
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      })) as { turn: { id: string } }
      await waitForPluginTurn(notifications, followUp.turn.id)

      expect(requestPaths).toEqual(['/v1/responses', '/v1/responses', '/v1/responses'])
      expect(requests).toHaveLength(3)
      expect(Array.isArray(requests[1]?.input) ? requests[1].input.at(-1) : undefined).toEqual({
        type: 'compaction_trigger'
      })
      expect(Array.isArray(requests[2]?.input) ? requests[2].input : []).toContainEqual(
        expect.objectContaining({
          type: 'compaction',
          encrypted_content: 'provider-opaque-state'
        })
      )
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)

  it('carries a Job hosted web search through standard Responses', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-hosted-web-search-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requests: JSONObject[] = []
    const bindings: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createHostedWebSearchResponsesProvider(requests, bindings)
    if (typeof provider.port !== 'number') throw new Error('Hosted web search provider did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      const baseURL = `http://127.0.0.1:${provider.port}/v1`
      resetCodexAgentRuntimeConfig(codexHome, baseURL)
      refreshCodexAgentRuntimeCredential(codexHome, 'contract-key')
      materializeCodexJobProjectConfig({ projectRoot: workspace, hostedWebSearch: true })

      const runtime = pluginTestRuntime(baseURL, 'gpt-5.6-sol')
      const config = codexJobThreadConfig({
        cwd: workspace,
        codexHome,
        env: {},
        runtime,
        projectConfig: readCodexJobProjectConfig(workspace)
      }) as Record<string, any>
      client = new CodexAppServerClient({
        cwd: workspace,
        env: {
          PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
          HOME: workspace,
          CODEX_HOME: codexHome,
          CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
          LANG: 'C.UTF-8'
        },
        onNotification: notification => notifications.push(notification)
      })

      await client.initialize()
      const thread = (await client.request('thread/start', {
        cwd: workspace,
        model: runtime.modelProfile.model,
        modelProvider: 'ankole_aigateway',
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        config
      })) as ThreadStartResponse
      const turn = (await client.request('turn/start', {
        threadId: thread.thread.id,
        input: [{ type: 'text', text: 'Use live web search for this probe.', text_elements: [] }],
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      })) as { turn: { id: string } }
      await waitForPluginTurn(notifications, turn.turn.id)

      expect(requests).toHaveLength(1)
      expect(requests[0]?.tools).toEqual(expect.arrayContaining([expect.objectContaining({ type: 'web_search' })]))
      expect(bindings).toHaveLength(1)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)

  it('routes MultiAgentV2 children from sub-agent activity and exposes their raw tool calls', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-multi-agent-v2-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requestKinds: string[] = []
    const provider = createMultiAgentResponsesProvider(requestKinds)
    if (typeof provider.port !== 'number') throw new Error('MultiAgentV2 provider did not bind a TCP port')
    const allNotifications: JSONRPCMessage[] = []
    let runtime: AgentCodexRuntime | undefined
    let client: CodexAppServerClient | undefined

    const owner: AgentCodexRuntimeSession & { notifications: JSONRPCMessage[] } = {
      notifications: [],
      prepareForRuntimeCleanup() {},
      handleRuntimeNotification(message) {
        this.notifications.push(message)
      },
      async handleRuntimeServerRequest() {},
      handleRuntimeLost(error) {
        throw error
      }
    }

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      const baseURL = `http://127.0.0.1:${provider.port}/v1`
      resetCodexAgentRuntimeConfig(codexHome, baseURL)
      refreshCodexAgentRuntimeCredential(codexHome, 'contract-key')
      const runtimeConfig = pluginTestRuntime(baseURL, 'gpt-5.4')
      const config = codexJobThreadConfig({ cwd: workspace, codexHome, env: {}, runtime: runtimeConfig }) as Record<
        string,
        any
      >
      config.model_providers.ankole_aigateway.supports_websockets = false
      client = new CodexAppServerClient({
        cwd: workspace,
        env: {
          PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
          ...(process.env.VOLTA_HOME ? { VOLTA_HOME: process.env.VOLTA_HOME } : {}),
          HOME: workspace,
          CODEX_HOME: codexHome,
          CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
          LANG: 'C.UTF-8'
        },
        onNotification: notification => {
          allNotifications.push(notification)
          runtime?.routeNotification(notification)
        }
      })
      await pluginStage(client.initialize(), 'MultiAgentV2 initialize')
      runtime = new AgentCodexRuntime('agent-1', client)
      const thread = (await pluginStage(
        client.request('thread/start', {
          cwd: workspace,
          model: runtimeConfig.modelProfile.model,
          modelProvider: 'ankole_aigateway',
          approvalPolicy: 'never',
          sandbox: 'danger-full-access',
          experimentalRawEvents: true,
          config
        }),
        'MultiAgentV2 thread/start'
      )) as ThreadStartResponse
      await runtime.registerRoot(thread.thread.id, owner)
      const turn = (await pluginStage(
        client.request('turn/start', {
          threadId: thread.thread.id,
          input: [{ type: 'text', text: 'PARENT_PROBE: spawn one child.', text_elements: [] }],
          cwd: workspace,
          approvalPolicy: 'never',
          sandboxPolicy: { type: 'dangerFullAccess' }
        }),
        'MultiAgentV2 turn/start'
      )) as { turn: { id: string } }
      await waitForTurnTree(allNotifications, thread.thread.id, turn.turn.id)
      await runtime.waitForSessionTurnsIdle(owner)

      const activity = allNotifications.find(notification => {
        const params = isObject(notification.params) ? notification.params : {}
        const item = isObject(params.item) ? params.item : {}
        return item.type === 'subAgentActivity' && item.kind === 'started'
      })
      const activityItem = isObject(activity?.params) && isObject(activity.params.item) ? activity.params.item : {}
      const childThreadID = typeof activityItem.agentThreadId === 'string' ? activityItem.agentThreadId : ''
      expect(childThreadID).not.toBe('')
      expect(
        allNotifications.some(notification => {
          const params = isObject(notification.params) ? notification.params : {}
          const startedThread = isObject(params.thread) ? params.thread : {}
          return notification.method === 'thread/started' && startedThread.id === childThreadID
        })
      ).toBe(false)
      expect(owner.notifications.some(notification => notificationThreadID(notification) === childThreadID)).toBe(true)
      const rawSpawn = allNotifications.find(notification => {
        const params = isObject(notification.params) ? notification.params : {}
        const item = isObject(params.item) ? params.item : {}
        return (
          notification.method === 'rawResponseItem/completed' &&
          item.type === 'function_call' &&
          item.name === 'spawn_agent'
        )
      })
      const rawSpawnItem = isObject(rawSpawn?.params) && isObject(rawSpawn.params.item) ? rawSpawn.params.item : {}
      expect(rawSpawnItem.namespace).toBe('collaboration')
      expect(rawSpawnItem.call_id).toBe(activityItem.id)
    } catch (error) {
      const stderr = allNotifications
        .filter(notification => notification.method === '$stderr' && isObject(notification.params))
        .flatMap(notification =>
          isObject(notification.params) && typeof notification.params.text === 'string'
            ? [notification.params.text]
            : []
        )
        .join('')
      throw new Error(
        `${error instanceof Error ? error.message : String(error)}\nrequests=${requestKinds.join(',')}\n${stderr}`
      )
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)

  it('applies request and model limits to model-visible code-mode output', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-exec-output-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requests: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createExecOutputResponsesProvider(requests)
    if (typeof provider.port !== 'number') throw new Error('Exec output provider did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      const baseURL = `http://127.0.0.1:${provider.port}/v1`
      resetCodexAgentRuntimeConfig(codexHome, baseURL)
      refreshCodexAgentRuntimeCredential(codexHome, 'contract-key')

      const runtime = pluginTestRuntime(baseURL)
      const config = codexJobThreadConfig({ cwd: workspace, codexHome, env: {}, runtime }) as Record<string, any>
      config.model_providers.ankole_aigateway.supports_websockets = false
      client = new CodexAppServerClient({
        cwd: workspace,
        env: {
          PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
          HOME: workspace,
          CODEX_HOME: codexHome,
          CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
          LANG: 'C.UTF-8'
        },
        onNotification: notification => notifications.push(notification)
      })

      await client.initialize()
      const thread = (await client.request('thread/start', {
        cwd: workspace,
        model: runtime.modelProfile.model,
        modelProvider: 'ankole_aigateway',
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        config
      })) as ThreadStartResponse
      const turn = (await client.request('turn/start', {
        threadId: thread.thread.id,
        input: [{ type: 'text', text: 'Run the output contract probe.', text_elements: [] }],
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      })) as { turn: { id: string } }
      await waitForPluginTurn(notifications, turn.turn.id)

      expect(requests).toHaveLength(3)

      const modelLimitedOutput = customToolOutputTexts(requests[1]!, modelLimitedExecOutputCallID).at(-1)
      expect(modelLimitedOutput).toBeString()
      expect(modelLimitedOutput).toContain('tokens truncated')
      const modelLimitedTokens = estimateO200kBaseTokens(modelLimitedOutput!)
      expect(modelLimitedTokens).toBeGreaterThan(9_000)
      expect(modelLimitedTokens).toBeLessThanOrEqual(10_100)

      const requestLimitedOutput = customToolOutputTexts(requests[2]!, requestLimitedExecOutputCallID).at(-1)
      expect(requestLimitedOutput).toBeString()
      expect(requestLimitedOutput).toContain('tokens truncated')
      const requestLimitedTokens = estimateO200kBaseTokens(requestLimitedOutput!)
      expect(requestLimitedTokens).toBeGreaterThan(3_500)
      expect(requestLimitedTokens).toBeLessThanOrEqual(4_100)
    } catch (error) {
      const stderr = notifications
        .filter(notification => notification.method === '$stderr' && isObject(notification.params))
        .flatMap(notification =>
          isObject(notification.params) && typeof notification.params.text === 'string'
            ? [notification.params.text]
            : []
        )
        .join('')
      throw new Error(`${error instanceof Error ? error.message : String(error)}\n${stderr}`)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)

  it('can execute the Codex Linux sandbox inside the worker container', async () => {
    const proc = Bun.spawn(['codex', 'sandbox', '/bin/true'], { stdout: 'pipe', stderr: 'pipe' })
    const [exitCode, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()])

    expect(stderr).toBe('')
    expect(exitCode).toBe(0)
  })

  it('releases the Agent Codex Home lock after each real sandboxed app-server exit', async () => {
    const agentsRoot = mkdtempSync('/agents/ankole-codex-lock-contract-')
    const materialized = materializeCodexConfig({ agentsRoot, agentUID: 'agent-1' })
    mkdirSync(materialized.agentHome, { recursive: true })
    const sandbox = codexAgentRuntimeSandboxSpec({ materialized })
    const manager = new AgentCodexRuntimeManager()
    let lease: AgentCodexRuntimeLease | undefined

    try {
      expect(
        sandbox.commandArgv.some(
          (value, index) =>
            value === '--bind' &&
            sandbox.commandArgv[index + 1] === materialized.codexHome &&
            sandbox.commandArgv[index + 2] === materialized.codexHome
        )
      ).toBe(true)

      for (let index = 0; index < 6; index += 1) {
        lease = await manager.acquire({
          agentUID: 'agent-1',
          agentHome: materialized.agentHome,
          codexHome: materialized.codexHome,
          aiGatewayBaseURL: 'http://control.test/api/v1/ai-gateway',
          aiGatewayAPIKey: `contract-key-${index}`,
          sandbox
        })
        await lease.release()
        lease = undefined

        const probe = Bun.spawn(
          ['flock', '-n', '-E', '75', '-F', codexHomeRuntimeLockPath(materialized.codexHome), '/bin/true'],
          { stdout: 'pipe', stderr: 'pipe' }
        )
        const [exitCode, stderr] = await Promise.all([probe.exited, new Response(probe.stderr).text()])
        if (exitCode !== 0) throw new Error(`Codex Home lock stayed busy after app-server exit: ${stderr}`)
      }
    } finally {
      await lease?.release()
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  }, 90_000)

  it('matches the experimental TypeScript bindings generated by the pinned Codex binary', async () => {
    const generatedRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-protocol-'))

    try {
      const proc = Bun.spawn(['codex', 'app-server', 'generate-ts', '--experimental', '--out', generatedRoot], {
        stdout: 'pipe',
        stderr: 'pipe'
      })
      const [exitCode, stdout, stderr] = await Promise.all([
        proc.exited,
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text()
      ])

      expect(`${stdout}\n${stderr}`).toBeString()
      expect(exitCode).toBe(0)
      expect(protocolFiles(checkedInProtocolRoot)).toEqual(protocolFiles(generatedRoot))

      for (const file of protocolFiles(generatedRoot)) {
        expect(readFileSync(join(checkedInProtocolRoot, file), 'utf8')).toBe(
          readFileSync(join(generatedRoot, file), 'utf8')
        )
      }
    } finally {
      rmSync(generatedRoot, { recursive: true, force: true })
    }
  })

  it('discovers standalone Skills through the native project root', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-native-skills-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const skillsRoot = join(workspace, '.agents', 'skills')
    const skillRoot = join(skillsRoot, 'pptx')
    mkdirSync(workspace, { recursive: true })
    mkdirSync(codexHome, { recursive: true })
    mkdirSync(skillRoot, { recursive: true })
    writeFileSync(
      join(skillRoot, 'SKILL.md'),
      ['---', 'name: pptx', 'description: Create PowerPoint presentations.', '---', '', '# PPTX', ''].join('\n')
    )

    const client = new CodexAppServerClient({
      cwd: workspace,
      env: {
        PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
        HOME: workspace,
        CODEX_HOME: codexHome,
        CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
        LANG: 'C.UTF-8'
      }
    })

    try {
      await client.initialize()
      const response = (await client.request('skills/list', {
        cwds: [workspace],
        forceReload: true
      })) as { data: Array<{ skills: Array<{ name: string; path: string; enabled: boolean }> }> }

      expect(response.data[0]?.skills.find(skill => skill.name === 'pptx')).toMatchObject({
        name: 'pptx',
        path: join(skillRoot, 'SKILL.md'),
        enabled: true
      })
    } finally {
      await client.close()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('officially installs Agent-owned Plugins and isolates selected roots between threads', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-agent-plugin-runtime-'))
    const libraryRoot = join(root, 'library')
    const agentHome = join(root, 'agent-home')
    const codexHome = join(agentHome, '.codex')
    const alphaProject = join(agentHome, 'jobs', 'alpha')
    const betaProject = join(agentHome, 'jobs', 'beta')
    const skillMaterialsRoot = join(agentHome, 'runtime-materials', 'skills')
    const notifications: JSONRPCMessage[] = []
    const requests: JSONObject[] = []
    const provider = createPluginResponsesProvider(requests)
    if (typeof provider.port !== 'number') throw new Error('Plugin Responses provider did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      createAgentPluginFixture(libraryRoot, 'alpha', 'ALPHA_SELECTED_BODY', true)
      createAgentPluginSkillFixture(
        libraryRoot,
        'alpha',
        'alpha-extra',
        'ALPHA_UNSELECTED_DESCRIPTION',
        'ALPHA_UNSELECTED_BODY'
      )
      createAgentPluginFixture(libraryRoot, 'beta', 'BETA_SELECTED_BODY', false)
      mkdirSync(codexHome, { recursive: true })
      mkdirSync(betaProject, { recursive: true })
      writeFileSync(join(betaProject, 'AGENTS.md'), '# Beta Job\n')
      const catalog = [
        create(AgentPluginCatalogEntrySchema, {
          id: 'alpha',
          description: 'alpha Plugin',
          skills: [{ catalogName: 'alpha-skill' }, { catalogName: 'alpha-extra' }]
        }),
        create(AgentPluginCatalogEntrySchema, {
          id: 'beta',
          description: 'beta Plugin',
          skills: [{ catalogName: 'beta-skill' }]
        })
      ]
      const prepared = prepareAgentPlugins({
        projectRoot: alphaProject,
        agentPlugins: catalog,
        agentHome,
        libraryRoot,
        initializeProject: true,
        agentsContent: '# Alpha Job'
      })
      materializeAgentPluginPackages(prepared, { rebuild: true })

      const baseURL = `http://127.0.0.1:${provider.port}/v1`
      resetCodexAgentRuntimeConfig(codexHome, baseURL)
      refreshCodexAgentRuntimeCredential(codexHome, 'contract-key')
      client = new CodexAppServerClient({
        cwd: agentHome,
        env: {
          PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
          HOME: agentHome,
          CODEX_HOME: codexHome,
          CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
          LANG: 'C.UTF-8'
        },
        onNotification: notification => notifications.push(notification)
      })
      await pluginStage(client.initialize(), 'initialize')
      const runtimeOwner = new AgentCodexRuntime('agent-1', client)
      await pluginStage(
        runtimeOwner.ensureAgentPlugins({ cwd: agentHome, prepared }),
        'official Plugin install, Hook trust, and global disable'
      )

      const config = TOML.parse(readFileSync(join(codexHome, 'config.toml'), 'utf8')) as Record<string, any>
      expect(config.plugins['alpha@ankole-agent-runtime'].enabled).toBe(false)
      expect(config.plugins['beta@ankole-agent-runtime'].enabled).toBe(false)
      expect(Object.keys(config.hooks.state)).not.toHaveLength(0)

      const alphaSelection = create(AgentPluginCatalogEntrySchema, {
        id: 'alpha',
        description: 'alpha Plugin',
        skills: [{ catalogName: 'alpha-skill' }]
      })
      const alphaPackages = materializeSelectedAgentPlugins(prepared, [alphaSelection], {
        materializedRoot: join(alphaProject, '.ankole', 'agent-plugins'),
        skillMaterialsRoot
      })
      const betaPackages = materializeSelectedAgentPlugins(prepared, [catalog[1]!], {
        materializedRoot: join(betaProject, '.ankole', 'agent-plugins'),
        skillMaterialsRoot
      })
      const alphaCapabilities = selectAgentPluginCapabilities(alphaPackages, [alphaSelection])
      const betaCapabilities = selectAgentPluginCapabilities(betaPackages, [catalog[1]!])
      const alphaRuntime = pluginTestRuntime(baseURL, 'gpt-5.4', 'high')
      const betaRuntime = pluginTestRuntime(baseURL, 'gpt-5.4-mini', 'low')
      const alphaThreadConfig = codexJobThreadConfig({
        cwd: alphaProject,
        codexHome,
        env: {},
        runtime: alphaRuntime
      }) as Record<string, any>
      const betaThreadConfig = codexJobThreadConfig({
        cwd: betaProject,
        codexHome,
        env: {},
        runtime: betaRuntime
      }) as Record<string, any>
      alphaThreadConfig.model_providers.ankole_aigateway.supports_websockets = false
      betaThreadConfig.model_providers.ankole_aigateway.supports_websockets = false

      const alphaThread = (await pluginStage(
        client.request('thread/start', {
          cwd: alphaProject,
          model: alphaRuntime.modelProfile.model,
          modelProvider: 'ankole_aigateway',
          approvalPolicy: 'never',
          sandbox: 'danger-full-access',
          config: alphaThreadConfig,
          selectedCapabilityRoots: alphaCapabilities.selectedCapabilityRoots
        }),
        'alpha thread/start'
      )) as ThreadStartResponse
      const betaThread = (await pluginStage(
        client.request('thread/start', {
          cwd: betaProject,
          model: betaRuntime.modelProfile.model,
          modelProvider: 'ankole_aigateway',
          approvalPolicy: 'never',
          sandbox: 'danger-full-access',
          config: betaThreadConfig,
          selectedCapabilityRoots: betaCapabilities.selectedCapabilityRoots
        }),
        'beta thread/start'
      )) as ThreadStartResponse

      expect(alphaThread.model).toBe('gpt-5.4')
      expect(alphaThread.reasoningEffort).toBe('high')
      expect(betaThread.model).toBe('gpt-5.4-mini')
      expect(betaThread.reasoningEffort).toBe('low')

      const [alphaTurn, betaTurn] = (await Promise.all([
        pluginStage(
          client.request('turn/start', {
            threadId: alphaThread.thread.id,
            input: [{ type: 'text', text: 'Use $alpha:alpha-skill.', text_elements: [] }],
            cwd: alphaProject,
            approvalPolicy: 'never',
            sandboxPolicy: { type: 'dangerFullAccess' },
            model: alphaRuntime.modelProfile.model,
            effort: alphaRuntime.modelProfile.modelReasoningEffort
          }),
          'alpha turn/start'
        ),
        pluginStage(
          client.request('turn/start', {
            threadId: betaThread.thread.id,
            input: [{ type: 'text', text: 'Use $beta:beta-skill.', text_elements: [] }],
            cwd: betaProject,
            approvalPolicy: 'never',
            sandboxPolicy: { type: 'dangerFullAccess' },
            model: betaRuntime.modelProfile.model,
            effort: betaRuntime.modelProfile.modelReasoningEffort
          }),
          'beta turn/start'
        )
      ])) as Array<{ turn: { id: string } }>
      await Promise.all([
        waitForPluginTurn(notifications, alphaTurn.turn.id),
        waitForPluginTurn(notifications, betaTurn.turn.id)
      ])

      expect(requests).toHaveLength(2)
      const alphaRequestBody = requests.find(request => request.model === 'gpt-5.4')
      const betaRequestBody = requests.find(request => request.model === 'gpt-5.4-mini')
      expect(alphaRequestBody).toBeDefined()
      expect(betaRequestBody).toBeDefined()
      const alphaRequest = JSON.stringify(alphaRequestBody)
      const betaRequest = JSON.stringify(betaRequestBody)
      expect(alphaRequest).toContain('ALPHA_SELECTED_BODY')
      expect(alphaRequest).not.toContain('BETA_SELECTED_BODY')
      expect(alphaRequest).not.toContain('ALPHA_UNSELECTED_DESCRIPTION')
      expect(betaRequest).toContain('BETA_SELECTED_BODY')
      expect(betaRequest).not.toContain('ALPHA_SELECTED_BODY')
      expect(alphaRequestBody?.reasoning).toMatchObject({ effort: 'high' })
      expect(betaRequestBody?.reasoning).toMatchObject({ effort: 'low' })

      const resumeThread = (await pluginStage(
        client.request('thread/start', {
          cwd: alphaProject,
          model: alphaRuntime.modelProfile.model,
          modelProvider: 'ankole_aigateway',
          approvalPolicy: 'never',
          sandbox: 'danger-full-access',
          config: alphaThreadConfig,
          selectedCapabilityRoots: alphaCapabilities.selectedCapabilityRoots
        }),
        'resume fixture thread/start'
      )) as ThreadStartResponse
      const resumeWarmupTurn = (await pluginStage(
        client.request('turn/start', {
          threadId: resumeThread.thread.id,
          input: [{ type: 'text', text: 'Reply ready. Do not use any Skill.', text_elements: [] }],
          cwd: alphaProject,
          approvalPolicy: 'never',
          sandboxPolicy: { type: 'dangerFullAccess' }
        }),
        'resume fixture warmup turn/start'
      )) as { turn: { id: string } }
      await waitForPluginTurn(notifications, resumeWarmupTurn.turn.id)
      expect(requests).toHaveLength(3)
      expect(JSON.stringify(requests[2])).not.toContain('ALPHA_SELECTED_BODY')
      materializeSelectedAgentPlugins(prepared, [], {
        materializedRoot: join(alphaProject, '.ankole', 'agent-plugins'),
        skillMaterialsRoot
      })
      const disabledAlphaConfig = codexJobThreadConfig({
        cwd: alphaProject,
        codexHome,
        env: {},
        runtime: alphaRuntime
      }) as Record<string, any>
      disabledAlphaConfig.model_providers.ankole_aigateway.supports_websockets = false
      await pluginStage(
        client.request('thread/resume', {
          threadId: resumeThread.thread.id,
          cwd: alphaProject,
          model: alphaRuntime.modelProfile.model,
          modelProvider: 'ankole_aigateway',
          approvalPolicy: 'never',
          sandbox: 'danger-full-access',
          config: disabledAlphaConfig
        }),
        'resume fixture thread/resume with current disable'
      )
      const disabledAlphaTurn = (await pluginStage(
        client.request('turn/start', {
          threadId: resumeThread.thread.id,
          input: [{ type: 'text', text: 'Use $alpha:alpha-skill.', text_elements: [] }],
          cwd: alphaProject,
          approvalPolicy: 'never',
          sandboxPolicy: { type: 'dangerFullAccess' }
        }),
        'disabled alpha turn/start'
      )) as { turn: { id: string } }
      await waitForPluginTurn(notifications, disabledAlphaTurn.turn.id)
      expect(requests).toHaveLength(4)
      expect(JSON.stringify(requests[3])).not.toContain('ALPHA_SELECTED_BODY')
    } catch (error) {
      const stderr = notifications
        .filter(notification => notification.method === '$stderr' && isObject(notification.params))
        .flatMap(notification =>
          isObject(notification.params) && typeof notification.params.text === 'string'
            ? [notification.params.text]
            : []
        )
        .join('')
      throw new Error(`${error instanceof Error ? error.message : String(error)}\n${stderr}`)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 90_000)

  it('uses real Job and Skill paths inside the bubblewrap sandbox', async () => {
    const root = mkdtempSync('/agents/ankole-codex-contract-')
    const jobProjectRoot = join(root, 'agent-1', 'jobs', '1000')
    const builtinSkillsRoot = join(root, 'skills')
    const skillRoot = join(builtinSkillsRoot, 'pptx')
    const plainSkillRoot = join(builtinSkillsRoot, 'plain-skill')
    const fakeCodex = join(jobProjectRoot, 'fake-codex')
    const previousCodexBinary = process.env.ANKOLE_CODEX_BINARY
    mkdirSync(jobProjectRoot, { recursive: true })
    mkdirSync(skillRoot, { recursive: true })
    mkdirSync(plainSkillRoot, { recursive: true })
    writeFileSync(
      join(skillRoot, 'SKILL.md'),
      ['---', 'name: pptx', 'description: Create PowerPoint presentations.', '---', '', '# PPTX', ''].join('\n')
    )
    writeFileSync(
      join(plainSkillRoot, 'SKILL.md'),
      ['---', 'name: plain-skill', 'description: Verify native Skill discovery.', '---', '', '# Plain', ''].join('\n')
    )
    writeFileSync(
      fakeCodex,
      `#!/bin/sh
set -eu
grep -q 'TASK_AGENTS_MARKER' ${jobProjectRoot}/AGENTS.md
grep -q '# PPTX' ${jobProjectRoot}/.agents/skills/pptx/SKILL.md
grep -q 'PG_OVERLAY_MARKER' ${jobProjectRoot}/.agents/skills/pptx/SKILL.md
grep -q '# Plain' ${jobProjectRoot}/.agents/skills/plain-skill/SKILL.md
grep -q '^name: pdf$' /repo/app/library/skills/pdf/SKILL.md
! grep -q '^model = ' ${jobProjectRoot}/.codex/config.toml
grep -q 'native-fixture' ${jobProjectRoot}/.codex/config.toml
grep -q 'broken-optional' ${jobProjectRoot}/.codex/config.toml
grep -q '^model_provider = "ankole_aigateway"$' \${CODEX_HOME}/config.toml
test -z "\${ANKOLE_AIGATEWAY_MODEL_BINDING:-}"
printf 'command path works\n' > ${jobProjectRoot}/command-probe.txt
test "$(bun -e "const { genericHash } = require('/repo/app/kernel'); process.stdout.write(genericHash(Buffer.from('bullx')))")" = '7f31cabae40697f9404428671c582d3c1f80c8a13d0741f4be8c9b856fcc0706'
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
    const runtimeInput: Parameters<typeof materializeCodexJobRuntimeFiles>[0] = {
      turn: {
        actor: { agent_uid: 'agent-1', session_id: 'job:1000' },
        activation_uid: 'activation-1',
        actor_epoch: 1,
        actor_event_id: '00000000-0000-0000-0000-000000000001',
        revision: 0
      },
      jobRoot: project.root,
      agentSkillsRoot: join(root, 'agent-1', 'runtime-materials', 'skills'),
      enabledSkills: [
        create(RuntimeSkillSummarySchema, {
          skillName: 'pptx',
          sourceKind: 'builtin',
          relativePath: 'pptx',
          hasAgentOverlay: true
        }),
        create(RuntimeSkillSummarySchema, {
          skillName: 'plain-skill',
          sourceKind: 'builtin',
          relativePath: 'plain-skill',
          hasAgentOverlay: false
        })
      ],
      projectSkillNames: ['plain-skill', 'pptx'],
      skillRoots: {
        builtinSkillsRoot,
        agentInstalledSkillsRoot: join(root, 'installed-skills')
      },
      rpc: (async (method: unknown, payload: unknown) => {
        if (method !== rpcMethods.skillsOverlayResolve) throw new Error(`unexpected RPC method: ${String(method)}`)
        const request = payload as { skillNames: string[] }
        return create(SkillOverlayResolveResponseSchema, {
          overlays: request.skillNames.map(skillName =>
            create(SkillOverlayResponseSchema, {
              skillName,
              hasOverlay: skillName === 'pptx',
              ...(skillName === 'pptx'
                ? { overlayJson: jsonBytes({ text: 'PG_OVERLAY_MARKER' }), contentHash: 'overlay-hash' }
                : {})
            })
          )
        })
      }) as RPCRequester
    }
    const runtimeFiles = await materializeCodexJobRuntimeFiles(runtimeInput)
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
        agentUid: 'agent-1',
        apiKey: 'unused-test-key',
        tokenType: 'Bearer',
        expiresAt: BigInt(Math.floor(Date.now() / 1_000) + 3_600),
        expiresIn: 3_600n,
        scope: 'ai_gateway',
        baseUrl: 'http://control.test/api/v1/ai-gateway'
      })
    }
    const materialized = materializeCodexConfig({
      agentsRoot: root,
      agentUID: 'agent-1'
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
      const sandbox = codexAgentRuntimeSandboxSpec({ materialized })
      const proc = Bun.spawn(sandbox.commandArgv, {
        cwd: sandbox.cwd,
        env: sandbox.env,
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
      if (exitCode !== 0) throw new Error(`fake Codex sandbox probe exited with ${exitCode}: ${stderr}`)
      expect(readFileSync(join(jobProjectRoot, 'command-probe.txt'), 'utf8')).toBe('command path works\n')
      expect(existsSync(join(jobProjectRoot, 'AGENTS.override.md'))).toBe(false)
      expect(readFileSync(join(skillRoot, 'SKILL.md'), 'utf8')).not.toContain('PG_OVERLAY_MARKER')

      if (previousCodexBinary === undefined) delete process.env.ANKOLE_CODEX_BINARY
      else process.env.ANKOLE_CODEX_BINARY = previousCodexBinary
      const realSandbox = codexAgentRuntimeSandboxSpec({ materialized })
      const stderrChunks: string[] = []
      const mcpStartupFailures: Array<Record<string, unknown>> = []
      realClient = new CodexAppServerClient({
        cwd: realSandbox.cwd,
        env: realSandbox.env,
        commandArgv: realSandbox.commandArgv,
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
        expect(initializeResponse.userAgent).toStartWith('codex_cli_rs/0.147.0 ')
        stage = 'skills/list'
        const response = (await realClient.request('skills/list', {
          cwds: [project.codexCwd],
          forceReload: true
        })) as { data: Array<{ skills: Array<{ name: string; path: string; enabled: boolean }> }> }
        expect(response.data[0]?.skills.find(skill => skill.name === 'pptx')).toMatchObject({
          name: 'pptx',
          path: `${runtimeInput.agentSkillsRoot}/pptx/SKILL.md`,
          enabled: true
        })
        expect(response.data[0]?.skills.find(skill => skill.name === 'plain-skill')).toMatchObject({
          name: 'plain-skill',
          path: `${runtimeInput.agentSkillsRoot}/plain-skill/SKILL.md`,
          enabled: true
        })
        const threadEnv = codexJobThreadEnv({ materialized, workerEnv: { ANKOLE_JOB_SCOPE: 'job-1000' } })
        const threadConfig = codexJobThreadConfig({
          cwd: project.codexCwd,
          codexHome: materialized.codexHome,
          env: threadEnv,
          runtime: runtimeConfig,
          projectConfig: readCodexJobProjectConfig(project.root)
        })
        stage = 'thread/start'
        const thread = (await realClient.request('thread/start', {
          cwd: project.codexCwd,
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
        throw new Error(
          `[${stage}] ${error instanceof Error ? error.message : String(error)}\n${stderrChunks.join('')}`
        )
      }
    } finally {
      await realClient?.close()
      if (previousCodexBinary === undefined) delete process.env.ANKOLE_CODEX_BINARY
      else process.env.ANKOLE_CODEX_BINARY = previousCodexBinary
      runtimeFiles.cleanup()
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)
})

function createAgentPluginFixture(libraryRoot: string, id: string, bodyMarker: string, withHook: boolean): void {
  const pluginRoot = join(libraryRoot, id)
  mkdirSync(join(pluginRoot, '.codex-plugin'), { recursive: true })
  mkdirSync(join(pluginRoot, 'skills', `${id}-skill`), { recursive: true })
  writeFileSync(
    join(pluginRoot, '.codex-plugin', 'plugin.json'),
    JSON.stringify({
      name: id,
      version: '1.0.0',
      description: `${id} Plugin`,
      skills: './skills/'
    })
  )
  writeFileSync(
    join(pluginRoot, 'skills', `${id}-skill`, 'SKILL.md'),
    ['---', `name: ${id}-skill`, `description: ${id} selected capability.`, '---', '', `# ${bodyMarker}`, ''].join('\n')
  )
  if (withHook) {
    mkdirSync(join(pluginRoot, 'hooks'), { recursive: true })
    writeFileSync(
      join(pluginRoot, 'hooks', 'hooks.json'),
      JSON.stringify({ hooks: { SessionStart: [{ hooks: [{ type: 'command', command: '/bin/true' }] }] } })
    )
  }
}

function createAgentPluginSkillFixture(
  libraryRoot: string,
  pluginID: string,
  skillName: string,
  description: string,
  bodyMarker: string
): void {
  const skillRoot = join(libraryRoot, pluginID, 'skills', skillName)
  mkdirSync(skillRoot, { recursive: true })
  writeFileSync(
    join(skillRoot, 'SKILL.md'),
    ['---', `name: ${skillName}`, `description: ${description}`, '---', '', `# ${bodyMarker}`, ''].join('\n')
  )
}

function pluginTestRuntime(baseURL: string, model = 'gpt-5.4', reasoningEffort?: 'low' | 'high'): CodexRuntimeConfig {
  return {
    aiGatewayKey: create(AIGatewayAPIKeyResponseSchema, {
      apiKey: 'contract-key',
      baseUrl: baseURL,
      expiresAt: BigInt(Math.floor(Date.now() / 1_000) + 3_600),
      expiresIn: 3_600n,
      scope: 'ai_gateway'
    }),
    modelProfile: {
      model,
      selector: model,
      providerOptions: reasoningEffort ? { reasoningEffort } : {},
      supportsParallelToolCalls: false,
      inputModalities: ['text'],
      ...(reasoningEffort ? { modelReasoningEffort: reasoningEffort } : {})
    }
  }
}

const modelLimitedExecOutputCallID = 'exec-output-model-limit'
const requestLimitedExecOutputCallID = 'exec-output-request-limit'

function createMultiAgentResponsesProvider(requestKinds: string[]) {
  let requestCount = 0
  return Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request) {
      const url = new URL(request.url)
      if (request.method === 'GET' && url.pathname === '/v1/models') {
        return Response.json({ models: [execOutputModelCard('gpt-5.4')] })
      }
      if (request.method !== 'POST' || url.pathname !== '/v1/responses') {
        return Response.json({ error: { message: 'not found' } }, { status: 404 })
      }

      requestCount += 1
      const body = (await request.json()) as JSONObject
      const serialized = JSON.stringify(body)
      const responseID = `multi-agent-response-${requestCount}`
      if (serialized.includes('function_call_output')) {
        requestKinds.push('parent-followup')
        return execOutputResponse(responseID, 'gpt-5.4', [
          {
            id: 'multi-agent-parent-message',
            type: 'message',
            status: 'completed',
            role: 'assistant',
            content: [{ type: 'output_text', text: 'PARENT_DONE', annotations: [] }]
          }
        ])
      }
      if (serialized.includes('CHILD_PROBE')) {
        requestKinds.push('child')
        return execOutputResponse(responseID, 'gpt-5.4', [
          {
            id: 'multi-agent-child-message',
            type: 'message',
            status: 'completed',
            role: 'assistant',
            content: [{ type: 'output_text', text: 'CHILD_DONE', annotations: [] }]
          }
        ])
      }
      requestKinds.push('parent-initial')
      return execOutputResponse(responseID, 'gpt-5.4', [
        {
          type: 'function_call',
          call_id: 'multi-agent-spawn-call',
          namespace: 'collaboration',
          name: 'spawn_agent',
          arguments: JSON.stringify({
            task_name: 'probe_child',
            message: 'CHILD_PROBE: reply once.',
            fork_turns: 'none'
          })
        }
      ])
    }
  })
}

function createRemoteCompactionResponsesProvider(requestPaths: string[], requests: JSONObject[]) {
  return Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request) {
      const url = new URL(request.url)
      if (request.method === 'GET' && url.pathname === '/v1/models') {
        return Response.json({ models: [execOutputModelCard('gpt-5.6-sol')] })
      }
      if (request.method !== 'POST') {
        return Response.json({ error: { message: 'not found' } }, { status: 404 })
      }

      const body = (await request.json()) as JSONObject
      requestPaths.push(url.pathname)
      requests.push(body)

      if (url.pathname === '/v1/responses/compact') {
        return Response.json({
          id: 'remote-compaction-contract',
          object: 'response.compaction',
          created_at: 1_764_967_971,
          output: [{ type: 'compaction', encrypted_content: 'provider-opaque-state' }],
          usage: {
            input_tokens: 1,
            input_tokens_details: { cached_tokens: 0 },
            output_tokens: 1,
            output_tokens_details: { reasoning_tokens: 0 },
            total_tokens: 2
          }
        })
      }

      if (url.pathname === '/v1/responses') {
        const input = Array.isArray(body.input) ? body.input : []
        if (input.some(item => isObject(item) && item.type === 'compaction_trigger')) {
          return execOutputResponse('remote-compaction-contract', 'gpt-5.6-sol', [
            { type: 'compaction', encrypted_content: 'provider-opaque-state' }
          ])
        }

        return execOutputResponse('remote-compaction-source', 'gpt-5.6-sol', [
          {
            id: 'remote-compaction-source-message',
            type: 'message',
            status: 'completed',
            role: 'assistant',
            content: [{ type: 'output_text', text: 'Ready to compact.', annotations: [] }]
          }
        ])
      }

      return Response.json({ error: { message: 'not found' } }, { status: 404 })
    }
  })
}

function createInvalidPromptResponsesProvider(requests: JSONObject[]) {
  return Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request) {
      const url = new URL(request.url)
      if (request.method === 'GET' && url.pathname === '/v1/models') {
        return Response.json({ models: [execOutputModelCard('gpt-5.6-sol')] })
      }
      if (request.method !== 'POST' || url.pathname !== '/v1/responses') {
        return Response.json({ error: { message: 'not found' } }, { status: 404 })
      }

      requests.push((await request.json()) as JSONObject)
      const event = {
        type: 'response.failed',
        response: {
          id: 'invalid-prompt-contract',
          error: {
            code: 'invalid_prompt',
            message: "Invalid Value: 'tools'. The function must match the configured schema."
          }
        }
      }
      return new Response(`event: response.failed\ndata: ${JSON.stringify(event)}\n\n`, {
        headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' }
      })
    }
  })
}

async function waitForContextCompaction(notifications: JSONRPCMessage[], threadID: string): Promise<void> {
  const deadline = Date.now() + 20_000
  while (true) {
    const completed = notifications.some(notification => {
      if (notification.method !== 'item/completed' || !isObject(notification.params)) return false
      return (
        notification.params.threadId === threadID &&
        isObject(notification.params.item) &&
        notification.params.item.type === 'contextCompaction'
      )
    })
    if (completed) return
    if (Date.now() >= deadline) throw new Error('timed out waiting for remote context compaction')
    await Bun.sleep(10)
  }
}

async function waitForTurnTree(
  notifications: JSONRPCMessage[],
  rootThreadID: string,
  rootTurnID: string
): Promise<void> {
  const deadline = Date.now() + 20_000
  while (true) {
    const completed = notifications.filter(notification => notification.method === 'turn/completed')
    const rootCompleted = completed.some(notification => {
      const params = isObject(notification.params) ? notification.params : {}
      const turn = isObject(params.turn) ? params.turn : {}
      return params.threadId === rootThreadID && turn.id === rootTurnID
    })
    const childCompleted = completed.some(notification => notificationThreadID(notification) !== rootThreadID)
    if (rootCompleted && childCompleted) return
    if (Date.now() >= deadline) throw new Error('timed out waiting for the MultiAgentV2 Turn tree')
    await Bun.sleep(10)
  }
}

function notificationThreadID(notification: JSONRPCMessage): string | undefined {
  const params = isObject(notification.params) ? notification.params : {}
  if (typeof params.threadId === 'string') return params.threadId
  const thread = isObject(params.thread) ? params.thread : {}
  return typeof thread.id === 'string' ? thread.id : undefined
}

function createExecOutputResponsesProvider(requests: JSONObject[]) {
  return Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request) {
      const url = new URL(request.url)
      if (request.method === 'GET' && url.pathname === '/v1/models') {
        return Response.json({
          models: [execOutputModelCard('gpt-5.4')]
        })
      }
      if (request.method !== 'POST' || url.pathname !== '/v1/responses') {
        return Response.json({ error: { message: 'not found' } }, { status: 404 })
      }

      const body = (await request.json()) as JSONObject
      requests.push(body)
      const model = typeof body.model === 'string' ? body.model : 'gpt-5.4'

      if (requests.length === 1) {
        return execOutputResponse('exec-output-model-limit-call', model, [
          {
            type: 'custom_tool_call',
            call_id: modelLimitedExecOutputCallID,
            name: 'exec',
            input: execOutputCode(20_000)
          }
        ])
      }

      if (requests.length === 2) {
        return execOutputResponse('exec-output-request-limit-call', model, [
          {
            type: 'custom_tool_call',
            call_id: requestLimitedExecOutputCallID,
            name: 'exec',
            input: execOutputCode(4_000)
          }
        ])
      }

      return execOutputResponse('exec-output-done', model, [
        {
          id: 'exec-output-message',
          type: 'message',
          status: 'completed',
          role: 'assistant',
          content: [{ type: 'output_text', text: 'Output contract checked.', annotations: [] }]
        }
      ])
    }
  })
}

function createHostedWebSearchResponsesProvider(requests: JSONObject[], bindings: JSONObject[]) {
  return Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request, server) {
      const url = new URL(request.url)
      if (request.method === 'GET' && url.pathname === '/v1/models') {
        return Response.json({
          models: [execOutputModelCard('gpt-5.6-sol')]
        })
      }
      if (request.method === 'GET' && url.pathname === '/v1/responses') {
        const encodedBinding = request.headers.get('x-ankole-aigateway-model-binding')
        if (encodedBinding) {
          bindings.push(JSON.parse(Buffer.from(encodedBinding, 'base64url').toString('utf8')) as JSONObject)
        }
        if (server.upgrade(request)) return
      }
      if (request.method !== 'POST' || url.pathname !== '/v1/responses') {
        return Response.json({ error: { message: 'not found' } }, { status: 404 })
      }

      const body = (await request.json()) as JSONObject
      requests.push(body)
      const encodedBinding = request.headers.get('x-ankole-aigateway-model-binding')
      if (encodedBinding) {
        bindings.push(JSON.parse(Buffer.from(encodedBinding, 'base64url').toString('utf8')) as JSONObject)
      }
      return execOutputResponse('hosted-web-search-done', 'gpt-5.6-sol', [
        {
          id: 'hosted-web-search-message',
          type: 'message',
          status: 'completed',
          role: 'assistant',
          content: [{ type: 'output_text', text: 'Hosted web search contract checked.', annotations: [] }]
        }
      ])
    },
    websocket: {
      message(ws, message) {
        const request = JSON.parse(
          typeof message === 'string' ? message : new TextDecoder().decode(message)
        ) as JSONObject
        if (request.generate !== false) requests.push(request)
        const response = {
          id: 'hosted-web-search-done',
          object: 'response',
          created_at: 1_764_967_971,
          completed_at: null,
          status: 'in_progress',
          model: 'gpt-5.6-sol',
          previous_response_id: null,
          output: [],
          usage: null
        }
        const item = {
          id: 'hosted-web-search-message',
          type: 'message',
          status: 'completed',
          role: 'assistant',
          content: [{ type: 'output_text', text: 'Hosted web search contract checked.', annotations: [] }]
        }
        for (const event of [
          { type: 'response.created', sequence_number: 0, response },
          { type: 'response.output_item.done', sequence_number: 1, output_index: 0, item },
          {
            type: 'response.completed',
            sequence_number: 2,
            response: {
              ...response,
              completed_at: 1_764_967_972,
              status: 'completed',
              output: [item],
              usage: {
                input_tokens: 1,
                input_tokens_details: { cached_tokens: 0 },
                output_tokens: 1,
                output_tokens_details: { reasoning_tokens: 0 },
                total_tokens: 2
              }
            }
          }
        ]) {
          ws.send(JSON.stringify(event))
        }
      }
    }
  })
}

function execOutputCode(maxOutputTokens: number): string {
  return [
    'const result = await tools.exec_command({',
    '  cmd: "python3 -c \\"import sys; sys.stdout.write(\' the\' * 30000)\\"",',
    `  max_output_tokens: ${maxOutputTokens}`,
    '});',
    'text(result.output);'
  ].join('\n')
}

function execOutputModelCard(model: string): JSONObject {
  return {
    slug: model,
    display_name: model,
    description: null,
    supported_reasoning_levels: [],
    shell_type: 'default',
    visibility: 'none',
    supported_in_api: true,
    priority: 99,
    availability_nux: null,
    upgrade: null,
    base_instructions:
      '`max_output_tokens` is a requested upper limit. Model-visible tool output is limited to 10000 tokens.',
    default_reasoning_summary: 'auto',
    support_verbosity: false,
    default_verbosity: null,
    apply_patch_tool_type: 'freeform',
    web_search_tool_type: 'text',
    truncation_policy: { mode: 'tokens', limit: 10_000 },
    supports_parallel_tool_calls: false,
    context_window: 272_000,
    max_context_window: 272_000,
    effective_context_window_percent: 95,
    experimental_supported_tools: [],
    input_modalities: ['text'],
    supports_search_tool: true,
    use_responses_lite: false
  }
}

function execOutputResponse(responseID: string, model: string, items: JSONObject[]): Response {
  const response = {
    id: responseID,
    object: 'response',
    created_at: 1_764_967_971,
    completed_at: null,
    status: 'in_progress',
    model,
    previous_response_id: null,
    output: [],
    usage: null
  }
  const events = [
    { type: 'response.created', sequence_number: 0, response },
    ...items.map((item, index) => ({
      type: 'response.output_item.done',
      sequence_number: index + 1,
      output_index: index,
      item
    })),
    {
      type: 'response.completed',
      sequence_number: items.length + 1,
      response: {
        ...response,
        completed_at: 1_764_967_972,
        status: 'completed',
        output: items,
        usage: {
          input_tokens: 1,
          input_tokens_details: { cached_tokens: 0 },
          output_tokens: 1,
          output_tokens_details: { reasoning_tokens: 0 },
          total_tokens: 2
        }
      }
    }
  ]
  return new Response(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(''), {
    headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' }
  })
}

function customToolOutputTexts(request: JSONObject, callID: string): string[] {
  const input = Array.isArray(request.input) ? request.input : []
  const output = input
    .filter(isObject)
    .find(item => item.type === 'custom_tool_call_output' && item.call_id === callID)?.output
  if (typeof output === 'string') return [output]
  if (!Array.isArray(output)) return []
  return output.filter(isObject).flatMap(item => (typeof item.text === 'string' ? [item.text] : []))
}

function createPluginResponsesProvider(requests: JSONObject[]) {
  return Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request) {
      const url = new URL(request.url)
      if (request.method === 'GET' && url.pathname === '/v1/models') {
        return Response.json({
          models: ['gpt-5.4', 'gpt-5.4-mini'].map(model => ({
            slug: model,
            display_name: model,
            description: null,
            supported_reasoning_levels: [],
            shell_type: 'default',
            visibility: 'none',
            supported_in_api: true,
            priority: 99,
            availability_nux: null,
            upgrade: null,
            base_instructions: 'Use selected capabilities from this request.',
            default_reasoning_summary: 'auto',
            support_verbosity: false,
            default_verbosity: null,
            apply_patch_tool_type: 'freeform',
            web_search_tool_type: 'text',
            truncation_policy: { mode: 'tokens', limit: 10_000 },
            supports_parallel_tool_calls: false,
            context_window: 272_000,
            max_context_window: 272_000,
            effective_context_window_percent: 95,
            experimental_supported_tools: [],
            input_modalities: ['text'],
            supports_search_tool: true,
            use_responses_lite: false
          }))
        })
      }
      if (request.method !== 'POST' || url.pathname !== '/v1/responses') {
        return Response.json({ error: { message: 'not found' } }, { status: 404 })
      }

      const body = (await request.json()) as JSONObject
      requests.push(body)
      const responseModel = typeof body.model === 'string' ? body.model : 'gpt-5.4'
      const responseID = `plugin-response-${requests.length}`
      const message = {
        id: `plugin-message-${requests.length}`,
        type: 'message',
        status: 'completed',
        role: 'assistant',
        content: [{ type: 'output_text', text: 'Selected Plugin checked.', annotations: [] }]
      }
      const response = {
        id: responseID,
        object: 'response',
        created_at: 1_764_967_971,
        completed_at: null,
        status: 'in_progress',
        model: responseModel,
        previous_response_id: null,
        output: [],
        usage: null
      }
      const events = [
        { type: 'response.created', sequence_number: 0, response },
        { type: 'response.output_item.done', sequence_number: 1, output_index: 0, item: message },
        {
          type: 'response.completed',
          sequence_number: 2,
          response: {
            ...response,
            completed_at: 1_764_967_972,
            status: 'completed',
            output: [message],
            usage: {
              input_tokens: 1,
              input_tokens_details: { cached_tokens: 0 },
              output_tokens: 1,
              output_tokens_details: { reasoning_tokens: 0 },
              total_tokens: 2
            }
          }
        }
      ]
      return new Response(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(''), {
        headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' }
      })
    }
  })
}

async function waitForPluginTurn(notifications: JSONRPCMessage[], turnID: string): Promise<void> {
  const deadline = Date.now() + 20_000
  while (!pluginTurnCompleted(notifications, turnID)) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for Plugin turn ${turnID}`)
    await Bun.sleep(10)
  }
}

async function waitForTerminalTurn(notifications: JSONRPCMessage[], turnID: string): Promise<JSONRPCMessage> {
  const deadline = Date.now() + 20_000
  while (true) {
    const completed = notifications.find(notification => {
      if (notification.method !== 'turn/completed' || !isObject(notification.params)) return false
      const turn = notification.params.turn
      return isObject(turn) && turn.id === turnID
    })
    if (completed) return completed
    if (Date.now() >= deadline) throw new Error(`timed out waiting for terminal Turn ${turnID}`)
    await Bun.sleep(10)
  }
}

async function pluginStage<T>(promise: Promise<T>, label: string): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_resolve, reject) => {
        timeout = setTimeout(() => reject(new Error(`timed out during ${label}`)), 20_000)
      })
    ])
  } finally {
    if (timeout) clearTimeout(timeout)
  }
}

function pluginTurnCompleted(notifications: JSONRPCMessage[], turnID: string): boolean {
  return notifications.some(notification => {
    if (notification.method !== 'turn/completed' || !isObject(notification.params)) return false
    const turn = notification.params.turn
    return isObject(turn) && turn.id === turnID && turn.status === 'completed'
  })
}

function isObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === 'object' && !Array.isArray(value))
}

function appendOptionalMCPFixtures(projectRoot: string): void {
  appendFileSync(
    join(projectRoot, '.codex', 'config.toml'),
    [
      '',
      '[mcp_servers.native-fixture]',
      'command = "bun"',
      'args = ["/repo/app/agent_computer/test/fixtures/mcp-stdio-server.ts"]',
      'cwd = "/repo/app/agent_computer"',
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

function protocolFiles(root: string): string[] {
  return readdirSync(root, { recursive: true, withFileTypes: true })
    .filter(entry => entry.isFile() && entry.name.endsWith('.ts'))
    .map(entry => relative(root, join(entry.parentPath, entry.name)))
    .sort()
}
