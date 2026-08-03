import { match, type JsonObject as JSONObject } from '@agentbull/active-support'
import { mailboxUpdatedFromEnvelope, turnControlFromEnvelope, turnStartFromEnvelope } from './lanes/actor_lane'
import { runTurnHandlers, type ReplyPresentationEvent } from './core'
import {
  controlShutdownEnvelope,
  turnAcceptedEnvelope,
  turnErrorEnvelope,
  turnNoopCompletedEnvelope,
  workerProgressEnvelope
} from './fabric/envelopes'
import {
  RuntimeRPCClient,
  automationJobRPCRequester,
  handleWorkerRPCRequest,
  webhookRPCRequester
} from './lanes/rpc_lane'
import { loadWorkerConfig, workerCapacityEnvelope, workerHeartbeatEnvelope, workerReadyEnvelope } from './worker/config'
import type { WorkerConfig } from './worker/config'
import { connectRuntimeFabric, isRuntimeFabricTransportError, type EnvelopeSender } from './fabric/fabric'
import type { Envelope } from './fabric/envelope_proto'
import { prepareTurnWorkspace, verifyWorkerFilesystem } from './worker/workspace'
import { createFileTransferLane } from './lanes/file'
import { resolveBubblewrapSupport } from './tools/computer/bubblewrap'
import { syncInstalledSkillsForTurn } from './skills/installed_skill_sync'
import {
  availableTurnSlots,
  startTurnProgress,
  turnFailureDetails,
  turnFailureLogFields,
  turnKey,
  type ActiveTurn
} from './worker/active_turns'
import { workerLogger } from './worker/logging'
import { requestAIGatewayAPIKey, stringFromDetails, throwingRPCRequester } from './worker/rpc_requests'
import { BrowserRuntime } from './browser-runtime'
import { agentHomePaths } from './core/agent-home-paths'
import {
  AUTOMATION_JOB_CLI_SOCKET_ENV,
  buildTurnRuntimeEnv,
  WEBHOOK_CLI_SOCKET_ENV
} from './core/turns/turn_runtime_env'
import { startWebhookCLIBridge } from './cli/webhooks/webhook-cli-bridge'
import { startAutomationJobCLIBridge } from './cli/automation-jobs/automation-job-cli-bridge'
import { runAutomationJob } from './automation-jobs/run'
import { WorkerDrainState } from './worker/drain'
import { completeTurnWithAck, TurnCompletionRejectedError } from './worker/turn_completion'
import { tryWithCodexHomeSetup } from './core/codex-runner/codex-home-setup'
import { deleteCodexLogs2AtDailyReset } from './tools/codex/fix-codex-logs2-sqlite-bug'

const heartbeatIntervalMs = 15_000

try {
  await runWorker()
} catch (error) {
  workerLogger.critical('worker.error', 'worker failed', { error: errorValue(error) })
  process.exit(1)
}

/**
 * Runs the long-lived Agent Computer worker process.
 *
 * The process owns live RuntimeFabric receive/send loops and in-memory active
 * turns only. Actor state, scheduling, and final commits remain control-plane
 * and PostgreSQL responsibilities.
 */
