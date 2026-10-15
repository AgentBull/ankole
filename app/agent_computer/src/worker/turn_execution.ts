import { agentHomePaths } from '../core/agent-home-paths'
import { runCodexJob } from '../core/codex-runner'
import { startRunCLIBridges } from '../cli/run-cli-bridges'
import type { RuntimeRPCClient } from '../lanes/rpc_lane'
import type { BrowserRuntime } from '../browser-runtime'
import { Drive } from '../drive/drive'
import { materializeSkills } from '../skills/drive_skills'
import type { ActiveTurn } from './active_turns'
import type { WorkerConfig } from './config'
import { workerLogger } from './logging'
import { requestAIGatewayAPIKey, throwingRPCRequester } from './rpc_requests'
import { prepareTurnWorkspace } from './workspace'

/**
 * Materializes the workspace, environment, CLI bridges, Skills, and handler
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
  const workspaceRoot = prepareTurnWorkspace(config)
  const paths = agentHomePaths(config.agentHomeRoot)
  workerLogger.info('worker.turn_started', 'worker turn started', {
    signal_id: turnStart.turn.signal_id,
    operation: turnOperation(turnStart.turn.signal_id)
  })
  const rpc = throwingRPCRequester(rpcClient, active.abortSignal)
  const drive = new Drive({ agentHome: paths.home, rpc })
  const cliBridges = startRunCLIBridges({ drive, rpc, turn: turnStart.turn, workspaceRoot })

  try {
    const runtimeEnv = { ...turnStart.runtime_env, ...cliBridges.env }

    await materializeSkills(drive, paths.installedSkills)
    active.abortSignal.throwIfAborted()

    await runCodexJob(turnStart, {
      agentHome: paths.home,
      workspaceRoot,
      drive,
      builtinSkillsRoot: config.builtinSkillsRoot,
      agentInstalledSkillsRoot: paths.installedSkills,
      internalSkillsRoot: config.internalSkillsRoot,
      runtimeEnv,
      rpc,
      requestAIGatewayAPIKey: options => requestAIGatewayAPIKey(rpcClient, { ...options, signal: active.abortSignal }),
      logger: workerLogger,
      pollSteering: () => active.pollSteering(),
      pollDisabledSkills: () => active.pollDisabledSkills(),
      abortSignal: active.abortSignal,
      browserRuntime
    })
  } finally {
    cliBridges.close()
  }
}

function turnOperation(signalID: string): { id: string; producer: string } {
  return {
    id: signalID,
    producer: 'ankole-worker/turn'
  }
}
