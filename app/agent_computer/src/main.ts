import * as kernel from '../../kernel'
import {
  mailboxUpdatedFromEnvelope,
  turnControlFromEnvelope,
  turnStartFromEnvelope,
  type ActorTurnRef,
  type TurnStart,
  type TurnSteerUpdate
} from './actor_lane'
import { runTurnHandlers } from './core'
import { classifyLlmError } from './core/llm-error-classifier'
import {
  turnAcceptedEnvelope,
  turnErrorEnvelope,
  turnNoopCompletedEnvelope,
  workerProgressEnvelope
} from './turn_envelopes'
import type {
  AgentConversationContext,
  AgentConversationContextRequest,
  AIGatewayApiKeyRejected,
  AIGatewayApiKeyRequest,
  AIGatewayApiKeyResponse,
  AppConfigureResolveRejected,
  AppConfigureResolveRequest,
  AppConfigureResolveResponse,
  RpcError,
  RpcMethod,
  RpcRequest,
  RpcResponse,
  ScheduleRpcRequest,
  SkillOverlayReplaceRequest,
  SkillOverlayRequest,
  SkillOverlayResponse
} from './rpc_lane'
import { RuntimeRpcClient, handleWorkerRpcRequest, rpcMethods } from './rpc_lane'
import { parseWorkerEnv, workerCapacityEnvelope, workerHeartbeatEnvelope, workerReadyEnvelope } from './runtime'
import type { WorkerConfig } from './runtime'
import { decodeEnvelope, type JsonObject, type RuntimeFabricEnvelope } from './runtime_fabric'
import {
  isRuntimeFabricBackpressure,
  reliableEnvelopeSender,
  type ReliableEnvelopeSender
} from './runtime_fabric_sender'
import { prepareTurnWorkspace, verifyWorkerFilesystem } from './workspace'
import { createFileTransferState, handleFileTransferFrame, isFileTransferFrame } from './file_transfer_lane'
import { resolveBubblewrapSupport } from './tools/computer/bubblewrap'

const heartbeatIntervalMs = 15_000
const turnProgressIntervalMs = 60_000
const aiGatewayApiKeyRefreshSkewMs = 60_000
const aiGatewayApiKeyCache = new Map<string, AIGatewayApiKeyResponse>()

type ActiveTurn = {
  turnStart: TurnStart
  correlationId: string
  steeringUpdates: TurnSteerUpdate[]
  abortController: AbortController
  controlledStopRequested: boolean
  controlledStopCommand?: string
  controlledStopReason?: string
}

try {
  await runWorker()
} catch (error) {
  logWorkerEvent('worker.error', { error: error instanceof Error ? error.message : String(error) }, 'stderr')
  process.exit(1)
}

async function runWorker(): Promise<void> {
  const config = parseWorkerEnv()
  verifyWorkerFilesystem(config)
  logBubblewrapSupport(config.workspaceRoot)

  const dealer = new kernel.RuntimeFabricDealer(config.endpoint, config.workerId, config.workerId, config.workerAuthKey)
  const sendEnvelope = reliableEnvelopeSender(envelope => dealer.sendEnvelope(envelope))
  const rpcClient = new RuntimeRpcClient(sendEnvelope)
  const activeTurns = new Map<string, ActiveTurn>()
  const fileTransfers = createFileTransferState()
  let stopping = false

  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      stopping = true
    })
  }

  try {
    await sendEnvelope(workerReadyEnvelope(config, availableTurnSlots(config, activeTurns)))
    await sendEnvelope(workerCapacityEnvelope(config, availableTurnSlots(config, activeTurns), activeTurns.size))
    logWorkerEvent('worker.ready_sent', {
      endpoint: config.endpoint,
      worker_id: config.workerId
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

      const frames = await dealer.recvRawAsync(500)
      if (!frames) continue

      if (isFileTransferFrame(frames)) {
        await handleFileTransferFrame(config, dealer, fileTransfers, frames)
        continue
      }

      if (!frames[0]) continue
      const envelope = decodeEnvelope(frames[0])
      logWorkerEvent('worker.envelope_received', {
        type: envelope.body.type,
        message_id: envelope.message_id
      })
      await handleEnvelope(config, sendEnvelope, rpcClient, activeTurns, envelope)
    }
  } finally {
    dealer.stop()
  }
}

