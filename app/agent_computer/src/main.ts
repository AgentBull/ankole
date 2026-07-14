import { match, type JsonObject as JSONObject } from '@pleisto/active-support'
import { mailboxUpdatedFromEnvelope, turnControlFromEnvelope, turnStartFromEnvelope } from './lanes/actor_lane'
import { runTurnHandlers, type ReplyPresentationEvent } from './core'
import {
  turnAcceptedEnvelope,
  turnCompletedEnvelope,
  turnErrorEnvelope,
  turnNoopCompletedEnvelope,
  workerProgressEnvelope
} from './fabric/envelopes'
import type { RPCError, RPCRequest, RPCResponse } from './lanes/rpc_lane'
import { RuntimeRPCClient, handleWorkerRPCRequest, rpcMethods } from './lanes/rpc_lane'
import { parseWorkerEnv, workerCapacityEnvelope, workerHeartbeatEnvelope, workerReadyEnvelope } from './worker/config'
import type { WorkerConfig } from './worker/config'
import {
  connectRuntimeFabric,
  isRuntimeFabricTransportError,
  type EnvelopeSender,
  type RuntimeFabricEnvelope
} from './fabric/fabric'
import { prepareTurnWorkspace, verifyWorkerFilesystem } from './worker/workspace'
import { createFileTransferLane } from './lanes/file'
import { resolveBubblewrapSupport } from './tools/computer/bubblewrap'
import { syncInstalledSkillsForTurn } from './skills/installed_skill_sync'
import {
  availableTurnSlots,
  startTurnProgress,
  turnFailureDetails,
  turnKey,
  type ActiveTurn
} from './worker/active_turns'
import { workerLogger } from './worker/logging'
import {
  appendSkillOverlay,
  replaceSkillOverlay,
  requestAgentConversationContext,
  requestAIGatewayAPIKey,
  requestSkillOverlay,
  replaceInstalledSkillObservations,
  stringFromDetails,
  throwingRPCRequester
} from './worker/rpc_requests'

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
  const config = parseWorkerEnv()
  verifyWorkerFilesystem(config)
  logBubblewrapSupport(config.workspaceRoot)

  const fabric = connectRuntimeFabric(config)
  const sendEnvelope = fabric.sendEnvelope
  const sendFileFrame = fabric.sendFileFrame
  const rpcClient = new RuntimeRPCClient(sendEnvelope)
  const activeTurns = new Map<string, ActiveTurn>()
  const fileLane = createFileTransferLane(config, sendFileFrame)
  let stopping = false

  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      stopping = true
    })
  }

  try {
    await sendEnvelope(workerReadyEnvelope(config, availableTurnSlots(config, activeTurns)))
    await sendEnvelope(workerCapacityEnvelope(config, availableTurnSlots(config, activeTurns), activeTurns.size))
    workerLogger.notice('worker.ready_sent', 'worker ready sent', {
      endpoint: config.endpoint,
      worker_id: config.workerID
    })

    let nextHeartbeatAt = Date.now() + heartbeatIntervalMs

    while (!stopping) {
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
        envelope_type: envelope.body.type,
        message_id: envelope.message_id
      })
      await handleEnvelope(config, sendEnvelope, rpcClient, activeTurns, envelope)
    }
  } finally {
    fabric.stop()
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
async function sendHeartbeat(sendEnvelope: EnvelopeSender, heartbeat: RuntimeFabricEnvelope): Promise<void> {
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
  sendEnvelope: EnvelopeSender,
  rpcClient: RuntimeRPCClient,
  activeTurns: Map<string, ActiveTurn>,
  envelope: RuntimeFabricEnvelope
): Promise<void> {
  return match(envelope.body.type)
    .with('rpc_response', () => {
      rpcClient.resolve(envelope.body.rpc_response as RPCResponse)
    })
    .with('rpc_error', () => {
      rpcClient.resolve(envelope.body.rpc_error as RPCError)
    })
    .with('rpc_request', () => handleWorkerRPCRequest(sendEnvelope, envelope.body.rpc_request as RPCRequest))
    .with('turn_start', () => startTurn(config, sendEnvelope, rpcClient, activeTurns, envelope))
    .with('mailbox_updated', () => handleMailboxUpdated(sendEnvelope, activeTurns, envelope))
    .with('turn_control', () => handleTurnControl(activeTurns, envelope))
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
  sendEnvelope: EnvelopeSender,
  rpcClient: RuntimeRPCClient,
  activeTurns: Map<string, ActiveTurn>,
  envelope: RuntimeFabricEnvelope
): Promise<void> {
  const turnStart = turnStartFromEnvelope(envelope)
  const correlationID = envelope.message_id
  workerLogger.info('worker.turn_start_received', 'worker turn start received', {
    actor_event_id: turnStart.turn.actor_event_id,
    input_count: 1,
    operation: turnOperation(turnStart.turn.actor_event_id, { first: true })
  })

  const activeKey = turnKey(turnStart.turn)

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

  void runActiveTurnTask(config, sendEnvelope, rpcClient, active, activeTurns).catch(error => {
    workerLogger.error('worker.turn_completion_error', 'worker turn completion task failed', {
      actor_event_id: turnStart.turn.actor_event_id,
      error: errorValue(error),
      operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
    })
  })
}

/**
 * Owns the lifecycle wrapper around the actual turn execution.
 *
 * It sends progress, converts ordinary failures to turn_error, and always
 * publishes updated capacity after the active turn is removed.
 */
async function runActiveTurnTask(
  config: WorkerConfig,
  sendEnvelope: EnvelopeSender,
  rpcClient: RuntimeRPCClient,
  active: ActiveTurn,
  activeTurns: Map<string, ActiveTurn>
): Promise<void> {
  const turnStart = active.turnStart
  const progress = startTurnProgress(sendEnvelope, active, {
    requireActivity: turnStart.turn.actor.session_id.startsWith('subagent:')
  })

  try {
    await runActiveTurn(config, sendEnvelope, rpcClient, active, progress.touch)
    if (active.controlledStopRequested) {
      workerLogger.info('worker.turn_controlled_stop', 'worker turn controlled stop', {
        actor_event_id: turnStart.turn.actor_event_id,
        command: active.controlledStopCommand ?? 'unknown',
        reason: active.controlledStopReason ?? 'controlled_stop',
        operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
      })
      return
    }

    workerLogger.info('worker.turn_completed', 'worker turn completed', {
      actor_event_id: turnStart.turn.actor_event_id,
      operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
    })
  } catch (error) {
    if (active.controlledStopRequested) {
      workerLogger.info('worker.turn_controlled_stop', 'worker turn controlled stop', {
        actor_event_id: turnStart.turn.actor_event_id,
        command: active.controlledStopCommand ?? 'unknown',
        reason: active.controlledStopReason ?? 'controlled_stop',
        error: errorValue(error),
        operation: turnOperation(turnStart.turn.actor_event_id, { last: true })
      })
      return
    }

    const message = error instanceof Error ? error.message : String(error)

    await sendEnvelope(
      turnErrorEnvelope(turnStart.turn, 'worker_turn_failed', message, active.correlationID, turnFailureDetails(error))
    )
    workerLogger.error('worker.turn_failed', 'worker turn failed', {
      actor_event_id: turnStart.turn.actor_event_id,
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
  sendEnvelope: EnvelopeSender,
  rpcClient: RuntimeRPCClient,
  active: ActiveTurn,
  onTurnActivity: (description?: string) => void
): Promise<void> {
  const turnStart = active.turnStart
  const workspaceRoot = prepareTurnWorkspace(config, turnStart)
  workerLogger.info('worker.turn_started', 'worker turn started', {
    actor_event_id: turnStart.turn.actor_event_id,
    operation: turnOperation(turnStart.turn.actor_event_id)
  })
  await syncInstalledSkillsForTurn(turnStart, {
    agentInstalledSkillsRoot: config.agentInstalledSkillsRoot,
    replaceInstalledSkillObservations: request => replaceInstalledSkillObservations(rpcClient, request),
    logger: workerLogger
  })

  const result = await runTurnHandlers(turnStart, {
    workspaceRoot,
    workspaceSessionsRoot: config.workspaceSessionsRoot,
    sharedFsRoot: config.sharedFsRoot,
    userFilesRoot: config.userFilesRoot,
    builtinSkillsRoot: config.builtinSkillsRoot,
    agentInstalledSkillsRoot: config.agentInstalledSkillsRoot,
    internalSkillsRoot: config.internalSkillsRoot,
    requestAIGatewayAPIKey: (request, options) => requestAIGatewayAPIKey(rpcClient, request, options),
    requestAppConfigure: request => rpcClient.request(rpcMethods.appConfigureResolve, request),
    requestWorkerEnv: request => rpcClient.request(rpcMethods.workerEnvResolve, request),
    resolveCodexAccount: request => rpcClient.request(rpcMethods.codexAccountResolve, request),
    updateCodexAccountAuth: request => rpcClient.request(rpcMethods.codexAccountAuthUpdate, request),
    createSubagentDelegation: request => rpcClient.request(rpcMethods.subagentDelegationCreate, request),
    getSubagentDelegation: request => rpcClient.request(rpcMethods.subagentDelegationGet, request),
    listSubagentDelegations: request => rpcClient.request(rpcMethods.subagentDelegationList, request),
    steerSubagentDelegation: request => rpcClient.request(rpcMethods.subagentDelegationSteer, request),
    stopSubagentDelegation: request => rpcClient.request(rpcMethods.subagentDelegationStop, request),
    appendSubagentDelegationEvents: request => rpcClient.request(rpcMethods.subagentDelegationEventAppend, request),
    updateSubagentDelegationStatus: request => rpcClient.request(rpcMethods.subagentDelegationStatusUpdate, request),
    requestAgentConversationContext: request => requestAgentConversationContext(rpcClient, request),
    requestScheduleRPC: throwingRPCRequester(rpcClient, 'schedule RPC failed'),
    requestMemoryRPC: throwingRPCRequester(rpcClient, 'memory RPC failed'),
    requestSkillOverlay: request => requestSkillOverlay(rpcClient, request),
    appendSkillOverlay: request => appendSkillOverlay(rpcClient, request),
    replaceSkillOverlay: request => replaceSkillOverlay(rpcClient, request),
    pollSteering: () => active.steeringUpdates.splice(0),
    onSteeringApplied: update =>
      sendEnvelope(turnAcceptedEnvelope(update.turn, update.correlationID ?? active.correlationID)),
    onTurnActivity,
    onPresentationEvent: event => sendReplyPresentationProgress(sendEnvelope, active, event),
    abortSignal: active.abortController.signal
  })

  if (active.controlledStopRequested) return

  if (result.kind === 'noop_completed') {
    await sendEnvelope(turnNoopCompletedEnvelope(turnStart.turn, result.reason, active.correlationID))
    return
  }

  await sendEnvelope(
    turnCompletedEnvelope(turnStart.turn, result.finalResponseID, result.outcome, active.correlationID)
  )
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
  envelope: RuntimeFabricEnvelope
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
    correlationID: envelope.message_id
  })

  // Normal text turns consume steering from the next model-loop boundary, so
  // queue admission is the application boundary. Subagent turns call Codex
  // turn/steer and acknowledge only after app-server accepts the instruction.
  if (!active.turnStart.turn.actor.session_id.startsWith('subagent:')) {
    await sendEnvelope(turnAcceptedEnvelope(update.turn, envelope.message_id))
  }
}

/**
 * Handles active `/retry` and `/stop` controls by aborting the in-flight turn.
 *
 * The control is recorded as a controlled stop so the normal abort exception
 * does not become a durable worker failure.
 */
async function handleTurnControl(activeTurns: Map<string, ActiveTurn>, envelope: RuntimeFabricEnvelope): Promise<void> {
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
