import { existsSync } from 'node:fs'
import type { RuntimeFabricEnvelope } from '../fabric/fabric'
import {
  SANDBOX_AGENT_INSTALLED_SKILLS_ROOT,
  SANDBOX_BUILTIN_SKILLS_ROOT,
  SANDBOX_SHARED_FS_ROOT,
  SANDBOX_USER_FILES_ROOT,
  SANDBOX_WORKSPACE_ROOT,
  SANDBOX_WORKSPACE_SESSIONS_ROOT
} from './sandbox_paths'

export type WorkerConfig = {
  endpoint: string
  workerAuthKey: string
  workerId: string
  workspaceRoot: string
  workspaceSessionsRoot: string
  sharedFsRoot: string
  userFilesRoot: string
  agentInstalledSkillsRoot: string
  builtinSkillsRoot: string
  internalSkillsRoot?: string
  maxConcurrentTurns: number
}

const defaultMaxConcurrentTurns = 9
const actorSpecificEnv = ['ANKOLE_AGENT_UID', 'ANKOLE_SESSION_ID', 'ANKOLE_ACTOR_EPOCH']
const defaultContainerMarkerPath = '/etc/ankole-agent-computer-container'

/**
 * Parses the worker process environment into the stable computer-worker config.
 *
 * A worker is not launched for one actor session. Actor identity must come from
 * each `turn_start` envelope so the same image can serve any actor in the pool.
 */
