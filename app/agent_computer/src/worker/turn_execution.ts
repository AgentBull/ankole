import type { ReplyPresentationEvent } from '../core'
import { agentHomePaths } from '../core/agent-home-paths'
import {
  AUTOMATION_JOB_CLI_SOCKET_ENV,
  buildTurnRuntimeEnv,
  WEBHOOK_CLI_SOCKET_ENV
} from '../core/execution/turn_runtime_env'
import { runTurnHandlers } from '../core/turns'
import { startAutomationJobCLIBridge } from '../cli/automation-jobs/automation-job-cli-bridge'
import { startWebhookCLIBridge } from '../cli/webhooks/webhook-cli-bridge'
import { turnAcceptedEnvelope, workerProgressEnvelope } from '../fabric/envelopes'
import type { EnvelopeSender } from '../fabric/fabric'
import { automationJobRPCRequester, type RuntimeRPCClient, webhookRPCRequester } from '../lanes/rpc_lane'
import type { BrowserRuntime } from '../browser-runtime'
import { syncInstalledSkillsForTurn } from '../skills/installed_skill_sync'
import type { ActiveTurn } from './active_turns'
import type { WorkerConfig } from './config'
import { workerLogger } from './logging'
import { requestAIGatewayAPIKey, throwingRPCRequester } from './rpc_requests'
import { completeTurnWithAck, noopTurnWithAck } from './turn_completion'
import { prepareTurnWorkspace } from './workspace'
import { toError } from '../common/errors'

/**
 * Materializes the workspace, environment, CLI bridges, Skills, and handler
 * dependencies for one accepted Turn. It commits complete and no-op results.
 * ActiveTurns owns admission, failures, controlled stops, and release.
 */
export async function executeActiveTurn(
  config: WorkerConfig,
  browserRuntime: BrowserRuntime,
  sendEnvelope: EnvelopeSender,
  rpcClient: RuntimeRPCClient,
  active: ActiveTurn,
  onTurnActivity: (description?: string) => void
): Promise<void> {
  const turnStart = active.turnStart
  const workspaceRoot = prepareTurnWorkspace(config, turnStart)
  const paths = agentHomePaths(config.agentsRoot, turnStart.turn.actor.agent_uid)
  workerLogger.info('worker.turn_started', 'worker turn started', {
    actor_event_id: turnStart.turn.actor_event_id,
    operation: turnOperation(turnStart.turn.actor_event_id)
  })
  const rpc = throwingRPCRequester(rpcClient)
  // Both bridges listen on their own Unix socket, so they enter the try block
  // that closes them: a failure while opening the second one, or while building
  // the environment, would otherwise leave the first listener behind for the
  // life of this long-running Worker.
  let webhookCLI: ReturnType<typeof startWebhookCLIBridge> | undefined
  let automationJobCLI: ReturnType<typeof startAutomationJobCLIBridge> | undefined

  try {
    webhookCLI = startWebhookCLIBridge({
      turnStart,
      requestWebhookRPC: webhookRPCRequester(rpc, turnStart.turn)
    })
    automationJobCLI = startAutomationJobCLIBridge({
      agentHome: paths.home,
      requestAutomationJobRPC: automationJobRPCRequester(rpc, turnStart.turn)
    })
    const runtimeEnv = {
      ...buildTurnRuntimeEnv(turnStart, config.workerAuthKey),
      [WEBHOOK_CLI_SOCKET_ENV]: webhookCLI.socketPath,
      [AUTOMATION_JOB_CLI_SOCKET_ENV]: automationJobCLI.socketPath
    }

    await syncInstalledSkillsForTurn(turnStart, {
      agentInstalledSkillsRoot: paths.installedSkills,
      rpc,
      abortSignal: active.abortSignal,
      logger: workerLogger
    })

    const result = await runTurnHandlers(turnStart, {
      agentsRoot: config.agentsRoot,
      agentHome: paths.home,
      workspaceRoot,
      userFilesRoot: paths.userFiles,
      builtinSkillsRoot: config.builtinSkillsRoot,
      agentInstalledSkillsRoot: paths.installedSkills,
      internalSkillsRoot: config.internalSkillsRoot,
      runtimeEnv,
      rpc,
      requestAIGatewayAPIKey: (agentUid, options) => requestAIGatewayAPIKey(rpcClient, agentUid, options),
      logger: workerLogger,
      pollSteering: () => active.pollSteering(),
      waitForSteering: signal => active.waitForSteering(signal),
      pollDisabledSkills: () => active.pollDisabledSkills(),
      onSteeringApplied: update =>
        sendEnvelope(turnAcceptedEnvelope(update.turn, update.correlationID ?? active.correlationID)),
      onTurnActivity,
      onPresentationEvent: event => sendReplyPresentationProgress(sendEnvelope, active, event),
      abortSignal: active.abortSignal,
      browserRuntime
    })

    if (active.controlledStopRequested) return

    if (result.kind === 'noop_completed') {
      await noopTurnWithAck(rpcClient, turnStart.turn, result, {
        onRetry: (attempt, error) => {
          workerLogger.warning('worker.turn_noop_retry', 'worker turn no-op acknowledgement missing', {
            actor_event_id: turnStart.turn.actor_event_id,
            attempt,
            error: toError(error)
          })
        }
      })
      return
    }

    await completeTurnWithAck(rpcClient, turnStart.turn, result.finalResponseID, result.outcome, {
      onRetry: (attempt, error) => {
        workerLogger.warning('worker.turn_completion_retry', 'worker turn completion acknowledgement missing', {
          actor_event_id: turnStart.turn.actor_event_id,
          attempt,
          error: toError(error)
        })
      }
    })
  } finally {
    automationJobCLI?.close()
    webhookCLI?.close()
  }
}

/** Presentation progress is ephemeral; a send failure must not fail the Turn. */
async function sendReplyPresentationProgress(
  sendEnvelope: EnvelopeSender,
  active: ActiveTurn,
  event: ReplyPresentationEvent
): Promise<void> {
  try {
    await sendEnvelope(
      workerProgressEnvelope(
        active.turnStart.turn,
        'reply_presentation',
        'reply presentation updated',
        active.correlationID,
        { presentation_event: event }
      )
    )
  } catch (error) {
    workerLogger.warning('worker.reply_presentation_send_failed', 'worker reply presentation event failed', {
      actor_event_id: active.turnStart.turn.actor_event_id,
      event_kind: event.kind,
      error: toError(error)
    })
  }
}

function turnOperation(actorEventID: string): { id: string; producer: string } {
  return {
    id: actorEventID,
    producer: 'ankole-worker/turn'
  }
}