async function runWorker(): Promise<void> {
  const config = loadWorkerConfig()
  verifyWorkerFilesystem(config)
  logBubblewrapSupport(config.agentsRoot)

  const fabric = connectRuntimeFabric(config)
  const sendEnvelope = fabric.sendEnvelope
  const sendFileFrame = fabric.sendFileFrame
  const rpcClient = new RuntimeRPCClient(sendEnvelope)
  const activeTurns = new Map<string, ActiveTurn>()
  const drain = new WorkerDrainState()
  const fileLane = createFileTransferLane(config, sendFileFrame)
  const browserRuntime = new BrowserRuntime({
    runtimeRoot: '/tmp/ankole-agent-computer',
    ...(process.env.ANKOLE_BROWSER_DAEMON_SOCKET ? { socketPath: process.env.ANKOLE_BROWSER_DAEMON_SOCKET } : {}),
    ...(process.env.ANKOLE_BROWSER_NODE ? { nodePath: process.env.ANKOLE_BROWSER_NODE } : {}),
    ...(process.env.ANKOLE_BROWSER_DAEMON_ENTRY ? { daemonEntry: process.env.ANKOLE_BROWSER_DAEMON_ENTRY } : {}),
    ...(process.env.ANKOLE_BROWSER_RUNNER ? { runnerPath: process.env.ANKOLE_BROWSER_RUNNER } : {}),
    ...(process.env.ANKOLE_BROWSER_CHROMIUM_EXECUTABLE
      ? { localChromiumExecutable: process.env.ANKOLE_BROWSER_CHROMIUM_EXECUTABLE }
      : {}),
    onDaemonEvent: event => workerLogger.info(`browser.daemon_${event.kind}`, 'browser daemon lifecycle', event),
    onWebFetchFailure: event =>
      workerLogger.warning('browser.rendered_fetch_failed', 'rendered browser fetch failed', {
        backend_kind: event.backendKind,
        stage: event.stage,
        error_code: event.errorCode,
        error_message: event.errorMessage,
        retryable: event.retryable,
        ...(event.urlIndex === undefined ? {} : { url_index: event.urlIndex }),
        ...(event.urlScheme === undefined ? {} : { url_scheme: event.urlScheme }),
        ...(event.urlHost === undefined ? {} : { url_host: event.urlHost })
      })
  })
  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      drain.begin(signal.toLowerCase())
    })
  }

  try {
    await browserRuntime.start()
    await sendEnvelope(workerReadyEnvelope(config, availableTurnSlots(config, activeTurns)))
    await sendEnvelope(workerCapacityEnvelope(config, availableTurnSlots(config, activeTurns), activeTurns.size))
    workerLogger.notice('worker.ready_sent', 'worker ready sent', {
      endpoint: config.endpoint,
      worker_id: config.workerID
    })

    let nextHeartbeatAt = Date.now() + heartbeatIntervalMs
    let shutdownReported = false

    for (;;) {
      if (!drain.acceptsTurns && !shutdownReported) {
        try {
          await sendEnvelope(controlShutdownEnvelope(drain.reason ?? 'process_shutdown'))
          shutdownReported = true
          workerLogger.notice('worker.draining', 'worker draining active tasks', {
            reason: drain.reason,
            active_tasks: drain.activeTaskCount,
            active_turns: activeTurns.size
          })
        } catch (error) {
          workerLogger.warning('worker.drain_report_failed', 'worker drain report failed', {
            reason: drain.reason,
            error: errorValue(error)
          })
        }
      }

      if (!drain.shouldContinue) break

      if (Date.now() >= nextHeartbeatAt) {
        await sendHeartbeat(
          sendEnvelope,
          workerHeartbeatEnvelope(config, Math.floor(performance.now()), activeTurns.size)
        )
        nextHeartbeatAt = Date.now() + heartbeatIntervalMs
      }

      const received = await fabric.receive(500)
      if (received.kind === 'timeout') continue

      if (received.kind === 'worker_file') {
        await fileLane.handle(received.frames)
        continue
      }

      const envelope = received.envelope
      workerLogger.debug('worker.envelope_received', 'runtime fabric envelope received', {
        envelope_type: envelope.body.case,
        message_id: envelope.messageId
      })
      await handleEnvelope(config, browserRuntime, sendEnvelope, rpcClient, activeTurns, drain, envelope)
    }
  } finally {
    try {
      await browserRuntime.stop()
    } finally {
      fabric.stop()
    }
  }
}

/**
 * Logs whether command tools can use the stronger bubblewrap isolation mode.
 *
 * Weak mode is allowed because the worker still runs inside the Agent Computer
 * container; the warning tells operators which host/container setting to fix.
 */
function logBubblewrapSupport(workspaceRoot: string): void {
  const support = resolveBubblewrapSupport(workspaceRoot)
  if (support.mode === 'strong') {
    workerLogger.info('worker.bubblewrap_ready', 'worker bubblewrap ready', { mode: 'strong' })
    return
  }

  workerLogger.warning(
    'worker.bubblewrap_warning',
    'Strong bubblewrap is unavailable; using weaker nested bubblewrap with the container procfs. Prefer Docker/Kubernetes settings that allow a fresh bwrap /proc mount.',
    {
      mode: 'weak',
      strong_probe_error: support.strong.ok ? undefined : support.strong.reason
    }
  )
}

/**
 * Sends heartbeat as best-effort liveness, not as a worker-fatal control fact.
 *
 * Capacity, ack, and RPC sends still fail loudly after bounded retry. Heartbeat
 * is different: it is periodically refreshed ephemeral state,
 * and killing the worker because one heartbeat hit a full ZeroMQ pipe creates a
 * worse failure mode than letting the control plane expire the lease if the pipe
 * is actually broken.
 */
