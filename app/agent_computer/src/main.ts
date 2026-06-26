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
import { prepareTurnWorkspace, verifyWorkerFilesystem } from './workspace'
import { createFileTransferState, handleFileTransferFrame, isFileTransferFrame } from './file_transfer_lane'

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
  process.stderr.write(
    `${JSON.stringify({
      event: 'worker.error',
      error: error instanceof Error ? error.message : String(error)
    })}\n`
  )
  process.exit(1)
}

async function runWorker(): Promise<void> {
  const config = parseWorkerEnv()
  verifyWorkerFilesystem(config)

  const dealer = new kernel.RuntimeFabricDealer(
    config.endpoint,
    config.workerInstanceId,
    config.workerId,
    config.preAuthToken
  )
  const rpcClient = new RuntimeRpcClient(envelope => dealer.sendEnvelope(envelope))
  const activeTurns = new Map<string, ActiveTurn>()
  const fileTransfers = createFileTransferState()
  let stopping = false

  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      stopping = true
    })
  }

  try {
    dealer.sendEnvelope(workerReadyEnvelope(config, 1))
    dealer.sendEnvelope(workerCapacityEnvelope(config, 1, 0))
    process.stdout.write(
      `${JSON.stringify({
        event: 'worker.ready_sent',
        endpoint: config.endpoint,
        worker_id: config.workerId,
        worker_instance_id: config.workerInstanceId
      })}\n`
    )

    let nextHeartbeatAt = Date.now() + heartbeatIntervalMs

    while (!stopping) {
      if (Date.now() >= nextHeartbeatAt) {
        dealer.sendEnvelope(workerHeartbeatEnvelope(config, Math.floor(performance.now()), activeTurns.size))
        nextHeartbeatAt = Date.now() + heartbeatIntervalMs
      }

      const frames = dealer.recvRaw(500)
      if (!frames) continue

      if (isFileTransferFrame(frames)) {
        await handleFileTransferFrame(config, dealer, fileTransfers, frames)
        continue
      }

      if (!frames[0]) {
        continue
      }
      const envelope = decodeEnvelope(frames[0])
      await handleEnvelope(config, dealer, rpcClient, activeTurns, envelope)
    }
  } finally {
    dealer.stop()
  }
}

async function handleEnvelope(
  config: WorkerConfig,
  dealer: kernel.RuntimeFabricDealer,
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
      return startTurn(config, dealer, rpcClient, activeTurns, envelope)

    case 'mailbox_updated':
      return handleMailboxUpdated(dealer, activeTurns, envelope)

    default:
      return
  }
}

function startTurn(
  config: WorkerConfig,
  dealer: kernel.RuntimeFabricDealer,
  rpcClient: RuntimeRpcClient,
  activeTurns: Map<string, ActiveTurn>,
  envelope: ActorLaneEnvelope
): void {
  const turnStart = turnStartFromEnvelope(envelope)
  const correlationId = envelope.message_id

  if (activeTurns.size > 0) {
    dealer.sendEnvelope(
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

  dealer.sendEnvelope(
    turnAcceptedEnvelope(
      turnStart.turn,
      turnStart.inputs.map(input => input.actor_input_id),
      correlationId
    )
  )
  dealer.sendEnvelope(workerCapacityEnvelope(config, 0, 1))

  void runActiveTurn(config, dealer, rpcClient, active)
    .catch(error => {
      dealer.sendEnvelope(
        turnErrorEnvelope(
          turnStart.turn,
          'worker_turn_failed',
          error instanceof Error ? error.message : String(error),
          correlationId
        )
      )
    })
    .finally(() => {
      activeTurns.delete(turnKey(turnStart.turn))
      dealer.sendEnvelope(workerCapacityEnvelope(config, 1, 0))
    })
}

async function runActiveTurn(
  config: WorkerConfig,
  dealer: kernel.RuntimeFabricDealer,
  rpcClient: RuntimeRpcClient,
  active: ActiveTurn
): Promise<void> {
  const turnStart = active.turnStart
  const runtimeContext = await requestTurnContext(rpcClient, {
    request_id: `turn-context-${crypto.randomUUID()}`,
    turn: turnStart.turn
  })
  const workspaceRoot = prepareTurnWorkspace(config, turnStart, runtimeContext)

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

  dealer.sendEnvelope(finalProposalEnvelope(turnStart.turn, proposal, active.correlationId))
}

function handleMailboxUpdated(
  dealer: kernel.RuntimeFabricDealer,
  activeTurns: Map<string, ActiveTurn>,
  envelope: ActorLaneEnvelope
): void {
  const update = mailboxUpdatedFromEnvelope(envelope)
  if (!update.turn || !Array.isArray(update.inputs) || update.inputs.length === 0) {
    return
  }

  const active = activeTurns.get(turnKey(update.turn))
  if (!active) return

  active.steeringUpdates.push({ turn: update.turn, inputs: update.inputs })
  dealer.sendEnvelope(
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

  constructor(private readonly sendEnvelope: (envelope: ActorLaneEnvelope) => void) {}

  request<M extends RpcMethod>(
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
      this.sendEnvelope({
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
