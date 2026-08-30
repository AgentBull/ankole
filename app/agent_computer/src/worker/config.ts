import { existsSync } from 'node:fs'
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

/** Default admission limit for one Worker when the operator sets no override. */
const defaultMaxConcurrentTurns = 9
/** Actor-scoped variables that a pooled Worker process must not inherit. */
const actorSpecificEnv = ['ANKOLE_AGENT_UID', 'ANKOLE_SESSION_ID', 'ANKOLE_ACTOR_EPOCH']
/** Marker that identifies the packaged Agent Computer runtime. */
const defaultContainerMarkerPath = '/etc/ankole-agent-computer-container'

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
 * Rejects execution outside the Worker image.
 *
 * The image supplies the native kernel, sandbox tools, browser runtime,
 * Chromium, and the Agent Home filesystem contract. A source mount does not
 * relax this boundary.
 */
function assertContainerRuntime(containerMarkerPath: string): void {
  if (process.platform !== 'linux') {
    throw new Error('Agent Computer worker must run inside the Linux Docker image')
  }

  if (!existsSync(containerMarkerPath)) {
    throw new Error('Agent Computer worker must run inside the Ankole Agent Computer Docker image')
  }
}

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

function optionalPositiveIntegerEnv(env: Record<string, string | undefined>, key: string, fallback: number): number {
  const raw = env[key]?.trim()
  if (!raw) return fallback

  const value = Number(raw)
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(`${key} must be a positive integer`)
  }

  return value
}
