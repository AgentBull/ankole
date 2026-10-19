import { runAutomationJob } from '../automation-jobs/run'
import { pullFile, pushBundle, pushFile } from '../lanes/file/relay'
import { type RuntimeRPCClient } from '../lanes/rpc_lane'
import { type WorkerRPCContext, type WorkerRPCHandlers } from '../lanes/rpc_contract'
import type { WorkerConfig } from './config'
import { throwingRPCRequester } from './rpc_requests'

/** The Worker's config without its credential: no handler needs it. */
type HandlerConfig = Pick<WorkerConfig, 'agentHomeRoot' | 'builtinSkillsRoot' | 'internalSkillsRoot'>

/** Binds control-plane-initiated RPCs to operations executed by this Worker. */
export function createWorkerRPCHandlers(
  config: HandlerConfig,
  rpcClient: RuntimeRPCClient
): WorkerRPCHandlers & { close(): Promise<void> } {
  const shutdown = new AbortController()
  const active = new Set<Promise<unknown>>()
  async function own<T>(context: WorkerRPCContext, operation: (signal: AbortSignal) => Promise<T>): Promise<T> {
    const signal = AbortSignal.any([shutdown.signal, context.signal])
    signal.throwIfAborted()
    const pending = operation(signal)
    active.add(pending)
    try {
      return await pending
    } finally {
      active.delete(pending)
    }
  }
  return {
    async close() {
      shutdown.abort(new DOMException('Worker stopped', 'AbortError'))
      await Promise.allSettled(active)
    },
    pullWorkerFile: (request, context) =>
      own(context, async signal => ({ size: BigInt((await pullFile(config, request, signal)).size) })),
    pushWorkerFile: (request, context) =>
      own(context, async signal => {
        const result =
          request.bundlePaths.length > 0
            ? await pushBundle(config, request, signal)
            : await pushFile(config, request, signal)
        return { size: BigInt(result.size) }
      }),
    runAutomationJob: (request, context) =>
      own(context, signal => {
        return runAutomationJob(request, {
          config,
          rpc: throwingRPCRequester(rpcClient),
          signal,
          deadlineUnixMs: context.deadlineUnixMs
        })
      })
  }
}
