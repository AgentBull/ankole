import { rpcMethods, rpcOperationMeta, rpcSchemas } from '../src/lanes/rpc_lane'

/**
 * Builds the cross-language RPC contract entries from the Bun operation tables.
 *
 * The committed JSON is the parity anchor between this package and the Elixir
 * `Ankole.SignalsGateway.ActorRuntime.RPCLane` dispatch table; both sides assert against it in
 * package-local tests. Each entry pins the method's authorization scope and
 * the fully qualified generated payload message names from `rpc.proto`.
 */
export function rpcContractEntries(): Array<{
  method: string
  owner?: string
  scope?: string
  effect?: string
  request_type: string
  response_type: string
}> {
  return Object.values(rpcMethods)
    .sort()
    .map(method => ({
      method,
      ...rpcOperationMeta[method],
      request_type: rpcSchemas[method].request.typeName,
      response_type: rpcSchemas[method].response.typeName
    }))
}

export const rpcContractPath = new URL('../../kernel/proto/ankole/runtime_fabric/v1/rpc_methods.json', import.meta.url)

if (import.meta.main) {
  await Bun.write(rpcContractPath, `${JSON.stringify(rpcContractEntries(), null, 2)}\n`)
  console.warn(`wrote ${rpcContractEntries().length} operations to ${rpcContractPath.pathname}`)
}
