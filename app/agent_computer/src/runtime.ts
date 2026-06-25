import type {
  ActorBusEnvelope,
  LlmProviderCredentialRejected,
  LlmProviderCredentialRequest,
  LlmProviderCredentialResponse
} from './actor_bus'
import { turnStartFromEnvelope } from './actor_bus'
import { finalProposalEnvelope, handlePingPongTurnStart, turnAcceptedEnvelope } from './ping_pong_handler'
import { runLlmTurnHandlers, type CredentialRequester } from './llm_runtime/text_turn_loop'

export type WorkerConfig = {
  endpoint: string
  preAuthToken: string
  workerId: string
  workerInstanceId: string
  workspaceRoot: string
}

const defaultWorkspaceRoot = '/workspace'

const actorSpecificEnv = ['ANKOLE_AGENT_UID', 'ANKOLE_SESSION_ID', 'ANKOLE_ACTOR_EPOCH', 'ANKOLE_LLM_TURN_ID']

/**
 * Parses the worker process environment into the stable computer-worker config.
 *
 * A worker is not launched for one actor session. Actor identity must come from
 * each `turn_start` envelope so the same image can serve any actor in the pool.
 */
export function parseWorkerEnv(env: Record<string, string | undefined> = Bun.env): WorkerConfig {
  for (const key of actorSpecificEnv) {
    if (env[key]) {
      throw new Error(`${key} must not be set on an agent computer worker`)
    }
  }

  return {
    endpoint: requiredEnv(env, 'ANKOLE_ACTOR_BUS_ENDPOINT'),
    preAuthToken: requiredEnv(env, 'ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN'),
    workerId: requiredEnv(env, 'ANKOLE_AGENT_COMPUTER_WORKER_ID'),
    workerInstanceId: requiredEnv(env, 'ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID'),
    workspaceRoot: optionalEnv(env, 'ANKOLE_WORKSPACE_ROOT') ?? defaultWorkspaceRoot
  }
}

/**
 * Builds the first lifecycle envelope sent after the DEALER connects.
 *
 * Runtime and version are observability metadata. They are not used as
 * feature negotiation because the worker pool is homogeneous by image.
 */
export function workerReadyEnvelope(config: WorkerConfig): ActorBusEnvelope {
  return {
    protocol_version: 1,
    message_id: `worker-ready-${crypto.randomUUID()}`,
    lane: 'LANE_CONTROL',
    durability: 'CONTROL_EPHEMERAL',
    body: {
      type: 'worker_ready',
      worker_ready: {
        worker_id: config.workerId,
        worker_instance_id: config.workerInstanceId,
        runtime: 'bun',
        version: '0.1.0',
        capacity_json: {
          available_turn_slots: 4
        }
      }
    }
  }
}

/**
 * Builds the periodic liveness envelope for the admitted worker instance.
 *
 * The control plane fences heartbeats by worker instance id and transport route,
 * so an old process cannot keep a restarted worker projection alive.
 */
export function workerHeartbeatEnvelope(
  config: WorkerConfig,
  monotonicMs = Math.floor(performance.now())
): ActorBusEnvelope {
  return {
    protocol_version: 1,
    message_id: `worker-heartbeat-${crypto.randomUUID()}`,
    lane: 'LANE_CONTROL',
    durability: 'CONTROL_EPHEMERAL',
    body: {
      type: 'worker_heartbeat',
      worker_heartbeat: {
        worker_id: config.workerId,
        worker_instance_id: config.workerInstanceId,
        monotonic_ms: monotonicMs,
        load_json: {
          active_turns: 0
        }
      }
    }
  }
}

/**
 * Builds the capacity projection used by the simple worker scheduler.
 *
 * Capacity is intentionally small here: it answers whether the worker can take
 * more turns, not which actor or tool classes it supports.
 */
export function workerCapacityEnvelope(config: WorkerConfig): ActorBusEnvelope {
  return {
    protocol_version: 1,
    message_id: `worker-capacity-${crypto.randomUUID()}`,
    lane: 'LANE_CONTROL',
    durability: 'CONTROL_EPHEMERAL',
    body: {
      type: 'worker_capacity',
      worker_capacity: {
        worker_id: config.workerId,
        worker_instance_id: config.workerInstanceId,
        available_turn_slots: 4,
        capacity_json: {
          available_turn_slots: 4
        },
        load_json: {
          active_turns: 0
        }
      }
    }
  }
}

/**
 * Handles one control-plane envelope and returns zero or more worker replies.
 *
 * Real turns run the LLM/tool loop inside Agent Computer after resolving the
 * model credential over the parent protocol. The ping/pong branch is kept only
 * for protocol smoke tests that intentionally omit a real `model_ref`.
 */
export async function handleActorBusEnvelope(
  envelope: ActorBusEnvelope,
  config?: Pick<WorkerConfig, 'workspaceRoot'>,
  deps: { requestCredential?: CredentialRequester } = {}
): Promise<ActorBusEnvelope[]> {
  switch (envelope.body.type) {
    case 'turn_start': {
      const turnStart = turnStartFromEnvelope(envelope)
      const correlationId = envelope.message_id

      if (!turnStart.model_ref || turnStart.model_ref.provider_id === 'ankole-placeholder') {
        const result = handlePingPongTurnStart(turnStart, {
          correlationId
        })
        return [result.accepted, result.finalProposal]
      }

      if (!deps.requestCredential || !config) {
        throw new Error('real LLM turn requires workspace config and credential requester')
      }

      const accepted = turnAcceptedEnvelope(
        turnStart.turn,
        turnStart.inputs.map(input => input.actor_input_id),
        correlationId
      )
      const proposal = await runLlmTurnHandlers(turnStart, {
        workspaceRoot: config.workspaceRoot,
        requestCredential: deps.requestCredential
      })
      const finalProposal = finalProposalEnvelope(turnStart.turn, proposal, correlationId)

      return [accepted, finalProposal]
    }

    default:
      return []
  }
}

export function credentialRequestEnvelope(request: LlmProviderCredentialRequest): ActorBusEnvelope {
  return {
    protocol_version: 1,
    message_id: request.request_id,
    correlation_id: request.request_id,
    lane: 'LANE_RPC',
    durability: 'CONTROL_EPHEMERAL',
    body: {
      type: 'llm_provider_credential_request',
      llm_provider_credential_request: request
    }
  }
}

export function credentialResponseFromEnvelope(
  envelope: ActorBusEnvelope,
  requestId: string
): LlmProviderCredentialResponse | LlmProviderCredentialRejected | undefined {
  if (envelope.correlation_id !== requestId) {
    return undefined
  }

  switch (envelope.body.type) {
    case 'llm_provider_credential_response':
      return envelope.body.llm_provider_credential_response as LlmProviderCredentialResponse
    case 'llm_provider_credential_rejected':
      return envelope.body.llm_provider_credential_rejected as LlmProviderCredentialRejected
    default:
      return undefined
  }
}

function requiredEnv(env: Record<string, string | undefined>, key: string): string {
  const value = env[key]?.trim()
  if (!value) {
    throw new Error(`${key} is required`)
  }

  return value
}

function optionalEnv(env: Record<string, string | undefined>, key: string): string | undefined {
  const value = env[key]?.trim()
  return value || undefined
}
