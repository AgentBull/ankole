import type { ActorBusEnvelope } from './actor_bus'
import { turnStartFromEnvelope } from './actor_bus'
import { handlePingPongTurnStart } from './ping_pong_handler'

export type WorkerConfig = {
  endpoint: string
  preAuthToken: string
  workerId: string
  workerInstanceId: string
  workspaceRoot: string
}

const defaultWorkspaceRoot = '/workspace'

const actorSpecificEnv = ['ANKOLE_AGENT_UID', 'ANKOLE_SESSION_ID', 'ANKOLE_ACTOR_EPOCH', 'ANKOLE_LLM_TURN_ID']

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

export function handleActorBusEnvelope(envelope: ActorBusEnvelope): ActorBusEnvelope[] {
  switch (envelope.body.type) {
    case 'turn_start': {
      const result = handlePingPongTurnStart(turnStartFromEnvelope(envelope), {
        correlationId: envelope.message_id
      })
      return [result.accepted, result.finalProposal]
    }

    default:
      return []
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
