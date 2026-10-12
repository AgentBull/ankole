import { existsSync } from 'node:fs'
import { AGENT_HOME } from '../core/agent-home-paths'

export type WorkerConfig = {
  endpoint: string
  workerAuthKey: string
  workerID: string
  incarnationID: string
  agentHomeRoot: string
  builtinSkillsRoot: string
  internalSkillsRoot?: string
  /** Browser runtime files. The Worker image names each file in its environment. */
  browser: { daemonEntry: string; runnerPath: string; localChromiumExecutable: string }
  maxConcurrentSlots: number
}

/** The part of the config that names the bound Agent's home, without the credential. */
export type AgentHomeConfig = Pick<WorkerConfig, 'agentHomeRoot'>

/** Default admission limit for one Worker when the operator sets no override. */
const defaultMaxConcurrentSlots = 12
/** Marker that identifies the packaged Agent Computer runtime. */
const defaultContainerMarkerPath = '/etc/ankole-agent-computer-container'

/**
 * Parses the worker process environment into the stable computer-worker config.
 *
 * A Worker serves the one Agent that `WORKER_ID` names. A conversation
 * workspace comes from `workspace_open`; a Codex Job comes from `turn_start`.
 */
export function parseWorkerEnv(env: Record<string, string | undefined>): WorkerConfig {
  if (env.DATABASE_URL) {
    throw new Error('DATABASE_URL must not be set on an agent computer worker')
  }

  return {
    endpoint: parseRuntimeFabricEndpoint(requiredEnv(env, 'ANKOLE_RUNTIME_FABRIC_ENDPOINT')),
    workerAuthKey: requiredRawEnv(env, 'ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY'),
    workerID: requiredEnv(env, 'WORKER_ID'),
    incarnationID: crypto.randomUUID(),
    agentHomeRoot: AGENT_HOME,
    builtinSkillsRoot: requiredEnv(env, 'ANKOLE_BUILTIN_SKILLS_ROOT'),
    internalSkillsRoot: optionalEnv(env, 'ANKOLE_INTERNAL_SKILLS_ROOT'),
    browser: {
      daemonEntry: requiredEnv(env, 'ANKOLE_BROWSER_DAEMON_ENTRY'),
      runnerPath: requiredEnv(env, 'ANKOLE_BROWSER_RUNNER'),
      localChromiumExecutable: requiredEnv(env, 'ANKOLE_BROWSER_CHROMIUM_EXECUTABLE')
    },
    maxConcurrentSlots: optionalPositiveIntegerEnv(env, 'ANKOLE_MAX_CONCURRENT_SLOTS', defaultMaxConcurrentSlots)
  }
}

/**
 * Loads process bootstrap config and removes the auth key from child-process inheritance.
 */
export function loadWorkerConfig(env: Record<string, string | undefined> = process.env): WorkerConfig {
  assertContainerRuntime(defaultContainerMarkerPath)
  const config = parseWorkerEnv(env)
  delete env.ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY
  return config
}

/**
 * Rejects execution outside the Worker image.
 *
 * The image supplies the Worker, command tools, browser runtime,
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

  if (process.getuid?.() !== 0) {
    throw new Error('Worker must run as root; model processes run as uid 1000')
  }
}

function optionalEnv(env: Record<string, string | undefined>, key: string, fallback: string): string
function optionalEnv(env: Record<string, string | undefined>, key: string, fallback?: undefined): string | undefined
function optionalEnv(env: Record<string, string | undefined>, key: string, fallback?: string): string | undefined {
  const value = env[key]?.trim()
  return value ? value : fallback
}

/**
 * Validates and normalizes the Worker Channel endpoint.
 *
 * The value is the `ws://` or `wss://` socket path on the control plane, for
 * example `ws://control-plane:4000/runtime-fabric/worker`; the client appends
 * the transport segment. Credentials never travel in the URL.
 */
export function parseRuntimeFabricEndpoint(value: string): string {
  let url: URL

  try {
    url = new URL(value)
  } catch (_error) {
    throw new Error(endpointFormatMessage)
  }

  if (url.username || url.password) {
    throw new Error('ANKOLE_RUNTIME_FABRIC_ENDPOINT must not include credentials')
  }

  if (url.protocol !== 'ws:' && url.protocol !== 'wss:') {
    throw new Error(endpointFormatMessage)
  }

  const path = url.pathname.replace(/\/+$/, '')
  if (!url.hostname || !path || url.search || url.hash) {
    throw new Error(endpointFormatMessage)
  }

  return `${url.protocol}//${url.host}${path}`
}

const endpointFormatMessage = 'ANKOLE_RUNTIME_FABRIC_ENDPOINT must be ws://host:port/path or wss://host:port/path'

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
