import { assertRPCResponse, type WorkerEnvResolveResponse } from '../../lanes/rpc_lane'
import type { TurnStart } from '../../lanes/actor_lane'
import type { TextTurnLoopOptions } from './turn_options'

/**
 * Resolves the operator-managed shell environment for this turn's agent.
 *
 * The control plane owns merge semantics (declared AppConfigure exports,
 * custom global rows, custom agent rows); the worker receives one flat map
 * with secrets already decrypted and keeps it in memory for the turn.
 */
export async function resolveWorkerEnv(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<Record<string, string>> {
  if (!opts.requestWorkerEnv) return {}

  const response = await opts.requestWorkerEnv({
    request_id: `worker-env-${crypto.randomUUID()}`,
    agent_uid: turnStart.turn.actor.agent_uid
  })
  assertRPCResponse<WorkerEnvResolveResponse>(response, 'worker env rejected')

  const vars: Record<string, string> = {}
  for (const [name, value] of Object.entries(response.vars ?? {})) {
    if (typeof value === 'string') vars[name] = value
  }
  return vars
}
