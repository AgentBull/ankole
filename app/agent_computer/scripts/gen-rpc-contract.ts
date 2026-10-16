import { rpcOperations, type RPCMethod } from '../src/lanes/rpc_contract'

/** Generates the shared contract from the Worker's operation table. */
export function rpcContractEntries(): Array<{
  method: string
  owner?: string
  scope?: string
  effect?: string
  request_type: string
  response_type: string
}> {
  return (Object.keys(rpcOperations) as RPCMethod[]).sort().map(method => {
    const operation = rpcOperations[method]
    return {
      method,
      ...('owner' in operation
        ? { owner: operation.owner }
        : { scope: operation.scope, ...('effect' in operation ? { effect: operation.effect } : {}) }),
      request_type: operation.request.typeName,
      response_type: operation.response.typeName
    }
  })
}

export const rpcContractPath = new URL('../../kernel/proto/ankole/runtime_fabric/v1/rpc_methods.json', import.meta.url)

if (import.meta.main) {
  await Bun.write(rpcContractPath, `${JSON.stringify(rpcContractEntries(), null, 2)}\n`)
  console.warn(`wrote ${rpcContractEntries().length} operations to ${rpcContractPath.pathname}`)
}
