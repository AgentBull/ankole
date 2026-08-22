import { runAutomationJob } from '../automation-jobs/run'
import { agentHomePaths } from '../core/agent-home-paths'
import { deleteCodexLogs2AtDailyReset } from '../core/codex-runner/runtime/fix-codex-logs2-sqlite-bug'
import { type RuntimeRPCClient, type WorkerRPCHandlers } from '../lanes/rpc_lane'
import type { WorkerConfig } from './config'
import { workerLogger } from './logging'
import { throwingRPCRequester } from './rpc_requests'

/** Binds control-plane-initiated RPCs to operations executed by this Worker. */
export function createWorkerRPCHandlers(config: WorkerConfig, rpcClient: RuntimeRPCClient): WorkerRPCHandlers {
  return {
    runAutomationJob: request =>
      runAutomationJob(request, {
        config,
        rpc: throwingRPCRequester(rpcClient)
      }),
    maintainCodexLogs2: async request => {
      const codexHome = agentHomePaths(config.agentsRoot, request.agentUid).codexHome
      const result = await deleteCodexLogs2AtDailyReset(codexHome)
      workerLogger.info('worker.codex_logs2_daily_maintenance', 'Codex logs daily maintenance completed', {
        agent_uid: request.agentUid,
        status: result.status,
        deleted_files: result.deletedFiles
      })
      return {
        status: result.status,
        deletedFiles: result.deletedFiles
      }
    }
  }
}