export function parseWorkerEnv(env: Record<string, string | undefined> = Bun.env): WorkerConfig {
  assertContainerRuntime(defaultContainerMarkerPath)

  if (env.DATABASE_URL) {
    throw new Error('DATABASE_URL must not be set on an agent computer worker')
  }

  for (const key of actorSpecificEnv) {
    if (env[key]) {
      throw new Error(`${key} must not be set on an agent computer worker`)
    }
  }

  return {
    ...parseRuntimeFabricUrl(requiredEnv(env, 'RUNTIME_FABRIC_URL')),
    workerId: requiredEnv(env, 'WORKER_ID'),
    workspaceRoot: optionalEnv(env, 'ANKOLE_WORKSPACE_ROOT', SANDBOX_WORKSPACE_ROOT),
    workspaceSessionsRoot: optionalEnv(env, 'ANKOLE_WORKSPACE_SESSIONS_ROOT', SANDBOX_WORKSPACE_SESSIONS_ROOT),
    sharedFsRoot: optionalEnv(env, 'ANKOLE_SHARED_FS_ROOT', SANDBOX_SHARED_FS_ROOT),
    userFilesRoot: optionalEnv(env, 'ANKOLE_USER_FILES_ROOT', SANDBOX_USER_FILES_ROOT),
    agentInstalledSkillsRoot: optionalEnv(
      env,
      'ANKOLE_AGENT_INSTALLED_SKILLS_ROOT',
      SANDBOX_AGENT_INSTALLED_SKILLS_ROOT
    ),
    builtinSkillsRoot: optionalEnv(env, 'ANKOLE_BUILTIN_SKILLS_ROOT', SANDBOX_BUILTIN_SKILLS_ROOT),
    internalSkillsRoot: optionalEnv(env, 'ANKOLE_INTERNAL_SKILLS_ROOT'),
    maxConcurrentTurns: optionalPositiveIntegerEnv(env, 'ANKOLE_MAX_CONCURRENT_TURNS', defaultMaxConcurrentTurns)
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
function assertContainerRuntime(containerMarkerPath: string): void {
  if (process.platform !== 'linux') {
    throw new Error('Agent Computer worker must run inside the Linux Docker image')
  }

  if (!existsSync(containerMarkerPath)) {
    throw new Error('Agent Computer worker must run inside the Ankole Agent Computer Docker image')
  }
}

/**
 * Reads an optional string environment variable.
 */
function optionalEnv(env: Record<string, string | undefined>, key: string, fallback: string): string
function optionalEnv(env: Record<string, string | undefined>, key: string, fallback?: undefined): string | undefined
function optionalEnv(env: Record<string, string | undefined>, key: string, fallback?: string): string | undefined {
  const value = env[key]?.trim()
  return value ? value : fallback
}

/**
 * Splits the worker bootstrap URL into the physical endpoint and route secret.
 *
 * The worker id is intentionally not accepted in the URL username: route
 * identity comes from `WORKER_ID`, while the URL password is only the auth key.
 */
export function parseRuntimeFabricUrl(value: string): Pick<WorkerConfig, 'endpoint' | 'workerAuthKey'> {
  let url: URL

  try {
    url = new URL(value)
  } catch (_error) {
    throw new Error('RUNTIME_FABRIC_URL must be tcp://:worker_auth_key@host:port')
  }

  if (url.protocol !== 'tcp:') {
    throw new Error('RUNTIME_FABRIC_URL must use tcp://')
  }

  if (url.username) {
    throw new Error('RUNTIME_FABRIC_URL must not include a username; use WORKER_ID')
  }

  if (!url.password) {
    throw new Error('RUNTIME_FABRIC_URL must include worker auth key as the URL password')
  }

  if (!url.hostname || !url.port || !['', '/'].includes(url.pathname) || url.search || url.hash) {
    throw new Error('RUNTIME_FABRIC_URL must be tcp://:worker_auth_key@host:port')
  }

  return {
    endpoint: `tcp://${url.host}`,
    workerAuthKey: decodeURIComponent(url.password)
  }
}

/**
 * Builds the first lifecycle envelope sent after the DEALER connects.
 *
 * Runtime and version are observability metadata. They are not used as
 * feature negotiation because the worker pool is homogeneous by image.
 */
export function workerReadyEnvelope(
  config: WorkerConfig,
  availableTurnSlots = config.maxConcurrentTurns
): RuntimeFabricEnvelope {
  const available = clampAvailableSlots(config, availableTurnSlots)

  return {
    protocol_version: 1,
    message_id: `worker-ready-${crypto.randomUUID()}`,
    lane: 'LANE_CONTROL',
    durability: 'CONTROL_EPHEMERAL',
    body: {
      type: 'worker_ready',
      worker_ready: {
        worker_id: config.workerId,
        runtime: 'bun',
        version: '0.1.0',
        capacity_json: {
          max_turns: config.maxConcurrentTurns,
          available_turn_slots: available
        }
      }
    }
  }
}

/**
 * Builds the periodic liveness envelope for the admitted worker process.
 *
 * The control plane fences heartbeats by worker id and transport route, so an
 * old process cannot keep a replaced worker projection alive.
 */
export function workerHeartbeatEnvelope(
  config: WorkerConfig,
  monotonicMs = Math.floor(performance.now()),
  activeTurns = 0
): RuntimeFabricEnvelope {
  return {
    protocol_version: 1,
    message_id: `worker-heartbeat-${crypto.randomUUID()}`,
    lane: 'LANE_CONTROL',
    durability: 'CONTROL_EPHEMERAL',
    body: {
      type: 'worker_heartbeat',
      worker_heartbeat: {
        worker_id: config.workerId,
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
  availableTurnSlots = config.maxConcurrentTurns,
  activeTurns = 0
): RuntimeFabricEnvelope {
  const available = clampAvailableSlots(config, availableTurnSlots)

  return {
    protocol_version: 1,
    message_id: `worker-capacity-${crypto.randomUUID()}`,
    lane: 'LANE_CONTROL',
    durability: 'CONTROL_EPHEMERAL',
    body: {
      type: 'worker_capacity',
      worker_capacity: {
        worker_id: config.workerId,
        available_turn_slots: available,
        capacity_json: {
          max_turns: config.maxConcurrentTurns,
          available_turn_slots: available
        },
        load_json: {
          active_turns: activeTurns
        }
      }
    }
  }
}

/**
 * Reads a required string environment variable.
 */
function requiredEnv(env: Record<string, string | undefined>, key: string): string {
  const value = env[key]?.trim()
  if (!value) {
    throw new Error(`${key} is required`)
  }

  return value
}

/**
 * Parses a positive integer environment override.
 */
function optionalPositiveIntegerEnv(env: Record<string, string | undefined>, key: string, fallback: number): number {
  const raw = env[key]?.trim()
  if (!raw) return fallback

  const value = Number(raw)
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(`${key} must be a positive integer`)
  }

  return value
}

/**
 * Clamps capacity before it is projected to the control plane.
 *
 * A bad local counter should degrade to zero capacity instead of advertising a
 * number the scheduler cannot safely interpret.
 */
function clampAvailableSlots(config: WorkerConfig, availableTurnSlots: number): number {
  if (!Number.isInteger(availableTurnSlots)) return 0
  return Math.max(0, Math.min(config.maxConcurrentTurns, availableTurnSlots))
}