async function sendHeartbeat(sendEnvelope: EnvelopeSender, heartbeat: Envelope): Promise<void> {
  try {
    await sendEnvelope(heartbeat)
  } catch (error) {
    if (!isRuntimeFabricTransportError(error, 'backpressure')) {
      throw error
    }

    workerLogger.warning('worker.heartbeat_skipped', 'worker heartbeat skipped', { reason: 'backpressure' })
  }
}

/**
 * Routes one decoded RuntimeFabric envelope to the lane-specific handler.
 *
 * Unknown envelope body types are ignored because this worker may share the
 * fabric with newer control-plane senders; durable compatibility checks live at
 * typed lane boundaries instead.
 */
async function handleEnvelope(
  config: WorkerConfig,
  browserRuntime: BrowserRuntime,
  sendEnvelope: EnvelopeSender,
  rpcClient: RuntimeRPCClient,
  activeTurns: Map<string, ActiveTurn>,
  drain: WorkerDrainState,
  envelope: Envelope
): Promise<void> {
  const body = envelope.body

  return match(body)
    .with({ case: 'rpcResponse' }, ({ value }) => {
      rpcClient.resolve(value)
    })
    .with({ case: 'rpcError' }, ({ value }) => {
      rpcClient.resolve(value)
    })
    .with({ case: 'rpcRequest' }, ({ value }) => {
      drain.track(
        handleWorkerRPCRequest(sendEnvelope, value, {
          runAutomationJob: request =>
            runAutomationJob(request, {
              config,
              rpc: throwingRPCRequester(rpcClient)
            }),
          maintainCodexLogs2: async request => {
            const codexHome = agentHomePaths(config.agentsRoot, request.agentUid).codexHome
            const maintenance = await tryWithCodexHomeSetup(codexHome, async () =>
              deleteCodexLogs2AtDailyReset(codexHome)
            )
            if (!maintenance.acquired) {
              workerLogger.info('worker.codex_logs2_daily_maintenance', 'Codex logs daily maintenance skipped', {
                agent_uid: request.agentUid,
                status: 'skipped_setup_busy'
              })
              return {
                status: 'skipped_setup_busy',
                deletedFiles: [],
                activeCodexProcesses: 0
              }
            }

            const result = maintenance.value
            workerLogger.info('worker.codex_logs2_daily_maintenance', 'Codex logs daily maintenance completed', {
              agent_uid: request.agentUid,
              status: result.status,
              deleted_files: result.deletedFiles,
              active_codex_processes: result.status === 'skipped_codex_running' ? result.activeCodexProcesses : 0
            })
            return {
              status: result.status,
              deletedFiles: result.deletedFiles,
              activeCodexProcesses: result.status === 'skipped_codex_running' ? result.activeCodexProcesses : 0
            }
          }
        }).catch(error => {
          workerLogger.error('worker.rpc_reply_failed', 'worker RPC reply failed', {
            method: value.method,
            error: errorValue(error)
          })
        })
      )
    })
    .with({ case: 'turnStart' }, () =>
      startTurn(config, browserRuntime, sendEnvelope, rpcClient, activeTurns, drain, envelope)
    )
    .with({ case: 'mailboxUpdated' }, () => handleMailboxUpdated(sendEnvelope, activeTurns, envelope))
    .with({ case: 'turnControl' }, () => handleTurnControl(activeTurns, envelope))
    .otherwise(() => undefined)
}

/**
 * Accepts and launches one turn if this worker has capacity.
 *
 * The acceptance envelope is sent before the async task starts so the control
 * plane can fence duplicate deliveries and observe that the worker took
 * responsibility for this actor event.
 */
