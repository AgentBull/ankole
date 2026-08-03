import { existsSync } from 'node:fs'
import { create } from '@bufbuild/protobuf'
import {
  AgentComputerWorkerCapacitySchema,
  AgentComputerWorkerHeartbeatSchema,
  AgentComputerWorkerReadySchema,
  createEnvelope,
  DurabilityClass,
  envelopeHeader,
  Lane,
  type Envelope
} from '../fabric/envelope_proto'
import { AGENTS_ROOT, BUILTIN_SKILLS_ROOT } from '../core/agent-home-paths'

export type WorkerConfig = {
  endpoint: string
  workerAuthKey: string
  workerID: string
  incarnationID: string
  agentsRoot: string
  builtinSkillsRoot: string
  internalSkillsRoot?: string
  maxConcurrentTurns: number
}

const defaultMaxConcurrentTurns = 9
const actorSpecificEnv = ['ANKOLE_AGENT_UID', 'ANKOLE_SESSION_ID', 'ANKOLE_ACTOR_EPOCH']
const defaultContainerMarkerPath = '/etc/ankole-agent-computer-container'
const workerRuntime = 'bun'
const workerVersion = '0.1.0'

/**
 * Parses the worker process environment into the stable computer-worker config.
 *
 * A worker is not launched for one actor session. Actor identity must come from
 * each `turn_start` envelope so the same image can serve any actor in the pool.
 */
export function parseWorkerEnv(env: Record<string, string | undefined>): WorkerConfig {
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
    endpoint: parseRuntimeFabricEndpoint(requiredEnv(env, 'ANKOLE_RUNTIME_FABRIC_ENDPOINT')),
    workerAuthKey: requiredRawEnv(env, 'ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY'),
    workerID: requiredEnv(env, 'WORKER_ID'),
    incarnationID: crypto.randomUUID(),
    agentsRoot: optionalEnv(env, 'ANKOLE_AGENTS_ROOT', AGENTS_ROOT),
    builtinSkillsRoot: optionalEnv(env, 'ANKOLE_BUILTIN_SKILLS_ROOT', BUILTIN_SKILLS_ROOT),
    internalSkillsRoot: optionalEnv(env, 'ANKOLE_INTERNAL_SKILLS_ROOT'),
    maxConcurrentTurns: optionalPositiveIntegerEnv(env, 'ANKOLE_MAX_CONCURRENT_TURNS', defaultMaxConcurrentTurns)
  }
}

/**
 * Loads process bootstrap config and removes the auth key from child-process inheritance.
 */
export function loadWorkerConfig(env: Record<string, string | undefined> = process.env): WorkerConfig {
  const config = parseWorkerEnv(env)
  delete env.ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY
  return config
}

/**
 * Enforces the Agent Computer deployment invariant at process startup.
 *
 * Mounting TS source into the image is allowed, but the worker itself must run
 * in the Linux Docker image that provides bubblewrap, Chromium/Python runtime
 * dependencies, the native kernel, and the `/agents` filesystem contract. This turns
 * host-Bun/non-Linux execution from an accidental partial mode into a startup
 * error. Chromium is image-owned only for the internal rendered web_fetch
 * fallback; it is not a model-visible browser surface.
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
 * Validates and normalizes the physical RuntimeFabric endpoint.
 */
export function parseRuntimeFabricEndpoint(value: string): string {
  let url: URL

  try {
    url = new URL(value)
  } catch (_error) {
    throw new Error('ANKOLE_RUNTIME_FABRIC_ENDPOINT must be tcp://host:port')
  }

  if (url.protocol !== 'tcp:') {
    throw new Error('ANKOLE_RUNTIME_FABRIC_ENDPOINT must use tcp://')
  }

  if (url.username || url.password) {
    throw new Error('ANKOLE_RUNTIME_FABRIC_ENDPOINT must not include credentials')
  }

  if (!url.hostname || !url.port || !['', '/'].includes(url.pathname) || url.search || url.hash) {
    throw new Error('ANKOLE_RUNTIME_FABRIC_ENDPOINT must be tcp://host:port')
  }

  return `tcp://${url.host}`
}

/**
 * Builds the first lifecycle envelope sent after the DEALER connects.
 *
 * Runtime and product version are observability metadata. Protocol compatibility
 * is enforced by the envelope header before this worker can enter the ready pool.
 */
export function workerReadyEnvelope(config: WorkerConfig, availableTurnSlots = config.maxConcurrentTurns): Envelope {
  const available = clampAvailableSlots(config, availableTurnSlots)

  return createEnvelope({
    ...envelopeHeader(`worker-ready-${crypto.randomUUID()}`, Lane.CONTROL, DurabilityClass.CONTROL_EPHEMERAL),
    body: {
      case: 'workerReady',
      value: create(AgentComputerWorkerReadySchema, {
        workerId: config.workerID,
        incarnationId: config.incarnationID,
        runtime: workerRuntime,
        version: workerVersion,
        maxTurns: config.maxConcurrentTurns,
        availableTurnSlots: available
      })
    }
  })
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
): Envelope {
  const available = clampAvailableSlots(config, config.maxConcurrentTurns - activeTurns)

  return createEnvelope({
    ...envelopeHeader(`worker-heartbeat-${crypto.randomUUID()}`, Lane.CONTROL, DurabilityClass.CONTROL_EPHEMERAL),
    body: {
      case: 'workerHeartbeat',
      value: create(AgentComputerWorkerHeartbeatSchema, {
        workerId: config.workerID,
        incarnationId: config.incarnationID,
        monotonicMs: BigInt(monotonicMs),
        activeTurns,
        runtime: workerRuntime,
        version: workerVersion,
        maxTurns: config.maxConcurrentTurns,
        availableTurnSlots: available
      })
    }
  })
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
): Envelope {
  const available = clampAvailableSlots(config, availableTurnSlots)

  return createEnvelope({
    ...envelopeHeader(`worker-capacity-${crypto.randomUUID()}`, Lane.CONTROL, DurabilityClass.CONTROL_EPHEMERAL),
    body: {
      case: 'workerCapacity',
      value: create(AgentComputerWorkerCapacitySchema, {
        workerId: config.workerID,
        incarnationId: config.incarnationID,
        maxTurns: config.maxConcurrentTurns,
        activeTurns,
        availableTurnSlots: available
      })
    }
  })
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
 * Reads a required value without changing secret bytes.
 */
function requiredRawEnv(env: Record<string, string | undefined>, key: string): string {
  const value = env[key]
  if (value === undefined || value.length === 0) {
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
