import type { ActorLaneEnvelope } from './actor_lane'
import { existsSync } from 'node:fs'

export type WorkerConfig = {
  endpoint: string
  preAuthToken: string
  workerId: string
  workerInstanceId: string
  workspaceRoot: string
  workspaceSessionsRoot: string
  sharedFsRoot: string
  userFilesRoot: string
  agentInstalledSkillsRoot: string
  builtinSkillsRoot: string
}

const defaultWorkspaceRoot = '/workspace'
const defaultWorkspaceSessionsRoot = '/workspace/.sessions'
const defaultSharedFsRoot = '/workspace/shared'
const defaultUserFilesRoot = '/workspace/shared/user-files'
const defaultAgentInstalledSkillsRoot = '/workspace/shared/skills/agents'
const defaultBuiltinSkillsRoot = '/repo/app/library/skills'
const actorSpecificEnv = ['ANKOLE_AGENT_UID', 'ANKOLE_SESSION_ID', 'ANKOLE_ACTOR_EPOCH', 'ANKOLE_LLM_TURN_ID']
const containerMarkerPath = '/etc/ankole-agent-computer-container'
const containerMarkerEnv = 'ANKOLE_AGENT_COMPUTER_CONTAINER'

/**
 * Parses the worker process environment into the stable computer-worker config.
 *
 * A worker is not launched for one actor session. Actor identity must come from
 * each `turn_start` envelope so the same image can serve any actor in the pool.
 */
export function parseWorkerEnv(env: Record<string, string | undefined> = Bun.env): WorkerConfig {
  assertContainerRuntime(env)

  if (env.DATABASE_URL) {
    throw new Error('DATABASE_URL must not be set on an agent computer worker')
  }

  for (const key of actorSpecificEnv) {
    if (env[key]) {
      throw new Error(`${key} must not be set on an agent computer worker`)
    }
  }

  return {
    endpoint: requiredEnv(env, 'ANKOLE_RUNTIME_FABRIC_ENDPOINT'),
    preAuthToken: requiredEnv(env, 'ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN'),
    workerId: requiredEnv(env, 'ANKOLE_AGENT_COMPUTER_WORKER_ID'),
    workerInstanceId: requiredEnv(env, 'ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID'),
    workspaceRoot: optionalEnv(env, 'ANKOLE_WORKSPACE_ROOT') ?? defaultWorkspaceRoot,
    workspaceSessionsRoot: optionalEnv(env, 'ANKOLE_WORKSPACE_SESSIONS_ROOT') ?? defaultWorkspaceSessionsRoot,
    sharedFsRoot: optionalEnv(env, 'ANKOLE_SHARED_FS_ROOT') ?? defaultSharedFsRoot,
    userFilesRoot: optionalEnv(env, 'ANKOLE_USER_FILES_ROOT') ?? defaultUserFilesRoot,
    agentInstalledSkillsRoot: optionalEnv(env, 'ANKOLE_AGENT_INSTALLED_SKILLS_ROOT') ?? defaultAgentInstalledSkillsRoot,
    builtinSkillsRoot: optionalEnv(env, 'ANKOLE_BUILTIN_SKILLS_ROOT') ?? defaultBuiltinSkillsRoot
  }
}

/**
 * Enforces the Agent Computer deployment invariant at process startup.
 *
 * Mounting TS source into the image is allowed, but the worker itself must run
 * in the Linux Docker image that provides bubblewrap, browser/Python tools, the
 * native kernel, and the `/workspace` filesystem contract. This turns
 * host-Bun/non-Linux execution from an accidental partial mode into a startup
 * error.
 */
function assertContainerRuntime(env: Record<string, string | undefined>): void {
  if (process.platform !== 'linux') {
    throw new Error('Agent Computer worker must run inside the Linux Docker image')
  }

  if (env[containerMarkerEnv] !== '1' || !existsSync(containerMarkerPath)) {
    throw new Error('Agent Computer worker must run inside the Ankole Agent Computer Docker image')
  }
}

/**
 * Builds the first lifecycle envelope sent after the DEALER connects.
 *
 * Runtime and version are observability metadata. They are not used as
 * feature negotiation because the worker pool is homogeneous by image.
 */
export function workerReadyEnvelope(config: WorkerConfig, availableTurnSlots = 1): ActorLaneEnvelope {
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
          available_turn_slots: availableTurnSlots
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
  monotonicMs = Math.floor(performance.now()),
  activeTurns = 0
): ActorLaneEnvelope {
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
          active_turns: activeTurns
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
export function workerCapacityEnvelope(
  config: WorkerConfig,
  availableTurnSlots = 1,
  activeTurns = 0
): ActorLaneEnvelope {
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
        available_turn_slots: availableTurnSlots,
        capacity_json: {
          available_turn_slots: availableTurnSlots
        },
        load_json: {
          active_turns: activeTurns
        }
      }
    }
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
