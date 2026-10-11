import { ms } from '@agentbull/active-support'
import type { RuntimeRPCClient } from '../lanes/rpc_lane'
import { configureWorkerTracing } from './turn-tracing'

/**
 * Exports the Worker's spans through the worker-agent RuntimeFabric RPC.
 * An RPC failure becomes an exporter failure; it does not fail Turn execution.
 */
export function configureRuntimeFabricTracing(rpcClient: RuntimeRPCClient): void {
  configureWorkerTracing(async payload => {
    const response = await rpcClient.request('observability.spans.export', { payload }, undefined, {
      timeoutMs: ms('10s')
    })
    if ('code' in response) throw new Error(`worker span export rejected: ${response.code}`)
  })
}
