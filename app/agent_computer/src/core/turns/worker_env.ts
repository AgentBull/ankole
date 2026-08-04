import { rpcMethods, type RPCRequester } from '../../lanes/rpc_lane'
import type { TurnStart } from '../../lanes/actor_lane'

/**
 * Resolves the operator-managed shell environment for this turn's agent.
 *
 * The control plane owns merge semantics (declared AppConfigure exports,
 * custom global rows, custom agent rows); the worker receives one flat map
 * with secrets already decrypted and keeps it in memory for the turn.
 */
export async function resolveWorkerEnv(turnStart: TurnStart, rpc: RPCRequester): Promise<Record<string, string>> {
  return (await resolveAgentWorkerEnvParts(turnStart.turn.actor.agent_uid, rpc)).vars
}

export type ResolvedAgentWorkerEnv = {
  vars: Record<string, string>
  operatorVars: Record<string, string>
  bindingVars: Record<string, string>
}

/**
 * Resolves the current Agent-level WorkerEnv without requiring a turn.
 */
export async function resolveAgentWorkerEnv(agentUID: string, rpc: RPCRequester): Promise<Record<string, string>> {
  return (await resolveAgentWorkerEnvParts(agentUID, rpc)).vars
}

export async function resolveAgentWorkerEnvParts(agentUID: string, rpc: RPCRequester): Promise<ResolvedAgentWorkerEnv> {
  const response = await rpc(rpcMethods.workerEnvResolve, {}, { agentUid: agentUID })
  return {
    vars: stringMap(response.vars),
    operatorVars: stringMap(response.operatorVars),
    bindingVars: stringMap(response.bindingVars)
  }
}

function stringMap(value: Record<string, string> | undefined): Record<string, string> {
  const result: Record<string, string> = {}
  for (const [name, item] of Object.entries(value ?? {})) {
    if (typeof item === 'string') result[name] = item
  }
  return result
}
