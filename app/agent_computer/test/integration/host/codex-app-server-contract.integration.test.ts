import { mkdirAgentSync } from '../../../src/common/agent-user'
import { resetCodexAgentRuntimeConfig } from '../../support/codex-runtime-config'
import { TOML } from 'bun'
import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { isRecord, type JsonObject as JSONObject } from '@agentbull/active-support'
import { estimateO200kBaseTokens } from '../../../../kernel/test/node/o200k-base-tokens'
import {
  AIGatewayAPIKeyResponseSchema,
  AgentPluginCatalogEntrySchema
} from '../../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { CodexAppServerClient, type JSONRPCMessage } from '../../../src/core/codex-runner/runtime/app-server-client'
import type { ThreadStartResponse } from '../../../src/core/codex-runner/generated/protocol/v2/ThreadStartResponse'
import { refreshCodexAgentRuntimeCredential } from '../../../src/core/codex-runner/runtime/agent-home-config'
import {
  materializeCodexJobProjectConfig,
  readCodexJobProjectConfig
} from '../../../src/core/codex-runner/job/project-config'
import { codexJobThreadConfig } from '../../../src/core/codex-runner/job/thread-config'
import {
  materializeAgentPluginPackages,
  prepareAgentPlugins
} from '../../../src/core/codex-runner/runtime/agent-plugin-materializer'
import {
  AgentCodexRuntime,
  type AgentCodexRuntimeSession
} from '../../../src/core/codex-runner/runtime/agent-runtime-manager'
import type { CodexRuntimeConfig } from '../../../src/core/codex-runner/runtime-config'
import { errorMessage } from '../../../src/common/errors'

