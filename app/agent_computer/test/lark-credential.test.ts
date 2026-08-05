import { afterEach, describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { mkdtempSync, mkdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  LARK_TENANT_TOKEN_ENV,
  LARK_TENANT_TOKEN_FILE_ENV,
  materializeLarkCredential,
  sameLarkBindingIdentity,
  withoutLarkTenantTokenValue
} from '../src/core/turns/lark-credential'
import type { ResolvedAgentWorkerEnv } from '../src/core/turns/worker_env'
import { WorkerEnvResolveResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'

const roots: string[] = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('Lark execution credential', () => {
  it('removes a frozen token from a final flat projection', () => {
    expect(withoutLarkTenantTokenValue({ SAFE: 'value', [LARK_TENANT_TOKEN_ENV]: 'frozen-token' })).toEqual({
      SAFE: 'value'
    })
  })

  it('compares the app and domain that own a refreshed token', () => {
    const current = workerEnv('tenant-token-1')
    const otherApp = workerEnv('tenant-token-2')
    otherApp.bindingVars.LARKSUITE_CLI_APP_ID = 'app-2'
    const otherDomain = workerEnv('tenant-token-3')
    otherDomain.bindingVars.LARKSUITE_CLI_BRAND = 'lark'

    expect(sameLarkBindingIdentity(current, workerEnv('tenant-token-4'))).toBe(true)
    expect(sameLarkBindingIdentity(current, otherApp)).toBe(false)
    expect(sameLarkBindingIdentity(current, otherDomain)).toBe(false)
    expect(sameLarkBindingIdentity(current, workerEnv(undefined))).toBe(false)
  })

  it('removes the raw token and refreshes one private file until cleanup', async () => {
    const agentHome = fixtureAgentHome()
    let refreshToken = 'tenant-token-2'
    let requests = 0
    const rpc = workerEnvRPC(() => {
      requests += 1
      return refreshToken
    })

    const materialized = materializeLarkCredential({
      agentUID: 'agent-a',
      agentHome,
      rpc,
      workerEnv: workerEnv('tenant-token-1'),
      refreshIntervalMs: 5
    })
    const path = materialized.runtimeEnv[LARK_TENANT_TOKEN_FILE_ENV]!

    expect(materialized.workerEnv.vars[LARK_TENANT_TOKEN_ENV]).toBeUndefined()
    expect(materialized.workerEnv.operatorVars[LARK_TENANT_TOKEN_ENV]).toBeUndefined()
    expect(materialized.workerEnv.bindingVars[LARK_TENANT_TOKEN_ENV]).toBeUndefined()
    expect(readFileSync(path, 'utf8')).toBe('tenant-token-1\n')
    expect(statSync(path).mode & 0o777).toBe(0o600)

    await waitUntil(() => readFileSync(path, 'utf8') === 'tenant-token-2\n')
    expect(requests).toBeGreaterThan(0)

    refreshToken = 'tenant-token-3'
    materialized.cleanup()
    materialized.cleanup()
    expect(await Bun.file(path).exists()).toBe(false)
  })

  it('removes a token disabled by the current binding and recreates the same path when it returns', async () => {
    const agentHome = fixtureAgentHome()
    // oxlint-disable-next-line prefer-const
    let refreshToken: string | undefined
    const materialized = materializeLarkCredential({
      agentUID: 'agent-a',
      agentHome,
      rpc: workerEnvRPC(() => refreshToken),
      workerEnv: workerEnv('tenant-token-1'),
      refreshIntervalMs: 5
    })
    const path = materialized.runtimeEnv[LARK_TENANT_TOKEN_FILE_ENV]!

    await waitUntil(async () => !(await Bun.file(path).exists()))
    refreshToken = 'tenant-token-2'
    await waitUntil(async () =>
      (await Bun.file(path).exists()) ? (await Bun.file(path).text()) === 'tenant-token-2\n' : false
    )

    materialized.cleanup()
  })

  it('fails closed when the binding changes to another Lark application', async () => {
    const agentHome = fixtureAgentHome()
    let appID = 'app-1'
    const materialized = materializeLarkCredential({
      agentUID: 'agent-a',
      agentHome,
      rpc: workerEnvRPC(
        () => 'tenant-token-2',
        () => appID
      ),
      workerEnv: workerEnv('tenant-token-1'),
      refreshIntervalMs: 5
    })
    const path = materialized.runtimeEnv[LARK_TENANT_TOKEN_FILE_ENV]!

    appID = 'app-2'
    await waitUntil(async () => !(await Bun.file(path).exists()))
    appID = 'app-1'
    await waitUntil(async () =>
      (await Bun.file(path).exists()) ? (await Bun.file(path).text()) === 'tenant-token-2\n' : false
    )

    materialized.cleanup()
  })

  it('does not create a refresh owner without a binding-derived token', () => {
    const materialized = materializeLarkCredential({
      agentUID: 'agent-a',
      agentHome: fixtureAgentHome(),
      rpc: workerEnvRPC(() => 'unused'),
      workerEnv: workerEnv(undefined)
    })

    expect(materialized.runtimeEnv).toEqual({})
    materialized.cleanup()
  })
})

function fixtureAgentHome(): string {
  const root = mkdtempSync(join(tmpdir(), 'ankole-lark-credential-'))
  roots.push(root)
  const agentHome = join(root, 'agent-a')
  mkdirSync(agentHome)
  return agentHome
}

function workerEnv(token: string | undefined): ResolvedAgentWorkerEnv {
  const bindingVars: Record<string, string> = { SAFE_BINDING: 'safe' }
  if (token) {
    bindingVars.LARKSUITE_CLI_APP_ID = 'app-1'
    bindingVars.LARKSUITE_CLI_BRAND = 'feishu'
    bindingVars[LARK_TENANT_TOKEN_ENV] = token
  }
  return {
    vars: { SAFE_OPERATOR: 'operator', ...bindingVars },
    operatorVars: { SAFE_OPERATOR: 'operator', [LARK_TENANT_TOKEN_ENV]: 'operator-token' },
    bindingVars
  }
}

function workerEnvRPC(token: () => string | undefined, appID: () => string = () => 'app-1'): RPCRequester {
  return (async (method: unknown, _payload: unknown, frame: unknown) => {
    expect(method).toBe(rpcMethods.workerEnvResolve)
    expect((frame as { agentUid: string }).agentUid).toBe('agent-a')
    const current = token()
    const bindingVars: Record<string, string> = {}
    if (current) {
      bindingVars.LARKSUITE_CLI_APP_ID = appID()
      bindingVars.LARKSUITE_CLI_BRAND = 'feishu'
      bindingVars[LARK_TENANT_TOKEN_ENV] = current
    }
    return create(WorkerEnvResolveResponseSchema, { vars: bindingVars, bindingVars })
  }) as RPCRequester
}

async function waitUntil(predicate: () => boolean | Promise<boolean>): Promise<void> {
  const deadline = Date.now() + 1_000
  while (!(await predicate())) {
    if (Date.now() >= deadline) throw new Error('condition did not become true')
    await Bun.sleep(5)
  }
}
