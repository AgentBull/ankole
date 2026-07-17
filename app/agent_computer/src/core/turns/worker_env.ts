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
  const response = await rpc(rpcMethods.workerEnvResolve, { agent_uid: turnStart.turn.actor.agent_uid })

  const vars: Record<string, string> = {}
  for (const [name, value] of Object.entries(response.vars ?? {})) {
    if (typeof value === 'string') vars[name] = value
  }
  return vars
}