describe('@ankole/agent-computer Codex app-server protocol contract', () => {
  it('does not retry a canonical Provider validation failure', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-invalid-prompt-'))
    mkdirAgentSync(root, 0o700)
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requests: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createInvalidPromptResponsesProvider(requests)
    if (typeof provider.port !== 'number') throw new Error('Invalid prompt provider did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirAgentSync(workspace)
      mkdirAgentSync(codexHome)
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
      const completedTurn = isRecord(completed.params) && isRecord(completed.params.turn) ? completed.params.turn : {}

      expect(completedTurn.status).toBe('failed')
      expect(requests).toHaveLength(1)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)

  it('uses compaction_trigger when the frozen ChatGPT Subscription projection enables v2', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-remote-compaction-'))
    mkdirAgentSync(root, 0o700)
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requestPaths: string[] = []
    const requests: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createRemoteCompactionResponsesProvider(requestPaths, requests)
    if (typeof provider.port !== 'number') throw new Error('Remote compaction provider did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirAgentSync(workspace)
      mkdirAgentSync(codexHome)
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
    mkdirAgentSync(root, 0o700)
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requests: JSONObject[] = []
    const bindings: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createHostedWebSearchResponsesProvider(requests, bindings)
    if (typeof provider.port !== 'number') throw new Error('Hosted web search provider did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirAgentSync(workspace)
      mkdirAgentSync(codexHome)
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
      expect(bindings.length).toBeGreaterThan(0)
      const configuredBinding = config.model_providers.ankole_aigateway.http_headers[
        'x-ankole-aigateway-model-binding'
      ] as string
      const expectedBinding = JSON.parse(Buffer.from(configuredBinding, 'base64url').toString('utf8'))
      for (const binding of bindings) expect(binding).toEqual(expectedBinding)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)

  it('routes MultiAgentV2 children from sub-agent activity and exposes their raw tool calls', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-multi-agent-v2-'))
    mkdirAgentSync(root, 0o700)
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
      mkdirAgentSync(workspace)
      mkdirAgentSync(codexHome)
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
        const params = isRecord(notification.params) ? notification.params : {}
        const item = isRecord(params.item) ? params.item : {}
        return item.type === 'subAgentActivity' && item.kind === 'started'
      })
      const activityItem = isRecord(activity?.params) && isRecord(activity.params.item) ? activity.params.item : {}
      const childThreadID = typeof activityItem.agentThreadId === 'string' ? activityItem.agentThreadId : ''
      expect(childThreadID).not.toBe('')
      expect(
        allNotifications.some(notification => {
          const params = isRecord(notification.params) ? notification.params : {}
          const startedThread = isRecord(params.thread) ? params.thread : {}
          return notification.method === 'thread/started' && startedThread.id === childThreadID
        })
      ).toBe(false)
      expect(owner.notifications.some(notification => notificationThreadID(notification) === childThreadID)).toBe(true)
      const rawSpawn = allNotifications.find(notification => {
        const params = isRecord(notification.params) ? notification.params : {}
        const item = isRecord(params.item) ? params.item : {}
        return (
          notification.method === 'rawResponseItem/completed' &&
          item.type === 'function_call' &&
          item.name === 'spawn_agent'
        )
      })
      const rawSpawnItem = isRecord(rawSpawn?.params) && isRecord(rawSpawn.params.item) ? rawSpawn.params.item : {}
      expect(rawSpawnItem.namespace).toBe('collaboration')
      expect(rawSpawnItem.call_id).toBe(activityItem.id)
    } catch (error) {
      const stderr = allNotifications
        .filter(notification => notification.method === '$stderr' && isRecord(notification.params))
        .flatMap(notification =>
          isRecord(notification.params) && typeof notification.params.text === 'string'
            ? [notification.params.text]
            : []
        )
        .join('')
      throw new Error(`${errorMessage(error)}\nrequests=${requestKinds.join(',')}\n${stderr}`)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)

  it('applies request and model limits to model-visible code-mode output', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-exec-output-'))
    mkdirAgentSync(root, 0o700)
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requests: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createExecOutputResponsesProvider(requests)
    if (typeof provider.port !== 'number') throw new Error('Exec output provider did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirAgentSync(workspace)
      mkdirAgentSync(codexHome)
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
        .filter(notification => notification.method === '$stderr' && isRecord(notification.params))
        .flatMap(notification =>
          isRecord(notification.params) && typeof notification.params.text === 'string'
            ? [notification.params.text]
            : []
        )
        .join('')
      throw new Error(`${errorMessage(error)}\n${stderr}`)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)

  it('officially installs Agent-owned Plugins and keeps them globally disabled', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-agent-plugin-runtime-'))
    mkdirAgentSync(root, 0o700)
    const libraryRoot = join(root, 'library')
    const agentHome = join(root, 'agent-home')
    const codexHome = join(agentHome, '.codex')
    const alphaProject = join(agentHome, 'jobs', 'alpha')
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
      mkdirAgentSync(codexHome)
      const catalog = [
        create(AgentPluginCatalogEntrySchema, {
          id: 'alpha',
          skills: [{ catalogName: 'alpha-skill' }, { catalogName: 'alpha-extra' }]
        }),
        create(AgentPluginCatalogEntrySchema, {
          id: 'beta',
          skills: [{ catalogName: 'beta-skill' }]
        })
      ]
      const prepared = prepareAgentPlugins({
        projectRoot: alphaProject,
        agentPlugins: catalog,
        codexHome,
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
        runtimeOwner.ensureAgentPlugins(prepared),
        'official Plugin install, Hook trust, and global disable'
      )

      const config = TOML.parse(readFileSync(join(codexHome, 'config.toml'), 'utf8')) as Record<string, any>
      expect(config.plugins['alpha@ankole-agent-runtime'].enabled).toBe(false)
      expect(config.plugins['beta@ankole-agent-runtime'].enabled).toBe(false)
      expect(Object.keys(config.hooks.state)).not.toHaveLength(0)
    } catch (error) {
      const stderr = notifications
        .filter(notification => notification.method === '$stderr' && isRecord(notification.params))
        .flatMap(notification =>
          isRecord(notification.params) && typeof notification.params.text === 'string'
            ? [notification.params.text]
            : []
        )
        .join('')
      throw new Error(`${errorMessage(error)}\n${stderr}`)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 90_000)

  it('names a same-name Plugin marketplace that an older Worker left in HOME', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-agent-plugin-shadow-'))
    mkdirAgentSync(root, 0o700)
    const libraryRoot = join(root, 'library')
    const agentHome = join(root, 'agent-home')
    const codexHome = join(root, 'codex-home')
    const legacyMarketplacePath = join(agentHome, '.agents', 'plugins', 'marketplace.json')
    let client: CodexAppServerClient | undefined

    try {
      createAgentPluginFixture(libraryRoot, 'alpha', 'ALPHA_SELECTED_BODY', false)
      // The layout that Workers before 1.6.8-rc.1 wrote to the Agent Home.
      createAgentPluginFixture(
        join(agentHome, 'runtime-materials', 'agent-plugins', 'plugins'),
        'alpha',
        'ALPHA_LEGACY_BODY',
        false
      )
      mkdirAgentSync(join(agentHome, '.agents', 'plugins'))
      writeFileSync(
        legacyMarketplacePath,
        JSON.stringify({
          name: 'ankole-agent-runtime',
          plugins: [
            {
              name: 'alpha',
              source: { source: 'local', path: './runtime-materials/agent-plugins/plugins/alpha' },
              policy: { installation: 'AVAILABLE', authentication: 'ON_INSTALL' },
              category: 'Developer Tools'
            }
          ]
        })
      )
      mkdirAgentSync(codexHome)
      const prepared = prepareAgentPlugins({
        projectRoot: join(agentHome, 'jobs', 'alpha'),
        agentPlugins: [
          create(AgentPluginCatalogEntrySchema, {
            id: 'alpha',
            skills: [{ catalogName: 'alpha-skill' }]
          })
        ],
        codexHome,
        libraryRoot,
        initializeProject: false
      })
      resetCodexAgentRuntimeConfig(codexHome, 'http://127.0.0.1:9/v1')
      refreshCodexAgentRuntimeCredential(codexHome, 'contract-key')
      client = new CodexAppServerClient({
        cwd: agentHome,
        env: {
          PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
          HOME: agentHome,
          CODEX_HOME: codexHome,
          CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
          LANG: 'C.UTF-8'
        }
      })
      await client.initialize()

      await expect(new AgentCodexRuntime('agent-1', client).ensureAgentPlugins(prepared)).rejects.toThrow(
        `Codex also discovers the ankole-agent-runtime Plugin marketplace at ${legacyMarketplacePath}.`
      )
      expect(existsSync(legacyMarketplacePath)).toBe(true)
    } finally {
      await client?.close()
      rmSync(root, { recursive: true, force: true })
    }
  }, 90_000)

  it('starts the same Agent on two Worker processes through Plugin install and the first Turn', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-plugin-worker-processes-'))
    mkdirAgentSync(root, 0o700)
    const requests: JSONObject[] = []
    const provider = createPluginResponsesProvider(requests)
    const baseURL = `http://127.0.0.1:${provider.port}/v1`
    const processes: Array<Bun.Subprocess<'ignore', 'pipe', 'pipe'>> = []
    try {
      createAgentPluginFixture(join(root, 'library'), 'alpha', 'ALPHA_BODY', true)
      for (const worker of ['a', 'b']) {
        const codexHome = join(root, worker, 'codex-home')
        const cwd = join(root, 'shared-agent-home', 'jobs', worker)
        const config = codexJobThreadConfig({ cwd, codexHome, env: {}, runtime: pluginTestRuntime(baseURL) }) as Record<
          string,
          any
        >
        config.model_providers.ankole_aigateway.supports_websockets = false
        const inputPath = join(root, `${worker}.json`)
        writeFileSync(inputPath, JSON.stringify({ root, worker, baseURL, config }))
        processes.push(
          Bun.spawn(['bun', join(import.meta.dir, '../../fixtures/plugin-worker-runtime.ts'), inputPath], {
            stdin: 'ignore',
            stdout: 'pipe',
            stderr: 'pipe'
          })
        )
      }
      await pluginStage(
        (async () => {
          while (!['a', 'b'].every(worker => existsSync(join(root, `ready-${worker}`)))) await Bun.sleep(10)
        })(),
        'both Worker processes ready'
      )
      writeFileSync(join(root, 'start'), '')
      const results = await Promise.all(
        processes.map(async proc => {
          const [code, stdout, stderr] = await Promise.all([
            proc.exited,
            new Response(proc.stdout).text(),
            new Response(proc.stderr).text()
          ])
          if (code !== 0) throw new Error(`Worker exited ${code}: ${stderr}`)
          return JSON.parse(stdout) as { marketplacePath: string; threadId: string }
        })
      )
      expect(new Set(results.map(result => result.marketplacePath)).size).toBe(2)
      expect(new Set(results.map(result => result.threadId)).size).toBe(2)
      expect(requests).toHaveLength(2)
      expect(existsSync(join(root, 'shared-agent-home', 'runtime-materials'))).toBe(false)
    } finally {
      for (const proc of processes) proc.kill()
      await Promise.all(processes.map(proc => proc.exited))
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 90_000)
})

function createAgentPluginFixture(libraryRoot: string, id: string, bodyMarker: string, withHook: boolean): void {
  const pluginRoot = join(libraryRoot, id)
  mkdirAgentSync(join(pluginRoot, '.codex-plugin'))
  mkdirAgentSync(join(pluginRoot, 'skills', `${id}-skill`))
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
    mkdirAgentSync(join(pluginRoot, 'hooks'))
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
  mkdirAgentSync(skillRoot)
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
        if (input.some(item => isRecord(item) && item.type === 'compaction_trigger')) {
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
    const completed = notifications.find(notification => {
      if (notification.method !== 'item/completed' || !isRecord(notification.params)) return false
      return (
        notification.params.threadId === threadID &&
        isRecord(notification.params.item) &&
        notification.params.item.type === 'contextCompaction'
      )
    })
    if (completed && isRecord(completed.params) && typeof completed.params.turnId === 'string') {
      await waitForPluginTurn(notifications, completed.params.turnId)
      return
    }
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
      const params = isRecord(notification.params) ? notification.params : {}
      const turn = isRecord(params.turn) ? params.turn : {}
      return params.threadId === rootThreadID && turn.id === rootTurnID
    })
    const childCompleted = completed.some(notification => notificationThreadID(notification) !== rootThreadID)
    if (rootCompleted && childCompleted) return
    if (Date.now() >= deadline) throw new Error('timed out waiting for the MultiAgentV2 Turn tree')
    await Bun.sleep(10)
  }
}

function notificationThreadID(notification: JSONRPCMessage): string | undefined {
  const params = isRecord(notification.params) ? notification.params : {}
  if (typeof params.threadId === 'string') return params.threadId
  const thread = isRecord(params.thread) ? params.thread : {}
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
    shell_type: 'unified_exec',
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
    .filter(isRecord)
    .find(item => item.type === 'custom_tool_call_output' && item.call_id === callID)?.output
  if (typeof output === 'string') return [output]
  if (!Array.isArray(output)) return []
  return output.filter(isRecord).flatMap(item => (typeof item.text === 'string' ? [item.text] : []))
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
            shell_type: 'unified_exec',
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
      if (notification.method !== 'turn/completed' || !isRecord(notification.params)) return false
      const turn = notification.params.turn
      return isRecord(turn) && turn.id === turnID
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
    if (notification.method !== 'turn/completed' || !isRecord(notification.params)) return false
    const turn = notification.params.turn
    return isRecord(turn) && turn.id === turnID && turn.status === 'completed'
  })
}
