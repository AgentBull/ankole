import * as kernel from '../../kernel'
import {
  mailboxUpdatedFromEnvelope,
  turnStartFromEnvelope,
  type ActorLaneEnvelope,
  type ActorTurnRef,
  type TurnStart,
  type TurnSteerUpdate
} from './actor_lane'
import { runLlmTurnHandlers } from './llm_runtime/text_turn_loop'
import { finalProposalEnvelope, turnAcceptedEnvelope, turnErrorEnvelope } from './turn_envelopes'
import type {
  AgentProfile,
  AgentProfileRequest,
  LlmProviderCredentialRejected,
  LlmProviderCredentialRequest,
  LlmProviderCredentialResponse,
  RpcError,
  RpcMethod,
  RpcPayloadByMethod,
  RpcRequest,
  RpcResponse,
  SkillOverlayReplaceRequest,
  SkillOverlayRequest,
  SkillOverlayResponse,
  TurnContextRequest,
  TurnRuntimeContext
} from './rpc_lane'
import { rpcMethods, rpcRequestEnvelopeBody } from './rpc_lane'
import { parseWorkerEnv, workerCapacityEnvelope, workerHeartbeatEnvelope, workerReadyEnvelope } from './runtime'
import type { WorkerConfig } from './runtime'
import { decodeEnvelope, type JsonObject } from './runtime_fabric'
import {
  isRuntimeFabricBackpressure,
  reliableEnvelopeSender,
  type ReliableEnvelopeSender
} from './runtime_fabric_sender'
import { prepareTurnWorkspace, verifyWorkerFilesystem } from './workspace'
import { createFileTransferState, handleFileTransferFrame, isFileTransferFrame } from './file_transfer_lane'
import { resolveBubblewrapSupport } from './tools/computer/bubblewrap'

const heartbeatIntervalMs = 15_000
const rpcTimeoutMs = 60_000

type ActiveTurn = {
  turnStart: TurnStart
  correlationId: string
  steeringUpdates: TurnSteerUpdate[]
}