async function startTurn(
  config: WorkerConfig,
  browserRuntime: BrowserRuntime,
  sendEnvelope: EnvelopeSender,
  rpcClient: RuntimeRPCClient,
  activeTurns: Map<string, ActiveTurn>,
  drain: WorkerDrainState,
  envelope: Envelope
): Promise<void> {
  const turnStart = turnStartFromEnvelope(envelope)
  const correlationID = envelope.messageId
  workerLogger.info('worker.turn_start_received', 'worker turn start received', {
    actor_event_id: turnStart.turn.actor_event_id,
    input_count: 1,
    operation: turnOperation(turnStart.turn.actor_event_id, { first: true })
  })

  const activeKey = turnKey(turnStart.turn)

  if (!drain.acceptsTurns) {
    await sendEnvelope(
      turnErrorEnvelope(turnStart.turn, 'worker_draining', 'worker is draining', correlationID, {
        runtime: 'bun',
        retryable: true
      })
    )
    return
  }

  if (activeTurns.has(activeKey)) {
    await sendEnvelope(
      turnErrorEnvelope(turnStart.turn, 'worker_busy', 'conversation already has an active turn', correlationID, {
        runtime: 'bun',
        retryable: true
      })
    )
    return
  }

  if (activeTurns.size >= config.maxConcurrentTurns) {
    await sendEnvelope(
      turnErrorEnvelope(turnStart.turn, 'worker_busy', 'worker has no available turn slots', correlationID, {
        runtime: 'bun',
        retryable: true,
        active_turns: activeTurns.size,
        max_turns: config.maxConcurrentTurns
      })
    )
    return
  }

  const active: ActiveTurn = {
    turnStart,
    correlationID,
    steeringUpdates: [],
    abortController: new AbortController(),
    controlledStopRequested: false
  }
  activeTurns.set(activeKey, active)

  await sendEnvelope(turnAcceptedEnvelope(turnStart.turn, correlationID))
  await sendEnvelope(workerCapacityEnvelope(config, availableTurnSlots(config, activeTurns), activeTurns.size))

  drain.track(
    runActiveTurnTask(config, browserRuntime, sendEnvelope, rpcClient, active, activeTurns).catch(error => {
      workerLogger.error('worker.turn_completion_error', 'worker turn completion task failed', {
        actor_event_id: turnStart.turn.actor_event_id,
        error: errorValue(error),
        operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
      })
    })
  )
}

/**
 * Owns the lifecycle wrapper around the actual turn execution.
 *
 * It sends progress, converts ordinary failures to turn_error, and always
 * publishes updated capacity after the active turn is removed.
 */
async function runActiveTurnTask(
  config: WorkerConfig,
  browserRuntime: BrowserRuntime,
  sendEnvelope: EnvelopeSender,
  rpcClient: RuntimeRPCClient,
  active: ActiveTurn,
  activeTurns: Map<string, ActiveTurn>
): Promise<void> {
  const turnStart = active.turnStart
  const startedAt = Date.now()
  const progress = startTurnProgress(sendEnvelope, active)

  try {
    await runActiveTurn(config, browserRuntime, sendEnvelope, rpcClient, active, progress.touch)
    if (active.controlledStopRequested) {
      workerLogger.info('worker.turn_controlled_stop', 'worker turn controlled stop', {
        actor_event_id: turnStart.turn.actor_event_id,
        command: active.controlledStopCommand ?? 'unknown',
        reason: active.controlledStopReason ?? 'controlled_stop',
        duration_ms: Date.now() - startedAt,
        operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
      })
      return
    }

    workerLogger.info('worker.turn_completed', 'worker turn completed', {
      actor_event_id: turnStart.turn.actor_event_id,
      duration_ms: Date.now() - startedAt,
      operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
    })
  } catch (error) {
    if (active.controlledStopRequested) {
      workerLogger.info('worker.turn_controlled_stop', 'worker turn controlled stop', {
        actor_event_id: turnStart.turn.actor_event_id,
        command: active.controlledStopCommand ?? 'unknown',
        reason: active.controlledStopReason ?? 'controlled_stop',
        duration_ms: Date.now() - startedAt,
        error: errorValue(error),
        operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
      })
      return
    }

    if (error instanceof TurnCompletionRejectedError) {
      workerLogger.error('worker.turn_completion_rejected', 'worker turn completion was rejected', {
        actor_event_id: turnStart.turn.actor_event_id,
        error: errorValue(error),
        operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
      })
      throw error
    }

    const message = error instanceof Error ? error.message : String(error)

    await sendEnvelope(
      turnErrorEnvelope(turnStart.turn, 'worker_turn_failed', message, active.correlationID, turnFailureDetails(error))
    )
    workerLogger.error('worker.turn_failed', 'worker turn failed', {
      actor_event_id: turnStart.turn.actor_event_id,
      duration_ms: Date.now() - startedAt,
      ...turnFailureLogFields(error),
      error: errorValue(error),
      operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
    })
  } finally {
    progress.stop()
    activeTurns.delete(turnKey(turnStart.turn))
    await sendEnvelope(workerCapacityEnvelope(config, availableTurnSlots(config, activeTurns), activeTurns.size))
  }
}

