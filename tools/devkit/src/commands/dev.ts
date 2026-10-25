import { spawn, type ChildProcess, type SpawnOptions } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { defineCommand } from '@crustjs/core'

import { createLocalAppDatabase, runAppMigrations } from './app-db'
import { resolveLocalWorkerImage } from '../local-worker-image'
import {
  appRootPath,
  loadAppDevelopmentEnv,
  mixCommand,
  repoRootPath,
  resolveAppDatabaseName,
  runChildCaptured,
  startComposeServices
} from '../utils'

const defaultPhoenixPort = 4000
const defaultDockerSocket = '/var/run/docker.sock'
/** Installation label of the Worker containers that the development control plane creates. */
export const devInstallation = 'dev'

export type ControlPlaneEnvOptions = {
  port: number
  workerImage: string
  repoRoot: string
}

/**
 * Environment of the development control plane. It creates the Worker of each
 * Agent through its selected provider when the Agent is created, and the Worker
 * runs the mounted source with `bun --watch`.
 */
export function buildControlPlaneEnv(env: NodeJS.ProcessEnv, opts: ControlPlaneEnvOptions): NodeJS.ProcessEnv {
  const aiGatewayBaseURL =
    env.ANKOLE_AI_GATEWAY_BASE_URL?.trim() || `http://host.docker.internal:${opts.port}/api/v1/ai-gateway`

  return {
    ...env,
    PORT: String(opts.port),
    ANKOLE_FUNCTION_RUNTIME_URL: env.ANKOLE_FUNCTION_RUNTIME_URL || 'http://127.0.0.1:5435',
    ANKOLE_FUNCTION_RUNTIME_TOKEN: env.ANKOLE_FUNCTION_RUNTIME_TOKEN || 'dev-function-runtime-token',
    ANKOLE_RUNTIME_FABRIC_INTERNAL_ORIGIN: `http://host.docker.internal:${opts.port}`,
    ANKOLE_AI_GATEWAY_BASE_URL: aiGatewayBaseURL,
    ANKOLE_WORKER_PROVIDERS_FILE: path.join(opts.repoRoot, 'var', 'ankole-dev', 'worker-providers.yaml'),
    ANKOLE_AGENT_COMPUTER_IMAGE: opts.workerImage,
    ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT: `ws://host.docker.internal:${opts.port}/runtime-fabric/worker`,
    ANKOLE_WORKER_INSTALLATION: devInstallation
  }
}

/** Imported once into an empty provider table. Console owns later changes. */
export function buildDevWorkerSeed(socket: string): string {
  return `providers:
  - provider_id: local
    kind: docker
    display_name: Local development
    is_default: true
    config: |
      socket: ${JSON.stringify(socket)}
      network: bridge
      idleReleaseAfter: never
`
}

/** The Unix socket path of a Docker context host, or undefined for another transport. */
export function parseDockerContextHost(output: string): string | undefined {
  const host = output.trim()
  return host.startsWith('unix://') ? host.slice('unix://'.length) : undefined
}

/** Lists every Worker container of the development installation, stopped ones included. */
export function buildDevWorkerPsArgs(): string[] {
  return ['ps', '-aq', '--filter', 'label=ankole.worker=1', '--filter', `label=ankole.installation=${devInstallation}`]
}

export function parseDockerContainerIDs(output: string): string[] {
  return output
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
}

// Docker Desktop and Colima do not always provide /var/run/docker.sock; the
// current context names the socket that the `docker` CLI uses.
async function dockerSocket(): Promise<string> {
  const result = await runChildCaptured('docker', ['context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'])
  return (result.status === 0 && parseDockerContextHost(result.stdout)) || defaultDockerSocket
}

// Removes the Worker containers after the control plane stops. The next
// `kit dev` creates each Worker again when its Agent needs it.
async function removeDevWorkers(): Promise<void> {
  const result = await runChildCaptured('docker', buildDevWorkerPsArgs())
  if (result.status !== 0) {
    throw new Error(`failed to list the development Worker containers: ${result.stderr || result.stdout}`)
  }

  const containerIDs = parseDockerContainerIDs(result.stdout)
  if (containerIDs.length === 0) return

  const stop = await runChildCaptured('docker', ['stop', '--time', '60', ...containerIDs])
  if (stop.status !== 0) {
    throw new Error(`failed to stop the development Worker containers: ${stop.stderr || stop.stdout}`)
  }
  const removal = await runChildCaptured('docker', ['rm', ...containerIDs])
  if (removal.status !== 0) {
    throw new Error(`failed to remove the development Worker containers: ${removal.stderr || removal.stdout}`)
  }
}

