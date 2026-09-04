import { afterEach, describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { cleanupExecutionMaterials, prepareExecutionMaterials } from '../src/core/execution/execution-materials'
import { BrowserRuntime } from '../src/browser-runtime'
import { LARK_TENANT_TOKEN_ENV, LARK_TENANT_TOKEN_FILE_ENV } from '../src/core/execution/lark-credential'
import { MCPORTER_CONFIG_ENV } from '../src/tools/mcp'
import { WorkerEnvResolveResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'

const roots: string[] = []
const browserBackendJSON = '{"kind":"local_chromium","executable":"/bin/true","args":[]}'

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('execution materials', () => {
  it('consumes material source values but returns only sandbox-safe environment', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-execution-materials-'))
    roots.push(root)
    const agentHome = join(root, 'agent')
    const scopeRoot = join(root, 'scope')
    const temp = join(root, 'temp')
    mkdirSync(agentHome)
    mkdirSync(scopeRoot)
    mkdirSync(temp)
    let materialSourceEnv: Record<string, string> | undefined

    const materials = await prepareExecutionMaterials({
      agentUID: 'agent-a',
      agentHome,
      rpc: workerEnvRPC(),
      bindingName: 'lark-main',
      runtimeEnv: { RUNTIME_SAFE: 'yes' },
      mcpServers: [],
      mcporterDirectory: temp,
      browser: {
        runtime: new BrowserRuntime({
          runtimeRoot: join(root, 'runtime'),
          socketPath: join(root, 'socket', 'browser.sock'),
          runnerPath: '/bin/true',
          localChromiumExecutable: '/bin/true'
        }),
        scopeRoot,
        artifactRoot: join(scopeRoot, 'browser'),
        ssrfFilter: true
      },
      consumeMaterialSourceEnv: async workerEnv => {
        materialSourceEnv = workerEnv
      }
    })

    expect(materialSourceEnv?.BROWSER_BACKEND_JSON).toBe(browserBackendJSON)
    expect(materialSourceEnv?.[LARK_TENANT_TOKEN_ENV]).toBeUndefined()
    expect(materials.workerEnv.SAFE).toBe('value')
    expect(materials.workerEnv.BROWSER_BACKEND_JSON).toBeUndefined()
    expect(materials.workerEnv[LARK_TENANT_TOKEN_ENV]).toBeUndefined()
    expect(materials.workerEnv[MCPORTER_CONFIG_ENV]).toStartWith(temp)
    expect(materials.runtimeEnv.RUNTIME_SAFE).toBe('yes')
    expect(materials.runtimeEnv[LARK_TENANT_TOKEN_FILE_ENV]).toStartWith(agentHome)
    expect(materials.runtimeEnv.ANKOLE_BROWSER_SOCKET).toBeUndefined()
    expect(materials.browserEnv.ANKOLE_BROWSER_SOCKET).toBe(join(root, 'socket', 'browser.sock'))
    expect(materials.browserEnv.ANKOLE_BROWSER_MATERIAL).toStartWith(join(root, 'runtime', 'browser'))

    const mcporterPath = materials.workerEnv[MCPORTER_CONFIG_ENV]!
    const larkPath = materials.runtimeEnv[LARK_TENANT_TOKEN_FILE_ENV]!
    const browserPath = materials.browserEnv.ANKOLE_BROWSER_MATERIAL!
    expect(await Bun.file(mcporterPath).exists()).toBe(true)
    expect(await Bun.file(larkPath).exists()).toBe(true)
    expect(await Bun.file(browserPath).exists()).toBe(true)

    await materials.cleanup()
    await materials.cleanup()
    expect(await Bun.file(mcporterPath).exists()).toBe(false)
    expect(await Bun.file(larkPath).exists()).toBe(false)
    expect(await Bun.file(browserPath).exists()).toBe(false)
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

function workerEnvRPC(): RPCRequester {
  return (async (method: unknown, payload: unknown, frame: unknown) => {
    expect(method).toBe(rpcMethods.workerEnvResolve)
    expect(payload).toMatchObject({ bindingName: 'lark-main' })
    expect((frame as { agentUid: string }).agentUid).toBe('agent-a')

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
