import * as kernel from '../../kernel'
import {
  mailboxUpdatedFromEnvelope,
  turnControlFromEnvelope,
  turnStartFromEnvelope,
  type ActorTurnRef,
  type TurnStart,
  type TurnSteerUpdate
} from './actor_lane'
import { runLlmTurnHandlers } from './core'
import { finalProposalEnvelope, turnAcceptedEnvelope, turnErrorEnvelope } from './turn_envelopes'
import type {
  AgentConversationContext,
  AgentConversationContextRequest,
  AIGatewayApiKeyRejected,
  AIGatewayApiKeyRequest,
  AIGatewayApiKeyResponse,
  ConversationHistoryRequest,
  ConversationHistoryResponse,
  ConversationSummaryCommitRequest,
  ConversationSummaryCommitResponse,
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
const aiGatewayApiKeyRefreshSkewMs = 60_000
const aiGatewayApiKeyCache = new Map<string, AIGatewayApiKeyResponse>()

type ActiveTurn = {
  turnStart: TurnStart
  correlationId: string
  steeringUpdates: TurnSteerUpdate[]
  abortController: AbortController
  retryRequested: boolean
  retryReason?: string
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
    await sendEnvelope(workerReadyEnvelope(config, 1))
    await sendEnvelope(workerCapacityEnvelope(config, 1, 0))
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
 * Capacity, ack, RPC, and final proposal sends still fail loudly after bounded
 * retry. Heartbeat is different: it is periodically refreshed ephemeral state,
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
    llm_turn_id: turnStart.turn.llm_turn_id,
    input_count: turnStart.inputs.length
  })

  if (activeTurns.size > 0) {
    await sendEnvelope(
      turnErrorEnvelope(turnStart.turn, 'worker_busy', 'worker already has an active turn', correlationId, {
        runtime: 'bun'
      })
    )
    return
  }

  const active: ActiveTurn = {
    turnStart,
    correlationId,
    steeringUpdates: [],
    abortController: new AbortController(),
    retryRequested: false,
    controlledStopRequested: false
  }
  activeTurns.set(turnKey(turnStart.turn), active)

  await sendEnvelope(
    turnAcceptedEnvelope(
      turnStart.turn,
      turnStart.inputs.map(input => input.actor_input_id),
      correlationId
    )
  )
  await sendEnvelope(workerCapacityEnvelope(config, 0, 1))

  void runActiveTurnTask(config, sendEnvelope, rpcClient, active, activeTurns).catch(error => {
    process.stderr.write(
      `${JSON.stringify({
        event: 'worker.turn_completion_error',
        llm_turn_id: turnStart.turn.llm_turn_id,
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

  try {
    await runActiveTurn(config, sendEnvelope, rpcClient, active)
    if (active.controlledStopRequested) {
      logWorkerEvent('worker.turn_controlled_stop', {
        llm_turn_id: turnStart.turn.llm_turn_id,
        command: active.controlledStopCommand ?? 'unknown',
        reason: active.controlledStopReason ?? 'controlled_stop'
      })
      return
    }

    logWorkerEvent('worker.turn_completed', {
      llm_turn_id: turnStart.turn.llm_turn_id
    })
  } catch (error) {
    if (active.controlledStopRequested) {
      logWorkerEvent('worker.turn_controlled_stop', {
        llm_turn_id: turnStart.turn.llm_turn_id,
        command: active.controlledStopCommand ?? 'unknown',
        reason: active.controlledStopReason ?? 'controlled_stop',
        error: error instanceof Error ? error.message : String(error)
      })
      return
    }

    const message = error instanceof Error ? error.message : String(error)

    await sendEnvelope(turnErrorEnvelope(turnStart.turn, 'worker_turn_failed', message, active.correlationId))
    logWorkerEvent(
      'worker.turn_failed',
      {
        llm_turn_id: turnStart.turn.llm_turn_id,
        error: error instanceof Error ? error.message : String(error)
      },
      'stderr'
    )
  } finally {
    activeTurns.delete(turnKey(turnStart.turn))
    await sendEnvelope(workerCapacityEnvelope(config, 1, 0))
  }
}

async function runActiveTurn(
  config: WorkerConfig,
  sendEnvelope: ReliableEnvelopeSender,
  rpcClient: RuntimeRpcClient,
  active: ActiveTurn
): Promise<void> {
  const turnStart = active.turnStart
  const workspaceRoot = prepareTurnWorkspace(config, turnStart)
  logWorkerEvent('worker.llm_turn_started', {
    llm_turn_id: turnStart.turn.llm_turn_id
  })

  const proposal = await runLlmTurnHandlers(turnStart, {
    workspaceRoot,
    builtinSkillsRoot: config.builtinSkillsRoot,
    agentInstalledSkillsRoot: config.agentInstalledSkillsRoot,
    requestAIGatewayApiKey: request => requestAIGatewayApiKey(rpcClient, request),
    requestAgentConversationContext: request => requestAgentConversationContext(rpcClient, request),
    requestConversationHistory: request => requestConversationHistory(rpcClient, request),
    commitConversationSummary: request => commitConversationSummary(rpcClient, request),
    requestScheduleRpc: (method, request) => requestScheduleRpc(rpcClient, method, request),
    requestSkillOverlay: request => requestSkillOverlay(rpcClient, request),
    replaceSkillOverlay: request => replaceSkillOverlay(rpcClient, request),
    clearSkillOverlay: request => clearSkillOverlay(rpcClient, request),
    pollSteering: () => active.steeringUpdates.splice(0),
    abortSignal: active.abortController.signal
  })

  if (active.controlledStopRequested) return
  if ('summaryCommitted' in proposal) return

  await sendEnvelope(finalProposalEnvelope(turnStart.turn, proposal, active.correlationId))
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
  if (!update.turn || !Array.isArray(update.inputs) || update.inputs.length === 0) {
    return
  }

  const active = activeTurns.get(turnKey(update.turn))
  if (!active) return

  active.steeringUpdates.push({ turn: update.turn, inputs: update.inputs })
  await sendEnvelope(
    turnAcceptedEnvelope(
      update.turn,
      update.inputs.map(input => input.actor_input_id),
      envelope.message_id
    )
  )
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

  if (control.command === 'retry') {
    active.retryRequested = true
    active.retryReason = reason
  }

  active.abortController.abort(new DOMException(reason, 'AbortError'))
}

async function requestAIGatewayApiKey(
  rpcClient: RuntimeRpcClient,
  request: AIGatewayApiKeyRequest
): Promise<AIGatewayApiKeyResponse | AIGatewayApiKeyRejected> {
  const cacheKey = `${request.agent_uid}\n${request.session_id}`
  const cached = aiGatewayApiKeyCache.get(cacheKey)
  if (cached && cached.expires_at * 1000 > Date.now() + aiGatewayApiKeyRefreshSkewMs) {
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
      session_id: stringFromDetails(response, 'session_id') || request.session_id,
      code: response.code,
      message: response.message
    }
  }

  const apiKey = response.payload_json as AIGatewayApiKeyResponse
  aiGatewayApiKeyCache.set(cacheKey, apiKey)
  return apiKey
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

async function requestConversationHistory(
  rpcClient: RuntimeRpcClient,
  request: ConversationHistoryRequest
): Promise<ConversationHistoryResponse> {
  const response = await rpcClient.request(rpcMethods.conversationHistoryResolve, request, request.request_id)
  if ('code' in response) {
    throw new Error(`conversation history RPC failed: ${response.code} ${response.message ?? ''}`.trim())
  }
  return response.payload_json as ConversationHistoryResponse
}

async function commitConversationSummary(
  rpcClient: RuntimeRpcClient,
  request: ConversationSummaryCommitRequest
): Promise<ConversationSummaryCommitResponse> {
  const response = await rpcClient.request(rpcMethods.conversationSummaryCommit, request, request.request_id)
  if ('code' in response) {
    throw new Error(`conversation summary commit RPC failed: ${response.code} ${response.message ?? ''}`.trim())
  }
  return response.payload_json as ConversationSummaryCommitResponse
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

async function clearSkillOverlay(
  rpcClient: RuntimeRpcClient,
  request: SkillOverlayRequest
): Promise<SkillOverlayResponse> {
  const response = await rpcClient.request(rpcMethods.skillsOverlayClear, request, request.request_id)
  if ('code' in response) {
    throw new Error(`skill overlay clear RPC failed: ${response.code} ${response.message ?? ''}`.trim())
  }
  return response.payload_json as SkillOverlayResponse
}

function stringFromDetails(source: RpcError | JsonObject | undefined, key: string): string | undefined {
  const details = (source && 'details_json' in source ? source.details_json : source) as JsonObject | undefined
  const value = details?.[key]
  return typeof value === 'string' ? value : undefined
}

function turnKey(turn: ActorTurnRef): string {
  return `${turn.activation_uid}:${turn.llm_turn_id}`
}
