import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { AgentPluginCatalogEntrySchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { CodexAppServerClient, JSONRPCMessage } from '../src/core/codex-runner/app-server-client'
import type { CodexAppServerSandboxSpec } from '../src/core/codex-runner/sandbox'
import { prepareAgentPlugins } from '../src/core/codex-runner/agent-plugin-materializer'
import { codexAIGatewayTokenPath } from '../src/core/codex-runner/agent-home-config'
import { codexHomeLockedCommandArgv } from '../src/core/codex-runner/codex-home-lock'
import {
  AgentCodexRuntime,
  AgentCodexRuntimeManager,
  type AgentCodexRuntimeLostError,
  type AgentCodexRuntimeSession
} from '../src/core/codex-runner/agent-runtime-manager'

describe('@ankole/agent-computer Agent Codex runtime manager', () => {
  it('single-flights one process per Agent and closes it at the last lease', async () => {
    const fixture = runtimeFixture()
    const manager = new AgentCodexRuntimeManager()
    try {
      const [first, second] = await Promise.all([
        manager.acquire({
          agentUID: 'agent-1',
          agentHome: fixture.agentHome,
          codexHome: fixture.codexHome,
          aiGatewayBaseURL: 'http://control.test/api/v1/ai-gateway',
          aiGatewayAPIKey: 'initial-agent-token',
          sandbox: fixture.sandbox
        }),
        manager.acquire({
          agentUID: 'agent-1',
          agentHome: fixture.agentHome,
          codexHome: fixture.codexHome,
          aiGatewayBaseURL: 'http://control.test/api/v1/ai-gateway',
          aiGatewayAPIKey: 'initial-agent-token',
          sandbox: fixture.sandbox
        })
      ])
      expect(first.runtime.client.processID).toBeDefined()
      expect(second.runtime.client.processID).toBe(first.runtime.client.processID)
      expect(manager.activeRuntimeCount('agent-1')).toBe(1)
      expect(fixture.sandbox.env.ANKOLE_AIGATEWAY_API_KEY).toBeUndefined()

      const refreshed = await manager.acquire({
        agentUID: 'agent-1',
        agentHome: fixture.agentHome,
        codexHome: fixture.codexHome,
        aiGatewayBaseURL: 'http://control.test/api/v1/ai-gateway',
        aiGatewayAPIKey: 'refreshed-agent-token',
        sandbox: fixture.sandbox
      })
      expect(refreshed.runtime.client.processID).toBe(first.runtime.client.processID)
      expect(readFileSync(codexAIGatewayTokenPath(fixture.codexHome), 'utf8')).toBe('refreshed-agent-token\n')
      await refreshed.release()

      await first.release()
      expect(manager.activeRuntimeCount('agent-1')).toBe(1)
      await second.release()
      expect(manager.activeRuntimeCount('agent-1')).toBe(0)
    } finally {
      fixture.cleanup()
    }
  })

  it('lets one startup waiter cancel without killing another waiter', async () => {
    const fixture = runtimeFixture({ initializeDelayMs: 100 })
    const manager = new AgentCodexRuntimeManager()
    const controller = new AbortController()
    try {
      const cancelled = manager.acquire({
        agentUID: 'agent-1',
        agentHome: fixture.agentHome,
        codexHome: fixture.codexHome,
        aiGatewayBaseURL: 'http://control.test/api/v1/ai-gateway',
        aiGatewayAPIKey: 'agent-token',
        sandbox: fixture.sandbox,
        abortSignal: controller.signal
      })
      const retained = manager.acquire({
        agentUID: 'agent-1',
        agentHome: fixture.agentHome,
        codexHome: fixture.codexHome,
        aiGatewayBaseURL: 'http://control.test/api/v1/ai-gateway',
        aiGatewayAPIKey: 'agent-token',
        sandbox: fixture.sandbox
      })
      await waitForFile(fixture.initializeMarker)
      controller.abort(new Error('first waiter cancelled'))

      await expect(cancelled).rejects.toThrow('first waiter cancelled')
      const lease = await retained
      expect(manager.activeRuntimeCount('agent-1')).toBe(1)
      await lease.release()
      expect(manager.activeRuntimeCount('agent-1')).toBe(0)
    } finally {
      fixture.cleanup()
    }
  })

  it('does not replace active runtime files before it owns the physical lock', async () => {
    const fixture = runtimeFixture()
    const manager = new AgentCodexRuntimeManager()
    const ready = join(fixture.codexHome, 'holder-ready')
    const release = join(fixture.codexHome, 'holder-release')
    const configPath = join(fixture.codexHome, 'config.toml')
    const tokenPath = codexAIGatewayTokenPath(fixture.codexHome)
    writeFileSync(configPath, 'active-config\n')
    writeFileSync(tokenPath, 'active-token\n')
    const holder = Bun.spawn(
      codexHomeLockedCommandArgv({
        codexHome: fixture.codexHome,
        commandArgv: [
          '/bin/sh',
          '-c',
          'touch "$1"; while [ ! -e "$2" ]; do sleep 0.02; done',
          'ankole-runtime-holder',
          ready,
          release
        ]
      })
    )

    try {
      await waitForFile(ready)
      await expect(
        manager.acquire({
          agentUID: 'agent-1',
          agentHome: fixture.agentHome,
          codexHome: fixture.codexHome,
          aiGatewayBaseURL: 'http://replacement.test/api/v1/ai-gateway',
          aiGatewayAPIKey: 'replacement-token',
          sandbox: fixture.sandbox
        })
      ).rejects.toMatchObject({ code: 'agent_codex_runtime_busy', retryable: true })

      expect(readFileSync(configPath, 'utf8')).toBe('active-config\n')
      expect(readFileSync(tokenPath, 'utf8')).toBe('active-token\n')
    } finally {
      writeFileSync(release, 'release')
      await holder.exited
      fixture.cleanup()
    }
  })

  it('keeps three Job trees isolated and fans one process loss to the remaining owners', async () => {
    const fixture = runtimeFixture()
    const manager = new AgentCodexRuntimeManager()
    try {
      const [first, second, third] = await Promise.all([
        manager.acquire({
          agentUID: 'agent-1',
          agentHome: fixture.agentHome,
          codexHome: fixture.codexHome,
          aiGatewayBaseURL: 'http://control.test/api/v1/ai-gateway',
          aiGatewayAPIKey: 'agent-token',
          sandbox: fixture.sandbox
        }),
        manager.acquire({
          agentUID: 'agent-1',
          agentHome: fixture.agentHome,
          codexHome: fixture.codexHome,
          aiGatewayBaseURL: 'http://control.test/api/v1/ai-gateway',
          aiGatewayAPIKey: 'agent-token',
          sandbox: fixture.sandbox
        }),
        manager.acquire({
          agentUID: 'agent-1',
          agentHome: fixture.agentHome,
          codexHome: fixture.codexHome,
          aiGatewayBaseURL: 'http://control.test/api/v1/ai-gateway',
          aiGatewayAPIKey: 'agent-token',
          sandbox: fixture.sandbox
        })
      ])
      const firstPID = first.runtime.client.processID
      expect(second.runtime.client.processID).toBe(firstPID)
      expect(third.runtime.client.processID).toBe(firstPID)
      const firstSession = session()
      const secondSession = session()
      const thirdSession = session()
      await first.runtime.registerRoot('thread-1', firstSession)
      await second.runtime.registerRoot('thread-2', secondSession)
      await third.runtime.registerRoot('thread-3', thirdSession)

      await first.runtime.cleanupSession(firstSession)
      await first.release()
      second.runtime.routeNotification({
        method: 'turn/completed',
        params: { threadId: 'thread-2', turn: { id: 'turn-2' } }
      })
      third.runtime.routeNotification({
        method: 'turn/completed',
        params: { threadId: 'thread-3', turn: { id: 'turn-3' } }
      })
      expect(firstSession.notifications).toEqual([])
      expect(secondSession.notifications.at(-1)?.method).toBe('turn/completed')
      expect(thirdSession.notifications.at(-1)?.method).toBe('turn/completed')
      expect(manager.activeRuntimeCount('agent-1')).toBe(1)

      await expect(second.runtime.client.request('test/exit', {})).rejects.toThrow('exited with code 43')
      await waitUntil(() => secondSession.lost.length === 1 && thirdSession.lost.length === 1)
      expect(firstSession.lost).toEqual([])
      expect(secondSession.lost[0]).toMatchObject({ code: 'runtime_lost', retryable: true })
      expect(thirdSession.lost[0]).toBe(secondSession.lost[0])
      expect(manager.activeRuntimeCount('agent-1')).toBe(0)

      await Promise.all([second.release(), third.release()])
      const replacement = await manager.acquire({
        agentUID: 'agent-1',
        agentHome: fixture.agentHome,
        codexHome: fixture.codexHome,
        aiGatewayBaseURL: 'http://control.test/api/v1/ai-gateway',
        aiGatewayAPIKey: 'replacement-agent-token',
        sandbox: fixture.sandbox
      })
      expect(replacement.runtime.client.processID).not.toBe(firstPID)
      await replacement.release()
    } finally {
      fixture.cleanup()
    }
  })

  it('serializes official Plugin installation, Hook trust, and global disable before any Job thread', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-runtime-plugins-'))
    const libraryRoot = join(root, 'library')
    const agentHome = join(root, 'agent-home')
    const pluginRoot = join(libraryRoot, 'alpha')
    mkdirSync(join(pluginRoot, '.codex-plugin'), { recursive: true })
    mkdirSync(join(pluginRoot, 'skills', 'alpha-skill'), { recursive: true })
    mkdirSync(join(pluginRoot, 'hooks'), { recursive: true })
    writeFileSync(
      join(pluginRoot, '.codex-plugin', 'plugin.json'),
      JSON.stringify({ name: 'alpha', version: '1.0.0', description: 'alpha Plugin', skills: './skills/' })
    )
    writeFileSync(
      join(pluginRoot, 'skills', 'alpha-skill', 'SKILL.md'),
      '---\nname: alpha-skill\ndescription: alpha Skill\n---\n'
    )
    writeFileSync(
      join(pluginRoot, 'hooks', 'hooks.json'),
      JSON.stringify({ hooks: { SessionStart: [{ hooks: [{ type: 'command', command: '/bin/true' }] }] } })
    )
    const prepared = prepareAgentPlugins({
      projectRoot: join(agentHome, 'jobs', '1000'),
      agentPlugins: [
        create(AgentPluginCatalogEntrySchema, {
          id: 'alpha',
          description: 'alpha Plugin',
          skills: [{ catalogName: 'alpha-skill' }]
        })
      ],
      agentHome,
      libraryRoot,
      initializeProject: false
    })
    const calls: string[] = []
    let installed = false
    let enabled = false
    let hookTrusted = false
    const fakeClient = {
      async request(method: string, params: Record<string, any>) {
        if (method === 'config/batchWrite') {
          const keyPath = params.edits[0].keyPath as string
          calls.push(`config:${keyPath}`)
          if (keyPath === 'hooks.state') hookTrusted = true
          if (keyPath === 'plugins') enabled = false
          return {}
        }
        calls.push(method)
        if (method === 'plugin/install') {
          installed = true
          enabled = true
          return {}
        }
        if (method === 'plugin/installed') {
          return {
            marketplaces: [
              {
                name: 'ankole-agent-runtime',
                plugins: [{ name: 'alpha', installed, enabled }]
              }
            ]
          }
        }
        if (method === 'hooks/list') {
          return {
            data: [
              {
                cwd: agentHome,
                hooks: [
                  {
                    pluginId: 'alpha@ankole-agent-runtime',
                    key: 'alpha-session-start',
                    currentHash: 'alpha-hook-hash',
                    trustStatus: hookTrusted ? 'trusted' : 'untrusted'
                  }
                ]
              }
            ]
          }
        }
        return {}
      },
      async closeAndWait() {}
    } as unknown as CodexAppServerClient
    const runtime = new AgentCodexRuntime('agent-1', fakeClient)

    try {
      await Promise.all([
        runtime.ensureAgentPlugins({ cwd: agentHome, prepared }),
        runtime.ensureAgentPlugins({ cwd: agentHome, prepared })
      ])
      expect(calls).toEqual([
        'config:features.plugins',
        'plugin/install',
        'plugin/installed',
        'hooks/list',
        'config:hooks.state',
        'hooks/list',
        'config:plugins',
        'plugin/installed'
      ])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

describe('@ankole/agent-computer Agent Codex thread router', () => {
  it('keeps a bounded redacted stderr diagnostic for unscoped runtime failures', () => {
    const records: Array<Record<string, unknown> | undefined> = []
    const fakeClient = { async closeAndWait() {} } as unknown as CodexAppServerClient
    const runtime = new AgentCodexRuntime('agent-1', fakeClient, {
      info(_event, _message, fields) {
        records.push(fields)
      },
      warning() {}
    })

    runtime.routeNotification({
      method: '$stderr',
      params: {
        text: `startup failed Authorization: Bearer sk-${'c'.repeat(24)} token=top-secret bx_mcp_${'a'.repeat(60)} ${'b'.repeat(60)}`
      }
    })

    expect(records).toEqual([
      {
        agent_uid: 'agent-1',
        method: '$stderr',
        diagnostic: 'startup failed Authorization: [REDACTED] token=[REDACTED] [REDACTED] [REDACTED]'
      }
    ])
  })

  it('buffers start races, inherits child ownership, fails unknown requests closed, and cleans one Job tree', async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = []
    const responses: Array<{ id: string | number; code: number; message: string }> = []
    const fakeClient = {
      async request(method: string, params: Record<string, unknown>) {
        calls.push({ method, params })
        if (method === 'thread/backgroundTerminals/list') {
          return { data: [{ processId: `${params.threadId}-process` }], nextCursor: null }
        }
        return {}
      },
      async respondError(id: string | number, code: number, message: string) {
        responses.push({ id, code, message })
      },
      async closeAndWait() {}
    } as unknown as CodexAppServerClient
    const runtime = new AgentCodexRuntime('agent-1', fakeClient)
    const first = session()
    const second = session()

    runtime.routeNotification({ method: 'mcpServer/startupStatus/updated', params: { threadId: 'root-1' } })
    await runtime.registerRoot('root-1', first)
    await runtime.registerRoot('root-2', second)
    expect(first.notifications.map(message => message.method)).toEqual(['mcpServer/startupStatus/updated'])

    runtime.routeNotification({
      method: 'turn/started',
      params: { threadId: 'child-1', turn: { id: 'child-turn' } }
    })
    runtime.routeNotification({
      method: 'item/completed',
      params: {
        threadId: 'root-1',
        turnId: 'root-turn',
        item: {
          type: 'subAgentActivity',
          id: 'spawn-child-1',
          kind: 'started',
          agentThreadId: 'child-1',
          agentPath: '/root/child-1'
        }
      }
    })
    runtime.routeNotification({ method: 'turn/started', params: { threadId: 'root-1', turn: { id: 'root-turn' } } })
    runtime.routeNotification({ method: 'turn/started', params: { threadId: 'root-2', turn: { id: 'other-turn' } } })
    expect(first.notifications.some(message => messageMethodThread(message) === 'turn/started:child-1')).toBe(true)
    expect(second.notifications.some(message => messageMethodThread(message) === 'turn/started:child-1')).toBe(false)

    await runtime.routeServerRequest({ id: 9, method: 'item/tool/call', params: { threadId: 'unknown' } }, fakeClient)
    expect(responses).toEqual([{ id: 9, code: -32602, message: 'Codex server request has no owned Job thread' }])

    let settleRequest = (): void => undefined
    const requestSettled = new Promise<void>(resolve => {
      settleRequest = resolve
    })
    first.onCleanup = settleRequest
    first.onRequest = () => requestSettled
    const pending = runtime.routeServerRequest(
      { id: 10, method: 'item/tool/call', params: { threadId: 'child-1' } },
      fakeClient
    )
    await Promise.resolve()
    await runtime.cleanupSession(first)
    await pending

    expect(first.preparedForCleanup).toBe(true)
    expect(calls.map(call => `${call.method}:${call.params.threadId ?? ''}`)).toEqual([
      'turn/interrupt:child-1',
      'thread/backgroundTerminals/list:child-1',
      'thread/backgroundTerminals/terminate:child-1',
      'thread/backgroundTerminals/clean:child-1',
      'thread/unsubscribe:child-1',
      'turn/interrupt:root-1',
      'thread/backgroundTerminals/list:root-1',
      'thread/backgroundTerminals/terminate:root-1',
      'thread/backgroundTerminals/clean:root-1',
      'thread/unsubscribe:root-1'
    ])

    runtime.routeNotification({ method: 'turn/completed', params: { threadId: 'root-2', turn: { id: 'other-turn' } } })
    expect(second.notifications.at(-1)?.method).toBe('turn/completed')
  })

  it('keeps the Job open until every routed child Turn is terminal', async () => {
    const fakeClient = {
      async request() {
        return {}
      },
      async closeAndWait() {}
    } as unknown as CodexAppServerClient
    const runtime = new AgentCodexRuntime('agent-1', fakeClient)
    const owner = session()
    await runtime.registerRoot('root-1', owner)

    runtime.routeNotification({
      method: 'turn/started',
      params: { threadId: 'child-1', turn: { id: 'child-turn' } }
    })
    runtime.routeNotification({
      method: 'item/completed',
      params: {
        threadId: 'root-1',
        turnId: 'root-turn',
        item: {
          type: 'subAgentActivity',
          id: 'spawn-child-1',
          kind: 'started',
          agentThreadId: 'child-1',
          agentPath: '/root/child-1'
        }
      }
    })
    runtime.routeNotification({
      method: 'turn/started',
      params: { threadId: 'child-2', turn: { id: 'child-turn-2' } }
    })
    runtime.routeNotification({
      method: 'item/completed',
      params: {
        threadId: 'root-1',
        turnId: 'root-turn',
        item: {
          type: 'subAgentActivity',
          id: 'spawn-child-2',
          kind: 'started',
          agentThreadId: 'child-2',
          agentPath: '/root/child-2'
        }
      }
    })

    let idle = false
    const waiting = runtime.waitForSessionTurnsIdle(owner).then(() => {
      idle = true
    })
    await Promise.resolve()
    expect(idle).toBe(false)

    runtime.routeNotification({
      method: 'turn/completed',
      params: { threadId: 'child-1', turn: { id: 'child-turn', status: 'completed' } }
    })
    await Promise.resolve()
    expect(idle).toBe(false)

    runtime.routeNotification({
      method: 'turn/completed',
      params: { threadId: 'child-2', turn: { id: 'child-turn-2', status: 'completed' } }
    })
    await waiting

    expect(idle).toBe(true)
    expect(owner.notifications.map(messageMethodThread)).toEqual(
      expect.arrayContaining(['turn/completed:child-1', 'turn/completed:child-2'])
    )
  })

  it('cleans a child thread that starts while its Job tree is being removed', async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = []
    let injected = false
    const fakeClient = {
      async request(method: string, params: Record<string, unknown>) {
        calls.push({ method, params })
        if (method === 'thread/backgroundTerminals/list') {
          if (params.threadId === 'root-1' && !injected) {
            injected = true
            runtime.routeNotification({
              method: 'item/completed',
              params: {
                threadId: 'root-1',
                turnId: 'root-turn',
                item: {
                  type: 'subAgentActivity',
                  id: 'spawn-late-child',
                  kind: 'started',
                  agentThreadId: 'late-child',
                  agentPath: '/root/late-child'
                }
              }
            })
          }
          return { data: [], nextCursor: null }
        }
        return {}
      },
      async closeAndWait() {}
    } as unknown as CodexAppServerClient
    const runtime = new AgentCodexRuntime('agent-1', fakeClient)
    const owner = session()
    await runtime.registerRoot('root-1', owner)

    await runtime.cleanupSession(owner)

    expect(calls.map(call => `${call.method}:${call.params.threadId ?? ''}`)).toEqual([
      'thread/backgroundTerminals/list:root-1',
      'thread/backgroundTerminals/clean:root-1',
      'thread/unsubscribe:root-1',
      'thread/backgroundTerminals/list:late-child',
      'thread/backgroundTerminals/clean:late-child',
      'thread/unsubscribe:late-child'
    ])
  })

  it('cleans a child thread that starts after its parent Job tree was removed', async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = []
    const fakeClient = {
      async request(method: string, params: Record<string, unknown>) {
        calls.push({ method, params })
        if (method === 'thread/backgroundTerminals/list') return { data: [], nextCursor: null }
        return {}
      },
      async closeAndWait() {}
    } as unknown as CodexAppServerClient
    const runtime = new AgentCodexRuntime('agent-1', fakeClient)
    const owner = session()
    await runtime.registerRoot('root-1', owner)
    await runtime.cleanupSession(owner)
    calls.length = 0

    runtime.routeNotification({
      method: 'item/completed',
      params: {
        threadId: 'root-1',
        turnId: 'root-turn',
        item: {
          type: 'subAgentActivity',
          id: 'spawn-late-child',
          kind: 'started',
          agentThreadId: 'late-child',
          agentPath: '/root/late-child'
        }
      }
    })
    runtime.routeNotification({
      method: 'turn/started',
      params: { threadId: 'late-child', turn: { id: 'late-turn' } }
    })

    await waitUntil(
      () =>
        calls.some(call => call.method === 'turn/interrupt' && call.params.threadId === 'late-child') &&
        calls.some(call => call.method === 'thread/unsubscribe' && call.params.threadId === 'late-child')
    )
    expect(owner.notifications).toEqual([])
  })

  it('reclaims a retired durable root for a later Job session', async () => {
    const calls: string[] = []
    const fakeClient = {
      async request(method: string, params: Record<string, unknown>) {
        calls.push(`${method}:${params.threadId ?? ''}`)
        if (method === 'thread/backgroundTerminals/list') return { data: [], nextCursor: null }
        return {}
      },
      async closeAndWait() {}
    } as unknown as CodexAppServerClient
    const runtime = new AgentCodexRuntime('agent-1', fakeClient)
    const first = session()
    const resumed = session()

    await runtime.registerRoot('durable-root', first)
    await runtime.cleanupSession(first)
    calls.length = 0

    await runtime.resumeRoot('durable-root', resumed, async () => {
      calls.push('resume:durable-root')
    })
    runtime.routeNotification({
      method: 'turn/completed',
      params: { threadId: 'durable-root', turn: { id: 'resumed-turn' } }
    })

    expect(calls).toEqual(['resume:durable-root'])
    expect(resumed.notifications.map(message => message.method)).toEqual(['turn/completed'])
  })

  it('serializes a later resume behind overlapping cleanup of the prior owner', async () => {
    const calls: string[] = []
    let releaseCleanup = (): void => undefined
    const cleanupReleased = new Promise<void>(resolve => {
      releaseCleanup = resolve
    })
    let cleanupStarted = false
    const fakeClient = {
      async request(method: string, params: Record<string, unknown>) {
        calls.push(`${method}:${params.threadId ?? ''}`)
        if (method === 'thread/backgroundTerminals/list') {
          cleanupStarted = true
          await cleanupReleased
          return { data: [], nextCursor: null }
        }
        return {}
      },
      async closeAndWait() {}
    } as unknown as CodexAppServerClient
    const runtime = new AgentCodexRuntime('agent-1', fakeClient)
    const first = session()
    const resumed = session()
    await runtime.registerRoot('durable-root', first)

    const cleanup = runtime.cleanupSession(first)
    await waitUntil(() => cleanupStarted)
    let resumeStarted = false
    const resume = runtime.resumeRoot('durable-root', resumed, async () => {
      resumeStarted = true
    })
    await Promise.resolve()
    expect(resumeStarted).toBe(false)

    releaseCleanup()
    await Promise.all([cleanup, resume])
    runtime.routeNotification({ method: 'turn/started', params: { threadId: 'durable-root', turn: { id: 'next' } } })

    expect(resumeStarted).toBe(true)
    expect(resumed.notifications.at(-1)?.method).toBe('turn/started')
  })

  it('keeps a failed resume tombstone reclaimable by a later attempt', async () => {
    const fakeClient = {
      async request(method: string) {
        if (method === 'thread/backgroundTerminals/list') return { data: [], nextCursor: null }
        return {}
      },
      async closeAndWait() {}
    } as unknown as CodexAppServerClient
    const runtime = new AgentCodexRuntime('agent-1', fakeClient)
    const first = session()
    const failed = session()
    const resumed = session()
    await runtime.registerRoot('durable-root', first)
    await runtime.cleanupSession(first)

    await expect(
      runtime.resumeRoot('durable-root', failed, async () => {
        throw new Error('temporary resume failure')
      })
    ).rejects.toThrow('temporary resume failure')

    await runtime.resumeRoot('durable-root', resumed, async () => undefined)
    runtime.routeNotification({
      method: 'turn/completed',
      params: { threadId: 'durable-root', turn: { id: 'recovered' } }
    })

    expect(failed.notifications).toEqual([])
    expect(resumed.notifications.at(-1)?.method).toBe('turn/completed')
  })
})

type TestSession = AgentCodexRuntimeSession & {
  notifications: JSONRPCMessage[]
  lost: AgentCodexRuntimeLostError[]
  preparedForCleanup: boolean
  onCleanup?: () => void
  onRequest?: () => Promise<void>
}

function session(): TestSession {
  return {
    notifications: [],
    lost: [],
    preparedForCleanup: false,
    prepareForRuntimeCleanup() {
      this.preparedForCleanup = true
      this.onCleanup?.()
    },
    handleRuntimeNotification(message) {
      this.notifications.push(message)
    },
    async handleRuntimeServerRequest() {
      await this.onRequest?.()
    },
    handleRuntimeLost(error) {
      this.lost.push(error)
    }
  }
}

function messageMethodThread(message: JSONRPCMessage): string {
  const params = message.params as { threadId?: string }
  return `${message.method}:${params.threadId ?? ''}`
}

function runtimeFixture(options: { initializeDelayMs?: number } = {}): {
  agentHome: string
  codexHome: string
  initializeMarker: string
  sandbox: CodexAppServerSandboxSpec
  cleanup(): void
} {
  const root = mkdtempSync(join(tmpdir(), 'ankole-agent-runtime-manager-'))
  const codexHome = join(root, 'codex-home')
  const script = join(root, 'fake-app-server.ts')
  const lockHelper = join(root, 'flock')
  const initializeMarker = join(root, 'initialize-started')
  const previousFlockBinary = process.env.ANKOLE_FLOCK_BINARY
  mkdirSync(codexHome)
  writePortableFlock(lockHelper)
  process.env.ANKOLE_FLOCK_BINARY = lockHelper
  writeFileSync(
    script,
    `import { writeFileSync } from 'node:fs'
let buffer = ''
function write(message) { process.stdout.write(JSON.stringify(message) + '\\n') }
function handle(message) {
  if (message.method === 'initialize') {
    writeFileSync(process.env.FAKE_INITIALIZE_MARKER, 'started')
    return setTimeout(() => write({ id: message.id, result: { userAgent: 'fake-codex/1' } }), Number(process.env.FAKE_INITIALIZE_DELAY_MS || 0))
  }
  if (message.method === 'initialized') return
  if (message.method === 'test/exit') return process.exit(43)
  if (message.id !== undefined) write({ id: message.id, result: {} })
}
process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
  buffer += chunk
  let index = buffer.indexOf('\\n')
  while (index >= 0) {
    const line = buffer.slice(0, index).trim()
    buffer = buffer.slice(index + 1)
    if (line) handle(JSON.parse(line))
    index = buffer.indexOf('\\n')
  }
})
process.stdin.resume()
`
  )
  return {
    agentHome: root,
    codexHome,
    initializeMarker,
    sandbox: {
      cwd: root,
      codexCwd: root,
      commandArgv: [process.execPath, script],
      env: {
        PATH: process.env.PATH ?? '/usr/bin:/bin',
        HOME: root,
        CODEX_HOME: codexHome,
        FAKE_INITIALIZE_MARKER: initializeMarker,
        FAKE_INITIALIZE_DELAY_MS: String(options.initializeDelayMs ?? 0)
      }
    },
    cleanup: () => {
      if (previousFlockBinary === undefined) delete process.env.ANKOLE_FLOCK_BINARY
      else process.env.ANKOLE_FLOCK_BINARY = previousFlockBinary
      rmSync(root, { recursive: true, force: true })
    }
  }
}

function writePortableFlock(path: string): void {
  writeFileSync(
    path,
    `#!/usr/bin/env python3
import fcntl
import os
import sys

args = sys.argv[1:]
if len(args) < 6 or args[0] != "-n" or args[1] != "-E" or args[3] != "-F":
    sys.exit(64)
busy_code = int(args[2])
fd = os.open(args[4], os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(busy_code)
os.set_inheritable(fd, True)
os.execvp(args[5], args[5:])
`
  )
  chmodSync(path, 0o755)
}

async function waitForFile(path: string): Promise<void> {
  await waitUntil(() => existsSync(path))
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 5_000
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('Timed out waiting for runtime state')
    await Bun.sleep(10)
  }
}
