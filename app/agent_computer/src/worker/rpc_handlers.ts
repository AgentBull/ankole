import { runAutomationJob } from '../automation-jobs/run'
import { pullFile, pushBundle, pushFile } from '../lanes/file/relay'
import { type RuntimeRPCClient, type WorkerRPCHandlers } from '../lanes/rpc_lane'
import type { WorkerConfig } from './config'
import { throwingRPCRequester } from './rpc_requests'

/** The Worker's config without its credential: no handler needs it. */
type HandlerConfig = Pick<WorkerConfig, 'agentHomeRoot' | 'builtinSkillsRoot' | 'internalSkillsRoot'>

/** Binds control-plane-initiated RPCs to operations executed by this Worker. */
export function createWorkerRPCHandlers(config: HandlerConfig, rpcClient: RuntimeRPCClient): WorkerRPCHandlers {
  return {
    pullWorkerFile: async request => ({ size: BigInt((await pullFile(config, request)).size) }),
    pushWorkerFile: async request => {
      const result =
        request.bundlePaths.length > 0 ? await pushBundle(config, request) : await pushFile(config, request)
      return { size: BigInt(result.size) }
    },
    runAutomationJob: request => {
      return runAutomationJob(request, {
        config,
        rpc: throwingRPCRequester(rpcClient)
      })
    }
  }
}