function logBubblewrapSupport(workspaceRoot: string): void {
  const support = resolveBubblewrapSupport(workspaceRoot)
  if (support.mode === 'strong') {
    logWorkerEvent('worker.bubblewrap_ready', { mode: 'strong' })
    return
  }

  logWorkerEvent(
    'worker.bubblewrap_warning',
    {
      mode: 'weak',
      strong_probe_error: support.strong.ok ? undefined : support.strong.reason,
      message:
        'Strong bubblewrap is unavailable; using weaker nested bubblewrap with the container procfs. Prefer Docker/Kubernetes settings that allow a fresh bwrap /proc mount.'
    },
    'stderr'
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
async function sendHeartbeat(sendEnvelope: ReliableEnvelopeSender, heartbeat: RuntimeFabricEnvelope): Promise<void> {
  try {
    await sendEnvelope(heartbeat)
  } catch (error) {
    if (!isRuntimeFabricBackpressure(error)) {
      throw error
    }

    process.stderr.write(
      `${JSON.stringify({
        event: 'worker.heartbeat_skipped',
        reason: 'backpressure'
      })}\n`
    )
  }
}

async function handleEnvelope(
  config: WorkerConfig,
  sendEnvelope: ReliableEnvelopeSender,
  rpcClient: RuntimeRpcClient,
  activeTurns: Map<string, ActiveTurn>,
  envelope: RuntimeFabricEnvelope
): Promise<void> {
  switch (envelope.body.type) {
    case 'rpc_response':
      rpcClient.resolve(envelope.body.rpc_response as RpcResponse)
      return

    case 'rpc_error':
      rpcClient.resolve(envelope.body.rpc_error as RpcError)
      return

    case 'rpc_request':
      return handleWorkerRpcRequest(config, sendEnvelope, activeTurns.size, envelope.body.rpc_request as RpcRequest)

    case 'turn_start':
      return startTurn(config, sendEnvelope, rpcClient, activeTurns, envelope)

    case 'mailbox_updated':
      return handleMailboxUpdated(sendEnvelope, activeTurns, envelope)

    case 'turn_control':
      return handleTurnControl(activeTurns, envelope)

    default:
      return
  }
}

async function startTurn(
  config: WorkerConfig,
  sendEnvelope: ReliableEnvelopeSender,
  rpcClient: RuntimeRpcClient,
  activeTurns: Map<string, ActiveTurn>,
  envelope: RuntimeFabricEnvelope
): Promise<void> {
  const turnStart = turnStartFromEnvelope(envelope)
  const correlationId = envelope.message_id
  logWorkerEvent('worker.turn_start_received', {
    actor_event_id: turnStart.turn.actor_event_id,
    input_count: 1
  })

  const activeKey = turnKey(turnStart.turn)

  if (activeTurns.has(activeKey)) {
    await sendEnvelope(
      turnErrorEnvelope(turnStart.turn, 'worker_busy', 'conversation already has an active turn', correlationId, {
        runtime: 'bun',
        retryable: true
      })
    )
    return
  }

  if (activeTurns.size >= config.maxConcurrentTurns) {
    await sendEnvelope(
      turnErrorEnvelope(turnStart.turn, 'worker_busy', 'worker has no available turn slots', correlationId, {
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
    correlationId,
    steeringUpdates: [],
    abortController: new AbortController(),
    controlledStopRequested: false
  }
  activeTurns.set(activeKey, active)

  await sendEnvelope(turnAcceptedEnvelope(turnStart.turn, correlationId))
  await sendEnvelope(workerCapacityEnvelope(config, availableTurnSlots(config, activeTurns), activeTurns.size))

  void runActiveTurnTask(config, sendEnvelope, rpcClient, active, activeTurns).catch(error => {
    process.stderr.write(
      `${JSON.stringify({
        event: 'worker.turn_completion_error',
        actor_event_id: turnStart.turn.actor_event_id,
        error: error instanceof Error ? error.message : String(error)
      })}\n`
    )
  })
}

async function runActiveTurnTask(
  config: WorkerConfig,
  sendEnvelope: ReliableEnvelopeSender,
  rpcClient: RuntimeRpcClient,
  active: ActiveTurn,
  activeTurns: Map<string, ActiveTurn>
): Promise<void> {
  const turnStart = active.turnStart
  const stopProgress = startTurnProgress(sendEnvelope, active)

  try {
    await runActiveTurn(config, sendEnvelope, rpcClient, active)
    if (active.controlledStopRequested) {
      logWorkerEvent('worker.turn_controlled_stop', {
        actor_event_id: turnStart.turn.actor_event_id,
        command: active.controlledStopCommand ?? 'unknown',
        reason: active.controlledStopReason ?? 'controlled_stop'
      })
      return
    }

    logWorkerEvent('worker.turn_completed', {
      actor_event_id: turnStart.turn.actor_event_id
    })
  } catch (error) {
    if (active.controlledStopRequested) {
      logWorkerEvent('worker.turn_controlled_stop', {
        actor_event_id: turnStart.turn.actor_event_id,
        command: active.controlledStopCommand ?? 'unknown',
        reason: active.controlledStopReason ?? 'controlled_stop',
        error: error instanceof Error ? error.message : String(error)
      })
      return
    }

    const message = error instanceof Error ? error.message : String(error)

    await sendEnvelope(
      turnErrorEnvelope(turnStart.turn, 'worker_turn_failed', message, active.correlationId, turnFailureDetails(error))
    )
    logWorkerEvent(
      'worker.turn_failed',
      {
        actor_event_id: turnStart.turn.actor_event_id,
        error: error instanceof Error ? error.message : String(error)
      },
      'stderr'
    )
  } finally {
    stopProgress()
    activeTurns.delete(turnKey(turnStart.turn))
    await sendEnvelope(workerCapacityEnvelope(config, availableTurnSlots(config, activeTurns), activeTurns.size))
  }
}

function availableTurnSlots(config: WorkerConfig, activeTurns: Map<string, ActiveTurn>): number {
  return Math.max(config.maxConcurrentTurns - activeTurns.size, 0)
}

function startTurnProgress(sendEnvelope: ReliableEnvelopeSender, active: ActiveTurn): () => void {
  let stopped = false
  let progressInFlight = false

  const sendProgress = (summary: string): void => {
    if (stopped || progressInFlight) return

    progressInFlight = true
    void sendTurnProgress(sendEnvelope, active, summary).finally(() => {
      progressInFlight = false
    })
  }

  sendProgress('turn started')
  const timer = setInterval(() => sendProgress('turn in progress'), turnProgressIntervalMs)
  timer.unref?.()

  return () => {
    stopped = true
    clearInterval(timer)
  }
}

async function sendTurnProgress(
  sendEnvelope: ReliableEnvelopeSender,
  active: ActiveTurn,
  summary: string
): Promise<void> {
  try {
    await sendEnvelope(workerProgressEnvelope(active.turnStart.turn, 'checkpoint', summary, active.correlationId))
  } catch (error) {
    logWorkerEvent(
      'worker.turn_progress_skipped',
      {
        actor_event_id: active.turnStart.turn.actor_event_id,
        reason: isRuntimeFabricBackpressure(error) ? 'backpressure' : 'send_error',
        error: error instanceof Error ? error.message : String(error)
      },
      'stderr'
    )
  }
}

function turnFailureDetails(error: unknown): JsonObject {
  const classification = classifyLlmError(error)
  const details: JsonObject = {
    runtime: 'bun',
    llm_error_kind: classification.kind,
    retryable: classification.retryable,
    should_compress: classification.shouldCompress,
    should_fallback_provider: classification.shouldFallbackProvider
  }

  const gateway = aigatewayErrorDetails(error)
  if (gateway) details.aigateway = gateway

  return details
}

function aigatewayErrorDetails(error: unknown): JsonObject | undefined {
  if (!error || typeof error !== 'object') return undefined

  const record = error as Record<string, unknown>
  const details: JsonObject = {}

  if (typeof record.code === 'string') details.code = record.code
  if (typeof record.status === 'number') details.status = record.status
  if (record.details && typeof record.details === 'object' && !Array.isArray(record.details)) {
    details.details_json = record.details as JsonObject
  }

  return Object.keys(details).length > 0 ? details : undefined
}

async function runActiveTurn(
  config: WorkerConfig,
  sendEnvelope: ReliableEnvelopeSender,
  rpcClient: RuntimeRpcClient,
  active: ActiveTurn
): Promise<void> {
  const turnStart = active.turnStart
  const workspaceRoot = prepareTurnWorkspace(config, turnStart)
  logWorkerEvent('worker.turn_started', {
    actor_event_id: turnStart.turn.actor_event_id
  })

  const result = await runTurnHandlers(turnStart, {
    workspaceRoot,
    builtinSkillsRoot: config.builtinSkillsRoot,
    agentInstalledSkillsRoot: config.agentInstalledSkillsRoot,
    requestAIGatewayApiKey: (request, options) => requestAIGatewayApiKey(rpcClient, request, options),
    requestAppConfigure: request => requestAppConfigure(rpcClient, request),
    requestAgentConversationContext: request => requestAgentConversationContext(rpcClient, request),
    requestScheduleRpc: (method, request) => requestScheduleRpc(rpcClient, method, request),
    requestSkillOverlay: request => requestSkillOverlay(rpcClient, request),
    replaceSkillOverlay: request => replaceSkillOverlay(rpcClient, request),
    pollSteering: () => active.steeringUpdates.splice(0),
    abortSignal: active.abortController.signal
  })

  if (active.controlledStopRequested) return

  if (result.kind === 'noop_completed') {
    await sendEnvelope(turnNoopCompletedEnvelope(turnStart.turn, result.reason, active.correlationId))
  }
}

function logWorkerEvent(
  event: string,
  fields: Record<string, unknown> = {},
  stream: 'stdout' | 'stderr' = 'stdout'
): void {
  const line = `${JSON.stringify({ event, ...fields })}\n`
  if (stream === 'stderr') {
    process.stderr.write(line)
    return
  }

  process.stdout.write(line)
}

async function handleMailboxUpdated(
  sendEnvelope: ReliableEnvelopeSender,
  activeTurns: Map<string, ActiveTurn>,
  envelope: RuntimeFabricEnvelope
): Promise<void> {
  const update = mailboxUpdatedFromEnvelope(envelope)
  if (!update.turn) {
    return
  }

  const active = activeTurns.get(turnKey(update.turn))
  if (!active) return

  // Active steer carries the single already-journaled actor event that caused
  // this revision bump.
  active.steeringUpdates.push({ turn: update.turn, actorEvent: update.actor_event })
  await sendEnvelope(turnAcceptedEnvelope(update.turn, envelope.message_id))
}

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

async function requestAIGatewayApiKey(
  rpcClient: RuntimeRpcClient,
  request: AIGatewayApiKeyRequest,
  options: { forceRefresh?: boolean } = {}
): Promise<AIGatewayApiKeyResponse | AIGatewayApiKeyRejected> {
  const cacheKey = request.agent_uid
  const cached = aiGatewayApiKeyCache.get(cacheKey)
  if (!options.forceRefresh && cached && cached.expires_at * 1000 > Date.now() + aiGatewayApiKeyRefreshSkewMs) {
    return { ...cached, request_id: request.request_id }
  }

  const response = await rpcClient.request(
    rpcMethods.aiGatewayApiKeyForCreateOrFindByAgent,
    request,
    request.request_id
  )
  if ('code' in response) {
    return {
      request_id: request.request_id,
      agent_uid: stringFromDetails(response, 'agent_uid') || request.agent_uid,
      code: response.code,
      message: response.message
    }
  }

  const apiKey = response.payload_json as AIGatewayApiKeyResponse
  aiGatewayApiKeyCache.set(cacheKey, apiKey)
  return apiKey
}

async function requestAppConfigure(
  rpcClient: RuntimeRpcClient,
  request: AppConfigureResolveRequest
): Promise<AppConfigureResolveResponse | AppConfigureResolveRejected> {
  const response = await rpcClient.request(rpcMethods.appConfigureResolve, request, request.request_id)
  if ('code' in response) {
    return {
      request_id: request.request_id,
      agent_uid: stringFromDetails(response, 'agent_uid') || request.agent_uid,
      code: response.code,
      message: response.message
    }
  }

  return response.payload_json as AppConfigureResolveResponse
}

async function requestAgentConversationContext(
  rpcClient: RuntimeRpcClient,
  request: AgentConversationContextRequest
): Promise<AgentConversationContext> {
  const response = await rpcClient.request(rpcMethods.agentConversationContextResolve, request, request.request_id)
  if ('code' in response) {
    throw new Error(`agent conversation context RPC failed: ${response.code} ${response.message ?? ''}`.trim())
  }
  return response.payload_json as AgentConversationContext
}

async function requestScheduleRpc(
  rpcClient: RuntimeRpcClient,
  method: RpcMethod,
  request: ScheduleRpcRequest
): Promise<JsonObject> {
  const response = await rpcClient.request(method, request as never, request.request_id)
  if ('code' in response) {
    throw new Error(`schedule RPC failed: ${response.code} ${response.message ?? ''}`.trim())
  }
  return (response.payload_json ?? {}) as JsonObject
}

async function requestSkillOverlay(
  rpcClient: RuntimeRpcClient,
  request: SkillOverlayRequest
): Promise<SkillOverlayResponse> {
  const response = await rpcClient.request(rpcMethods.skillsOverlayResolve, request, request.request_id)
  if ('code' in response) {
    throw new Error(`skill overlay RPC failed: ${response.code} ${response.message ?? ''}`.trim())
  }
  return response.payload_json as SkillOverlayResponse
}

async function replaceSkillOverlay(
  rpcClient: RuntimeRpcClient,
  request: SkillOverlayReplaceRequest
): Promise<SkillOverlayResponse> {
  const response = await rpcClient.request(rpcMethods.skillsOverlayReplace, request, request.request_id)
  if ('code' in response) {
    throw new Error(`skill overlay replace RPC failed: ${response.code} ${response.message ?? ''}`.trim())
  }
  return response.payload_json as SkillOverlayResponse
}

function stringFromDetails(source: RpcError | JsonObject | undefined, key: string): string | undefined {
  const details = (source && 'details_json' in source ? source.details_json : source) as JsonObject | undefined
  const value = details?.[key]
  return typeof value === 'string' ? value : undefined
}

function turnKey(turn: ActorTurnRef): string {
  return `${turn.activation_uid}:${turn.actor_event_id}`
}