/**
 * Builds the turn-local runtime surface and runs the registered turn handlers.
 *
 * All control-plane state access is passed in as RPC callbacks so the turn code
 * cannot reach PostgreSQL-owned semantics directly.
 */
async function runActiveTurn(
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
  const webhookCLI = startWebhookCLIBridge({
    turnStart,
    requestWebhookRPC: webhookRPCRequester(rpc, turnStart.turn)
  })
  const automationJobCLI = startAutomationJobCLIBridge({
    agentHome: paths.home,
    requestAutomationJobRPC: automationJobRPCRequester(rpc, turnStart.turn)
  })
  const runtimeEnv = {
    ...buildTurnRuntimeEnv(turnStart, config.workerAuthKey),
    [WEBHOOK_CLI_SOCKET_ENV]: webhookCLI.socketPath,
    [AUTOMATION_JOB_CLI_SOCKET_ENV]: automationJobCLI.socketPath
  }

  try {
    await syncInstalledSkillsForTurn(turnStart, {
      agentInstalledSkillsRoot: paths.installedSkills,
      rpc,
      abortSignal: active.abortController.signal,
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
      pollSteering: () => active.steeringUpdates.splice(0),
      onSteeringApplied: update =>
        sendEnvelope(turnAcceptedEnvelope(update.turn, update.correlationID ?? active.correlationID)),
      onTurnActivity,
      onPresentationEvent: event => sendReplyPresentationProgress(sendEnvelope, active, event),
      abortSignal: active.abortController.signal,
      browserRuntime
    })

    if (active.controlledStopRequested) return

    if (result.kind === 'noop_completed') {
      await sendEnvelope(turnNoopCompletedEnvelope(turnStart.turn, result.reason, active.correlationID))
      return
    }

    await completeTurnWithAck(rpcClient, turnStart.turn, result.finalResponseID, result.outcome, {
      onRetry: (attempt, error) => {
        workerLogger.warning('worker.turn_completion_retry', 'worker turn completion acknowledgement missing', {
          actor_event_id: turnStart.turn.actor_event_id,
          attempt,
          error: errorValue(error)
        })
      }
    })
  } finally {
    automationJobCLI.close()
    webhookCLI.close()
  }
}

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
      error: errorValue(error)
    })
  }
}

function errorValue(error: unknown): unknown {
  return error instanceof Error ? error : new Error(String(error))
}

function turnOperation(actorEventID: string, flags: { first?: boolean; last?: boolean } = {}): JSONObject {
  return {
    id: actorEventID,
    producer: 'ankole-worker/turn',
    ...flags
  }
}

/**
 * Adds an active steering update to the matching in-flight turn.
 *
 * The update is accepted only when the mailbox event already contains the
 * journaled actor event; the worker must not synthesize steer text locally.
 */
async function handleMailboxUpdated(
  sendEnvelope: EnvelopeSender,
  activeTurns: Map<string, ActiveTurn>,
  envelope: Envelope
): Promise<void> {
  const update = mailboxUpdatedFromEnvelope(envelope)
  if (!update.turn) return

  const active = activeTurns.get(turnKey(update.turn))
  if (!active) return

  // Active steer carries the single already-journaled actor event that caused
  // this revision bump.
  active.steeringUpdates.push({
    turn: update.turn,
    actorEvent: update.actor_event,
    correlationID: envelope.messageId
  })

  // Normal text turns consume steering from the next model-loop boundary, so
  // queue admission is the application boundary. Background Agent Job turns call Codex
  // turn/steer and acknowledge only after app-server accepts the instruction.
  if (!active.turnStart.turn.actor.session_id.startsWith('job:')) {
    await sendEnvelope(turnAcceptedEnvelope(update.turn, envelope.messageId))
  }
}

/**
 * Handles active `/retry` and `/stop` controls by aborting the in-flight turn.
 *
 * The control is recorded as a controlled stop so the normal abort exception
 * does not become a durable worker failure.
 */
async function handleTurnControl(activeTurns: Map<string, ActiveTurn>, envelope: Envelope): Promise<void> {
  const control = turnControlFromEnvelope(envelope)
  if (!control.turn || (control.command !== 'retry' && control.command !== 'stop')) return

  const active = activeTurns.get(turnKey(control.turn))
  if (!active) return

  const reason = stringFromDetails(control.payload_json, 'reason') ?? control.command
  active.controlledStopRequested = true
  active.controlledStopCommand = control.command
  active.controlledStopReason = reason

  active.abortController.abort(new DOMException(reason, 'AbortError'))
}
