import { type RPCRequester, type TurnRPCFrame } from '../../lanes/rpc_lane'

/**
 * Keeps the combined, operator, and binding views returned by the control
 * plane. Execution adapters use these partitions to apply binding-specific
 * credential rules before child-process injection.
 */
export type ResolvedAgentWorkerEnv = {
  vars: Record<string, string>
  operatorVars: Record<string, string>
  bindingVars: Record<string, string>
}

export async function resolveAgentWorkerEnvParts(
  rpc: RPCRequester,
  frame: TurnRPCFrame,
  bindingName?: string
): Promise<ResolvedAgentWorkerEnv> {
  const response = await rpc('worker_env.resolve', { bindingName: bindingName ?? '' }, frame, {
    retryOnDisconnect: true
  })
  return {
    vars: response.vars,
    operatorVars: response.operatorVars,
    bindingVars: response.bindingVars
  }
}
