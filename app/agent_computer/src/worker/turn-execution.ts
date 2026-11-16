import { agentHomePaths } from '../core/agent-home-paths'
import { runCodexJob } from '../core/codex-runner'
import type { RuntimeRPCClient } from '../lanes/rpc-lane'
import type { BrowserRuntime } from '../browser-runtime'
import { Drive } from '../drive/drive'
import type { ActiveTurn } from './active-turns'
import type { WorkerConfig } from './config'
import { turnOperation, workerLogger } from './logging'
import { requestAIGatewayAPIKey, throwingRPCRequester } from './rpc-requests'
import { prepareTurnWorkspace } from './workspace'

/**
 * Materializes the Agent Home directories, Drive handle, and handler
 * dependencies for one accepted Turn. It commits complete and no-op results.
 * ActiveTurns owns admission, failures, controlled stops, and release.
 */
export async function executeActiveTurn(
  config: WorkerConfig,
  browserRuntime: BrowserRuntime,
  rpcClient: RuntimeRPCClient,
  active: ActiveTurn
): Promise<void> {
  const turnStart = active.turnStart
  prepareTurnWorkspace(config)
  const paths = agentHomePaths(config.agentHomeRoot)
  workerLogger.info('worker.turn_started', 'worker turn started', {
    signal_id: turnStart.turn.signal_id,
    operation: turnOperation(turnStart.turn.signal_id)
  })
  const rpc = throwingRPCRequester(rpcClient, active.abortSignal)
  const drive = new Drive({ agentHome: paths.home, rpc, frame: { jobTurn: turnStart.turn } })

  active.abortSignal.throwIfAborted()

  await runCodexJob(turnStart, {
    agentHome: paths.home,
    drive,
    builtinSkillsRoot: config.builtinSkillsRoot,
    internalSkillsRoot: config.internalSkillsRoot,
    runtimeEnv: turnStart.runtime_env,
    rpc,
    requestAIGatewayAPIKey: options => requestAIGatewayAPIKey(rpcClient, { ...options, signal: active.abortSignal }),
    logger: workerLogger,
    pollSteering: () => active.pollSteering(),
    pollDisabledSkills: () => active.pollDisabledSkills(),
    abortSignal: active.abortSignal,
    browserRuntime
  })
}
