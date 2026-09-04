import { ms } from '@agentbull/active-support'
import { randomUUID } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { RPCRequester } from '../../lanes/rpc_lane'
import { resolveAgentWorkerEnvParts, type ResolvedAgentWorkerEnv } from './worker_env'

/** Binding-scoped raw token returned only through WorkerEnv RPC. */
export const LARK_TENANT_TOKEN_ENV = 'LARKSUITE_CLI_TENANT_ACCESS_TOKEN'
/** File-path handoff read by the image-provided lark-cli launcher. */
export const LARK_TENANT_TOKEN_FILE_ENV = 'ANKOLE_RUNTIME_LARK_TENANT_ACCESS_TOKEN_FILE'

// App ID and brand identify the binding. A refresh must not cross this
// identity boundary.
const larkAppIDEnv = 'LARKSUITE_CLI_APP_ID'
const larkBrandEnv = 'LARKSUITE_CLI_BRAND'
// One-minute refresh keeps the file inside the launcher's five-minute
// freshness limit.
const defaultRefreshIntervalMs = ms('1m')

export type MaterializedLarkCredential = {
  workerEnv: ResolvedAgentWorkerEnv
  runtimeEnv: Record<string, string>
  cleanup(): void
}

/**
 * Keeps one execution's Lark bot token current without freezing it in the
 * shell environment. The control plane remains the credential owner; this
 * file is a disposable projection read by the image-provided lark-cli wrapper.
 */
export function materializeLarkCredential(input: {
  agentUID: string
  agentHome: string
  rpc: RPCRequester
  workerEnv: ResolvedAgentWorkerEnv
  bindingName?: string
  refreshIntervalMs?: number
}): MaterializedLarkCredential {
  const workerEnv = withoutLarkTenantToken(input.workerEnv)
  const initialToken = input.workerEnv.bindingVars[LARK_TENANT_TOKEN_ENV]
  const bindingIdentity = larkBindingIdentity(input.workerEnv.bindingVars)
  if (!initialToken || !bindingIdentity) return { workerEnv, runtimeEnv: {}, cleanup: () => undefined }

  const directory = join(input.agentHome, 'runtime-materials', 'credentials')
  mkdirSync(directory, { recursive: true, mode: 0o700 })
  chmodSync(directory, 0o700)
  const path = join(directory, `lark-tenant-token-${randomUUID()}`)
  atomicWriteToken(path, initialToken)

  const refreshIntervalMs = input.refreshIntervalMs ?? defaultRefreshIntervalMs
  if (!Number.isFinite(refreshIntervalMs) || refreshIntervalMs <= 0) {
    unlinkIfPresent(path)
    throw new Error('Lark credential refresh interval must be positive')
  }

  let stopped = false
  let timer: ReturnType<typeof setTimeout> | undefined

  const schedule = (): void => {
    timer = setTimeout(() => void refresh(), refreshIntervalMs)
    timer.unref?.()
  }

  const refresh = async (): Promise<void> => {
    try {
      const current = await resolveAgentWorkerEnvParts(input.agentUID, input.rpc, input.bindingName)
      if (stopped) return
      const token = current.bindingVars[LARK_TENANT_TOKEN_ENV]
      if (token && larkBindingIdentity(current.bindingVars) === bindingIdentity) atomicWriteToken(path, token)
      else unlinkIfPresent(path)
    } catch {
      // Keep the last file timestamp. The launcher rejects it if refresh does
      // not recover before the bounded freshness window ends.
    } finally {
      if (!stopped) schedule()
    }
  }

  schedule()

  return {
    workerEnv,
    runtimeEnv: { [LARK_TENANT_TOKEN_FILE_ENV]: path },
    cleanup: () => {
      if (stopped) return
      stopped = true
      if (timer) clearTimeout(timer)
      unlinkIfPresent(path)
    }
  }
}

/** Removes the raw Lark token before any WorkerEnv reaches a child process. */
function withoutLarkTenantToken(workerEnv: ResolvedAgentWorkerEnv): ResolvedAgentWorkerEnv {
  return {
    vars: withoutLarkTenantTokenValue(workerEnv.vars),
    operatorVars: withoutLarkTenantTokenValue(workerEnv.operatorVars),
    bindingVars: withoutLarkTenantTokenValue(workerEnv.bindingVars)
  }
}

function withoutLarkTenantTokenValue(env: Record<string, string>): Record<string, string> {
  const next = { ...env }
  delete next[LARK_TENANT_TOKEN_ENV]
  return next
}

function larkBindingIdentity(bindingVars: Record<string, string>): string | undefined {
  const appID = bindingVars[larkAppIDEnv]
  const brand = bindingVars[larkBrandEnv]
  return appID && brand ? `${brand}\0${appID}` : undefined
}

/** Writes by rename so a reader cannot observe a partial token. */
function atomicWriteToken(path: string, token: string): void {
  if (!token || token.trim() !== token || /[\0\r\n]/.test(token)) {
    throw new Error('Lark tenant token has an invalid value')
  }

  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`
  try {
    writeFileSync(temporary, `${token}\n`, { mode: 0o600, flag: 'wx' })
    renameSync(temporary, path)
  } finally {
    if (existsSync(temporary)) unlinkSync(temporary)
  }
}

function unlinkIfPresent(path: string): void {
  try {
    unlinkSync(path)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
}