type RpcWaiter = {
  resolve: (response: RpcResponse | RpcError) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
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

  const dealer = new kernel.RuntimeFabricDealer(
    config.endpoint,
    config.workerInstanceId,
    config.workerId,
    config.preAuthToken
  )
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
      worker_id: config.workerId,
      worker_instance_id: config.workerInstanceId
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
async function sendHeartbeat(sendEnvelope: ReliableEnvelopeSender, heartbeat: ActorLaneEnvelope): Promise<void> {
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
  envelope: ActorLaneEnvelope
): Promise<void> {
  switch (envelope.body.type) {
    case 'rpc_response':
      rpcClient.resolve(envelope.body.rpc_response as RpcResponse)
      return

    case 'rpc_error':
      rpcClient.resolve(envelope.body.rpc_error as RpcError)
      return

    case 'turn_start':
      return startTurn(config, sendEnvelope, rpcClient, activeTurns, envelope)

    case 'mailbox_updated':
      return handleMailboxUpdated(sendEnvelope, activeTurns, envelope)

    default:
      return
  }
}

async function startTurn(
  config: WorkerConfig,
  sendEnvelope: ReliableEnvelopeSender,
  rpcClient: RuntimeRpcClient,
  activeTurns: Map<string, ActiveTurn>,
  envelope: ActorLaneEnvelope
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
    steeringUpdates: []
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
    logWorkerEvent('worker.turn_completed', {
      llm_turn_id: turnStart.turn.llm_turn_id
    })
  } catch (error) {
    await sendEnvelope(
      turnErrorEnvelope(
        turnStart.turn,
        'worker_turn_failed',
        error instanceof Error ? error.message : String(error),
        active.correlationId
      )
    )
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
  const runtimeContext = await requestTurnContext(rpcClient, {
    request_id: `turn-context-${crypto.randomUUID()}`,
    turn: turnStart.turn
  })
  logWorkerEvent('worker.turn_context_resolved', {
    llm_turn_id: turnStart.turn.llm_turn_id
  })
  const workspaceRoot = prepareTurnWorkspace(config, turnStart, runtimeContext)
  logWorkerEvent('worker.llm_turn_started', {
    llm_turn_id: turnStart.turn.llm_turn_id
  })

  const proposal = await runLlmTurnHandlers(turnStart, {
    workspaceRoot,
    runtimeContext,
    requestCredential: request => requestCredential(rpcClient, request),
    requestAgentProfile: request => requestAgentProfile(rpcClient, request),
    requestTurnContext: request => requestTurnContext(rpcClient, request),
    requestSkillOverlay: request => requestSkillOverlay(rpcClient, request),
    replaceSkillOverlay: request => replaceSkillOverlay(rpcClient, request),
    clearSkillOverlay: request => clearSkillOverlay(rpcClient, request),
    pollSteering: () => active.steeringUpdates.splice(0)
  })

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
  envelope: ActorLaneEnvelope
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

async function requestCredential(
  rpcClient: RuntimeRpcClient,
  request: LlmProviderCredentialRequest
): Promise<LlmProviderCredentialResponse | LlmProviderCredentialRejected> {
  const response = await rpcClient.request(rpcMethods.llmProviderResolveCredential, request, request.request_id)
  if ('code' in response) {
    return {
      request_id: request.request_id,
      agent_uid: stringFromDetails(response, 'agent_uid') || request.agent_uid,
      session_id: stringFromDetails(response, 'session_id') || request.session_id,
      profile: stringFromDetails(response, 'profile') || request.profile,
      code: response.code,
      message: response.message
    }
  }

  return response.payload_json as LlmProviderCredentialResponse
}

async function requestAgentProfile(rpcClient: RuntimeRpcClient, request: AgentProfileRequest): Promise<AgentProfile> {
  const response = await rpcClient.request(rpcMethods.agentProfileResolve, request, request.request_id)
  if ('code' in response) {
    throw new Error(`agent profile RPC failed: ${response.code} ${response.message ?? ''}`.trim())
  }
  return response.payload_json as AgentProfile
}

async function requestTurnContext(
  rpcClient: RuntimeRpcClient,
  request: TurnContextRequest
): Promise<TurnRuntimeContext> {
  const response = await rpcClient.request(rpcMethods.runtimeTurnContextResolve, request, request.request_id)
  if ('code' in response) {
    throw new Error(`turn context RPC failed: ${response.code} ${response.message ?? ''}`.trim())
  }
  return response.payload_json as TurnRuntimeContext
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

class RuntimeRpcClient {
  private waiters = new Map<string, RpcWaiter>()

  constructor(private readonly sendEnvelope: ReliableEnvelopeSender) {}

  async request<M extends RpcMethod>(
    method: M,
    payload: RpcPayloadByMethod[M],
    requestId: string
  ): Promise<RpcResponse | RpcError> {
    const request: RpcRequest = {
      request_id: requestId,
      method,
      payload_json: payload as JsonObject
    }

    const promise = new Promise<RpcResponse | RpcError>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.waiters.delete(requestId)
        reject(new Error(`RPC request timed out: ${method}`))
      }, rpcTimeoutMs)
      this.waiters.set(requestId, { resolve, reject, timeout })
    })

    try {
      await this.sendEnvelope({
        protocol_version: 1,
        message_id: `rpc-request-${crypto.randomUUID()}`,
        correlation_id: requestId,
        lane: 'LANE_RPC',
        durability: 'CONTROL_EPHEMERAL',
        body: rpcRequestEnvelopeBody(request)
      })
    } catch (error) {
      const waiter = this.waiters.get(requestId)
      if (waiter) {
        clearTimeout(waiter.timeout)
        this.waiters.delete(requestId)
      }
      throw error
    }

    return promise
  }

  resolve(response: RpcResponse | RpcError): void {
    const waiter = this.waiters.get(response.request_id)
    if (!waiter) return

    clearTimeout(waiter.timeout)
    this.waiters.delete(response.request_id)
    waiter.resolve(response)
  }
}

function stringFromDetails(error: RpcError, key: string): string | undefined {
  const value = error.details_json?.[key]
  return typeof value === 'string' ? value : undefined
}

function turnKey(turn: ActorTurnRef): string {
  return `${turn.activation_uid}:${turn.llm_turn_id}`
}