function spawnAttached(name: string, command: string, args: string[], options: SpawnOptions): ChildProcess {
  const child = spawn(command, args, { stdio: 'inherit', ...options })
  child.on('error', error => {
    console.error(`[dev] ${name} failed to start: ${error.message}`)
  })
  return child
}

function startControlPlane(env: NodeJS.ProcessEnv): ChildProcess {
  const mix = mixCommand(['phx.server'])
  return spawnAttached('control-plane', mix.command, mix.args, {
    cwd: appRootPath,
    env,
    detached: process.platform !== 'win32'
  })
}

function waitForExit(child: ChildProcess): Promise<{ code: number | null; signal: NodeJS.Signals | null }> {
  return new Promise(resolve => {
    child.once('exit', (code, signal) => resolve({ code, signal }))
  })
}

async function stopChild(child: ChildProcess | undefined): Promise<void> {
  if (!child || child.exitCode !== null || child.signalCode !== null) return

  signalChild(child, 'SIGTERM')
  await new Promise<void>(resolve => {
    const timer = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) signalChild(child, 'SIGKILL')
      resolve()
    }, 5_000)
    child.once('exit', () => {
      clearTimeout(timer)
      resolve()
    })
  })
}

export function signalChild(
  child: ChildProcess,
  signal: NodeJS.Signals,
  killProcess: typeof process.kill = process.kill,
  platform: NodeJS.Platform = process.platform
): void {
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return

  try {
    if (platform === 'win32') child.kill(signal)
    else killProcess(-child.pid, signal)
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    if (code === 'EPERM' && platform !== 'win32') {
      child.kill(signal)
      return
    }
    if (code !== 'ESRCH') throw error
  }
}

async function runDev(flags: {
  services: boolean
  migrate: boolean
  build: boolean
  port: number
  'worker-image'?: string
}): Promise<void> {
  const port = flags.port
  const workerImage =
    flags['worker-image'] ?? (await resolveLocalWorkerImage({ scope: 'source-mounted', allowBuild: flags.build }))
  const databaseName = resolveAppDatabaseName()

  if (flags.services) {
    await startComposeServices({ pull: false, wait: true, waitTimeout: 60 })
  }

  await createLocalAppDatabase(databaseName)
  if (flags.migrate) await runAppMigrations()

  const controlPlaneEnv = buildControlPlaneEnv(loadAppDevelopmentEnv(), {
    port,
    workerImage,
    repoRoot: repoRootPath
  })
  const seedPath = controlPlaneEnv.ANKOLE_WORKER_PROVIDERS_FILE!
  mkdirSync(path.dirname(seedPath), { recursive: true })
  writeFileSync(seedPath, buildDevWorkerSeed(await dockerSocket()))
  let stopRequested = false
  let controlPlane: ChildProcess | undefined

  const requestStop = () => {
    if (stopRequested) return
    stopRequested = true
    if (controlPlane) signalChild(controlPlane, 'SIGTERM')
  }

  process.once('SIGINT', requestStop)
  process.once('SIGTERM', requestStop)

  try {
    controlPlane = startControlPlane(controlPlaneEnv)
    const exit = await waitForExit(controlPlane)
    if (stopRequested) return

    const code = exit.code ?? 1
    if (code !== 0) {
      throw new Error(`control-plane exited with code ${code}${exit.signal ? ` signal ${exit.signal}` : ''}`)
    }
  } finally {
    process.removeListener('SIGINT', requestStop)
    process.removeListener('SIGTERM', requestStop)
    await stopChild(controlPlane)
    await removeDevWorkers()
  }
}

export function devCommand() {
  return defineCommand(
    'dev',
    {
      description:
        "Start local Postgres, Function Runtime, and the Phoenix control plane, which runs each Agent's Worker in Docker from the local source."
    },
    command =>
      command
        .flags(
          {
            name: 'services',
            type: 'boolean',
            description: 'Start Docker Compose support services.',
            default: true
          },
          {
            name: 'migrate',
            type: 'boolean',
            description: 'Run control-plane Ecto migrations.',
            default: true
          },
          {
            name: 'build',
            type: 'boolean',
            description: 'Build a missing or stale worker image.',
            default: true
          },
          {
            name: 'port',
            type: 'number',
            description: 'Phoenix HTTP port.',
            default: defaultPhoenixPort
          },
          {
            name: 'worker-image',
            type: 'string',
            description: 'Use an explicit Agent Computer image instead of resolving the current source image.'
          }
        )
        .action(({ flags }) => runDev(flags))
  )
}
