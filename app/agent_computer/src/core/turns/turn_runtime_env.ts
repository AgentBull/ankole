import { createHmac } from 'node:crypto'
import type { TurnStart } from '../../lanes/actor_lane'

export const CURRENT_ACTOR_SENDER_PRINCIPAL_ENV = 'ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL'
export const LARK_PROFILE_ENV = 'ANKOLE_RUNTIME_LARK_PROFILE'
export const WEBHOOK_CLI_SOCKET_ENV = 'ANKOLE_RUNTIME_WEBHOOK_CLI_SOCKET'
export const AUTOMATION_JOB_CLI_SOCKET_ENV = 'ANKOLE_RUNTIME_AUTOMATION_JOB_CLI_SOCKET'

const fabricWorkerAuthKeyEnv = 'ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY'
const runtimeEnvPrefix = 'ANKOLE_RUNTIME_'
const envNameFormat = /^[A-Za-z_][A-Za-z0-9_]*$/
const larkProfilePrefix = 'ankole-u-'
const workerOnlyEnvNames = new Set([
  fabricWorkerAuthKeyEnv,
  LARK_PROFILE_ENV,
  WEBHOOK_CLI_SOCKET_ENV,
  AUTOMATION_JOB_CLI_SOCKET_ENV
])

/**
 * Validates control-plane turn facts and adds worker-owned derived values.
 *
 * The RuntimeFabric worker key stays in this process. The Worker adds only the
 * opaque Lark profile name to the model-facing turn facts.
 */
export function buildTurnRuntimeEnv(turnStart: TurnStart, workerAuthKey: string): Record<string, string> {
  const runtimeEnv: Record<string, string> = {}

  for (const [name, value] of Object.entries(turnStart.runtime_env ?? {})) {
    if (!envNameFormat.test(name) || !name.startsWith(runtimeEnvPrefix)) {
      throw new Error(`turn runtime env name must use ${runtimeEnvPrefix}: ${name}`)
    }
    if (workerOnlyEnvNames.has(name)) {
      throw new Error(`${name} is reserved to Agent Computer`)
    }
    if (typeof value !== 'string' || value.includes('\0')) {
      throw new Error(`turn runtime env value is invalid: ${name}`)
    }
    runtimeEnv[name] = value
  }

  const principalUID = runtimeEnv[CURRENT_ACTOR_SENDER_PRINCIPAL_ENV]
  if (principalUID) {
    runtimeEnv[LARK_PROFILE_ENV] =
      larkProfilePrefix + createHmac('sha256', workerAuthKey).update(principalUID, 'utf8').digest('base64url')
  }

  return runtimeEnv
}
