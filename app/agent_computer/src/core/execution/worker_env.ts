import { rpcMethods, type RPCRequester } from '../../lanes/rpc_lane'

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
  agentUID: string,
  rpc: RPCRequester,
  bindingName?: string
): Promise<ResolvedAgentWorkerEnv> {
  const response = await rpc(rpcMethods.workerEnvResolve, { bindingName: bindingName ?? '' }, { agentUid: agentUID })
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
