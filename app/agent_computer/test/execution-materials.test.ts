import { afterEach, describe, expect, it, mock } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { cleanupExecutionMaterials, prepareExecutionMaterials } from '../src/core/execution/execution-materials'
import { BrowserRuntime, type RenderedFetchBrowserMaterializeSettings } from '../src/browser-runtime'
import type { BrowserRoute } from '../src/browser-runtime/materializer'
import { projectWorkerEnv, type CodexJobRuntimeProjection } from '../src/core/codex-runner/job/runtime-projection'
import { LARK_TENANT_TOKEN_ENV } from '../src/core/execution/lark-credential'
import { MCPORTER_CONFIG_ENV } from '../src/tools/mcp/mcporter-config'
import { WorkerEnvResolveResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { type RPCRequester } from '../src/lanes/rpc_lane'

const roots: string[] = []
const browserBackendJSON = '{"kind":"local_chromium","executable":"/bin/true","args":[]}'

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('execution materials', () => {
  it('binds rendered fetch source settings but returns only command-safe environment', async () => {
    const { root, agentHome, scopeRoot, temp } = executionPaths()
    const runtime = browserRuntime(root)
    const fetchRendered = mock(
      async (_urls: string[], _settings: RenderedFetchBrowserMaterializeSettings, _signal?: AbortSignal) => ({
        results: []
      })
    )
    runtime.fetchRendered = fetchRendered

    const materials = await prepareExecutionMaterials({
      agentHome,
      rpc: workerEnvRPC(),
      bindingName: 'lark-main',
      runtimeEnv: { RUNTIME_SAFE: 'yes' },
      mcpServers: [],
      mcporterDirectory: temp,
      renderedFetch: {
        config: { ssrfFilter: true, renderedFetchIdleTtlMs: 45_000 },
        browserRuntime: runtime
      },
      browser: {
        runtime,
        scopeRoot,
        artifactRoot: join(scopeRoot, 'browser'),
        ssrfFilter: true
      }
    })

    const signal = new AbortController().signal
    await materials.renderedFetch!.fetchBatch(['https://example.com'], signal)
    expect(fetchRendered).toHaveBeenCalledTimes(1)
    const settings = fetchRendered.mock.calls[0]![1]
    expect(settings.ssrfFilter).toBe(true)
    expect(settings.workerEnv?.BROWSER_BACKEND_JSON).toBe(browserBackendJSON)
    expect(settings.workerEnv?.[LARK_TENANT_TOKEN_ENV]).toBeUndefined()
    expect(settings.idleTtlMs).toBe(45_000)
    expect(fetchRendered).toHaveBeenCalledWith(['https://example.com'], settings, signal)
    expect(materials.workerEnv.SAFE).toBe('value')
    expect(materials.workerEnv.BROWSER_BACKEND_JSON).toBeUndefined()
    expect(materials.workerEnv[LARK_TENANT_TOKEN_ENV]).toBeUndefined()
    expect(materials.workerEnv[MCPORTER_CONFIG_ENV]).toStartWith(temp)
    expect(materials.runtimeEnv.RUNTIME_SAFE).toBe('yes')
    expect(materials.runtimeEnv['ANKOLE_RUNTIME_LARK_TENANT_ACCESS_TOKEN_FILE']).toStartWith(agentHome)
    expect(materials.runtimeEnv.ANKOLE_BROWSER_SOCKET).toBeUndefined()
    expect(materials.browserEnv.ANKOLE_BROWSER_SOCKET).toBe(join(root, 'socket', 'browser.sock'))
    expect(materials.browserEnv.ANKOLE_BROWSER_MATERIAL).toStartWith(join(root, 'runtime', 'browser'))

    const mcporterPath = materials.workerEnv[MCPORTER_CONFIG_ENV]!
    const larkPath = materials.runtimeEnv['ANKOLE_RUNTIME_LARK_TENANT_ACCESS_TOKEN_FILE']!
    const browserPath = materials.browserEnv.ANKOLE_BROWSER_MATERIAL!
    expect(await Bun.file(mcporterPath).exists()).toBe(true)
    expect(await Bun.file(larkPath).exists()).toBe(true)
    expect(await Bun.file(browserPath).exists()).toBe(true)
    expect((await Bun.file(browserPath).json()).idle_ttl_ms).toBe(30 * 60_000)

    await materials.cleanup()
    await materials.cleanup()
    expect(await Bun.file(mcporterPath).exists()).toBe(false)
    expect(await Bun.file(larkPath).exists()).toBe(false)
    expect(await Bun.file(browserPath).exists()).toBe(false)
    expect(await Bun.file(join(scopeRoot, '.ankole', 'browser-route.json')).exists()).toBe(true)
  })

  it('uses the frozen Job projection for separate ephemeral fetch routes', async () => {
    const { root, agentHome, temp } = executionPaths()
    const runtime = browserRuntime(root)
    const routes: BrowserRoute[] = []
    runtime.fetchRendered = async (_urls, settings) => {
      routes.push(await runtime.materializer.materializeEphemeral({ settings }))
      return { results: [] }
    }
    const frozenBackend = JSON.stringify({ kind: 'local_chromium', executable: '/bin/true', args: ['--frozen'] })
    const projection: CodexJobRuntimeProjection = {
      version: 1,
      workerEnv: {
        names: ['SAFE', 'BROWSER_BACKEND_JSON'],
        plainValues: { SAFE: 'frozen-value', BROWSER_BACKEND_JSON: frozenBackend }
      }
    }
    const materials = await prepareExecutionMaterials({
      agentHome,
      rpc: workerEnvRPC(),
      bindingName: 'lark-main',
      mcpServers: [],
      mcporterDirectory: temp,
      projectEnv: workerEnv => projectWorkerEnv(projection, workerEnv),
      renderedFetch: { config: { ssrfFilter: false }, browserRuntime: runtime }
    })

    try {
      expect(materials.workerEnv.SAFE).toBe('frozen-value')
      expect(materials.workerEnv.BROWSER_BACKEND_JSON).toBeUndefined()
      expect(materials.browserEnv).toEqual({})
      await materials.renderedFetch!.fetchBatch(['https://example.com'])
      await materials.renderedFetch!.fetchBatch(['https://example.com'])
      expect(routes).toHaveLength(2)
      expect(routes[0]!.route).not.toBe(routes[1]!.route)
      for (const route of routes) {
        expect(route.material.backend).toMatchObject({ args: ['--frozen'] })
        expect(route.material.navigation.ssrf_filter).toBe(false)
        expect(route.material.idle_ttl_ms).toBe(30 * 60_000)
      }
    } finally {
      await materials.cleanup()
    }
  })

  it('cleans Browser, MCPorter, and Lark in order without hiding the first error', async () => {
    const calls: string[] = []
    const browserError = new Error('browser cleanup failed')

    const cleanup = cleanupExecutionMaterials({
      browser: {
        cleanup: async () => {
          calls.push('browser')
          throw browserError
        }
      },
      mcporter: {
        cleanup: () => {
          calls.push('mcporter')
          throw new Error('mcporter cleanup failed')
        }
      },
      lark: {
        cleanup: () => {
          calls.push('lark')
          throw new Error('lark cleanup failed')
        }
      }
    })

    await expect(cleanup).rejects.toBe(browserError)
    expect(calls).toEqual(['browser', 'mcporter', 'lark'])
  })
})

function executionPaths() {
  const root = mkdtempSync(join(tmpdir(), 'ankole-execution-materials-'))
  roots.push(root)
  const paths = { root, agentHome: join(root, 'agent'), scopeRoot: join(root, 'scope'), temp: join(root, 'temp') }
  for (const directory of [paths.agentHome, paths.scopeRoot, paths.temp]) mkdirSync(directory)
  return paths
}

function browserRuntime(root: string): BrowserRuntime {
  return new BrowserRuntime({
    runtimeRoot: join(root, 'runtime'),
    socketPath: join(root, 'socket', 'browser.sock'),
    daemonEntry: '/bin/true',
    runnerPath: '/bin/true',
    localChromiumExecutable: '/bin/true'
  })
}

function workerEnvRPC(): RPCRequester {
  return (async (method: unknown, payload: unknown, frame: unknown) => {
    expect(method).toBe('worker_env.resolve')
    expect(payload).toMatchObject({ bindingName: 'lark-main' })
    expect(frame).toBeUndefined()

    const bindingVars = {
      LARKSUITE_CLI_APP_ID: 'app-1',
      LARKSUITE_CLI_BRAND: 'feishu',
      [LARK_TENANT_TOKEN_ENV]: 'tenant-token'
    }
    const vars = {
      SAFE: 'value',
      BROWSER_BACKEND_JSON: browserBackendJSON,
      ...bindingVars
    }
    return create(WorkerEnvResolveResponseSchema, { vars, bindingVars })
  }) as RPCRequester
}
