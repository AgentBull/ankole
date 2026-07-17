import { spawn, spawnSync, type ChildProcess, type SpawnOptions } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync } from 'node:fs'
import net from 'node:net'
import path from 'node:path'
import { Crust } from '@crustjs/core'

import { createLocalAppDatabase, runAppMigrations } from './app-db'
import { buildDockerRunArgs, renderWorkerBootstrapSpec, type WorkerBootstrapSpec } from '../worker-bootstrap'
import {
  appRootPath,
  loadAppDevelopmentEnv,
  mixCommand,
  repoRootPath,
  resolveAppDatabaseName,
  runChild,
  runChildCaptured,
  startComposeServices
} from '../utils'

const defaultFabricPort = 6010
const defaultPhoenixPort = 4000
const defaultWorkerID = 'local-dev-worker'
const defaultWorkerImage = 'ankole-agent-computer:0.1.0'
const defaultWorkspaceRoot = 'var/ankole-dev/worker'
const defaultContainerName = 'ankole-dev-agent-computer'
const managedLabel = 'ankole.dev.managed'
const sourceHashLabel = 'ankole.dev.source_hash'
const workerSourceMountTarget = '/repo/app/agent_computer/src'
const workerInternalSkillsMountTarget = '/repo/internals/skills'
const workerDevCommand = 'cd /repo/app/agent_computer && exec bun --watch src/main.ts'

export type WorkerDockerArgsOptions = {
  repoRoot: string
  containerName?: string
}

export function buildControlPlaneEnv(
  env: NodeJS.ProcessEnv,
  opts: { port: number; fabricPort: number }
): NodeJS.ProcessEnv {
  const workerFacingBaseURL =
    env.ANKOLE_AI_GATEWAY_WORKER_FACING_BASE_URL?.trim() || `http://host.docker.internal:${opts.port}/api/v1/ai-gateway`

  return {
    ...env,
    PORT: String(opts.port),
    ANKOLE_RUNTIME_FABRIC_BIND_ENDPOINT: `tcp://127.0.0.1:${opts.fabricPort}`,
    ANKOLE_AI_GATEWAY_WORKER_FACING_BASE_URL: workerFacingBaseURL
  }
}

export function buildManagedWorkerPsArgs(containerName = defaultContainerName): string[] {
  return ['ps', '-aq', '--filter', `label=${managedLabel}=true`, '--filter', `name=^/${containerName}$`]
}

export function buildManagedWorkerRmArgs(containerIDs: string[]): string[] {
  return ['rm', '-f', ...containerIDs]
}

export function parseDockerContainerIDs(output: string): string[] {
  return output
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
}

export function buildWorkerDockerArgs(spec: WorkerBootstrapSpec, opts: WorkerDockerArgsOptions): string[] {
  const containerName = opts.containerName ?? defaultContainerName
  const repoRoot = path.resolve(opts.repoRoot)
  const workerID = spec.env.WORKER_ID
  if (!workerID) throw new Error('worker bootstrap contract is missing WORKER_ID')

  const internalSkillsRoot = path.join(repoRoot, 'internals', 'skills')
  const internalSkillsAvailable = existsSync(internalSkillsRoot)
  const workerSpec = internalSkillsAvailable
    ? {
        ...spec,
        env: {
          ...spec.env,
          ANKOLE_INTERNAL_SKILLS_ROOT: workerInternalSkillsMountTarget
        }
      }
    : spec

  return buildDockerRunArgs(workerSpec, {
    name: containerName,
    labels: {
      [managedLabel]: 'true',
      'ankole.dev.worker_id': workerID
    },
    additionalMounts: [
      {
        source: path.join(repoRoot, 'app', 'agent_computer', 'src'),
        target: workerSourceMountTarget,
        readonly: true
      },
      ...(internalSkillsAvailable
        ? [
            {
              source: internalSkillsRoot,
              target: workerInternalSkillsMountTarget,
              readonly: true
            }
          ]
        : [])
    ],
    command: ['/bin/sh', '-lc', workerDevCommand]
  })
}

export async function workerImageSourceHash(): Promise<string> {
  const files = await workerImageInputFiles()
  const hash = createHash('sha256')

  for (const file of files.toSorted()) {
    hash.update(file)
    hash.update('\0')
    hash.update(readFileSync(path.join(repoRootPath, file)))
    hash.update('\0')
  }

  return hash.digest('hex')
}

async function workerImageInputFiles(): Promise<string[]> {
  const inputs = [
    'app/agent_computer/Dockerfile',
    'app/agent_computer/package.json',
    'app/agent_computer/tsconfig.json',
    'app/kernel',
    'app/library',
    'package.json',
    'bun.lock',
    'tsconfig.base.json'
  ]

  const result = await runChildCaptured('git', ['ls-files', '-co', '--exclude-standard', '-z', '--', ...inputs], {
    cwd: repoRootPath
  })

  if (result.status !== 0) {
    throw new Error(`git ls-files failed while hashing worker image inputs: ${result.stderr || result.stdout}`)
  }

  return result.stdout
    .split('\0')
    .filter(Boolean)
    .filter(file => !file.startsWith('app/agent_computer/src/'))
    .filter(file => existsSync(path.join(repoRootPath, file)))
}

async function ensureWorkerImage(image: string, allowBuild: boolean): Promise<void> {
  await requireDocker()
  const sourceHash = await workerImageSourceHash()
  const currentHash = await dockerImageSourceHash(image)

  if (currentHash === sourceHash) return

  if (!allowBuild) {
    throw new Error(`Worker image ${image} is missing or stale and --no-build was given.`)
  }

  await runChild('docker', [
    'build',
    '--label',
    `${sourceHashLabel}=${sourceHash}`,
    '-f',
    path.join(repoRootPath, 'app', 'agent_computer', 'Dockerfile'),
    '-t',
    image,
    repoRootPath
  ])
}

async function requireDocker(): Promise<void> {
  const result = await runChildCaptured('docker', ['info'])
  if (result.status !== 0) {
    throw new Error('Docker daemon is not reachable; local Agent Computer worker development needs Docker.')
  }
}

async function dockerImageSourceHash(image: string): Promise<string | null> {
  const result = await runChildCaptured('docker', [
    'image',
    'inspect',
    '--format',
    `{{ index .Config.Labels "${sourceHashLabel}" }}`,
    image
  ])

  if (result.status !== 0) return null

  const value = result.stdout.trim()
  return value && value !== '<no value>' ? value : null
}

async function cleanupManagedWorker(containerName: string): Promise<void> {
  const result = await runChildCaptured('docker', buildManagedWorkerPsArgs(containerName))
  if (result.status !== 0) {
    throw new Error(`failed to inspect managed dev worker containers: ${result.stderr || result.stdout}`)
  }

  const containerIDs = parseDockerContainerIDs(result.stdout)
  if (containerIDs.length === 0) return

  const removal = await runChildCaptured('docker', buildManagedWorkerRmArgs(containerIDs))
  if (removal.status !== 0) {
    throw new Error(`failed to remove managed dev worker containers: ${removal.stderr || removal.stdout}`)
  }
}

function cleanupManagedWorkerSync(containerName: string): void {
  const result = spawnSync('docker', buildManagedWorkerPsArgs(containerName), { encoding: 'utf8' })
  if (result.status !== 0) {
    throw new Error(`failed to inspect managed dev worker containers: ${result.stderr || result.stdout}`)
  }

  const containerIDs = parseDockerContainerIDs(result.stdout)
  if (containerIDs.length === 0) return

  const removal = spawnSync('docker', buildManagedWorkerRmArgs(containerIDs), { encoding: 'utf8' })
  if (removal.status !== 0) {
    throw new Error(`failed to remove managed dev worker containers: ${removal.stderr || removal.stdout}`)
  }
}

function ensureWorkspaceDirs(spec: WorkerBootstrapSpec): void {
  for (const dir of spec.host_setup_dirs) {
    mkdirSync(dir, { recursive: true })
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

function startWorker(spec: WorkerBootstrapSpec): ChildProcess {
  return spawnAttached('worker', 'docker', buildWorkerDockerArgs(spec, { repoRoot: repoRootPath }), {
    cwd: repoRootPath,
    detached: process.platform !== 'win32'
  })
}

async function waitForTCPPort(host: string, port: number, timeoutMs: number, aborted: () => boolean): Promise<void> {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    if (aborted()) throw new Error(`control plane exited before RuntimeFabric bound ${host}:${port}`)
    if (await canConnect(host, port)) return
    await new Promise(resolve => setTimeout(resolve, 250))
  }

  throw new Error(`timed out waiting for RuntimeFabric on ${host}:${port}`)
}

function canConnect(host: string, port: number): Promise<boolean> {
  return new Promise(resolve => {
    const socket = net.createConnection({ host, port })
    socket.setTimeout(500)
    socket.once('connect', () => {
      socket.end()
      resolve(true)
    })
    socket.once('timeout', () => {
      socket.destroy()
      resolve(false)
    })
    socket.once('error', () => resolve(false))
  })
}

type ChildExit = {
  name: string
  code: number | null
  signal: NodeJS.Signals | null
}

function waitForFirstExit(children: Array<{ name: string; child: ChildProcess }>): Promise<ChildExit> {
  return new Promise(resolve => {
    for (const entry of children) {
      entry.child.once('exit', (code, signal) => resolve({ name: entry.name, code, signal }))
    }
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

function signalChild(child: ChildProcess, signal: NodeJS.Signals): void {
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return

  try {
    if (process.platform === 'win32') child.kill(signal)
    else process.kill(-child.pid, signal)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error
  }
}

async function runDev(flags: {
  services: boolean
  migrate: boolean
  build: boolean
  port: number
  'fabric-port': number
  'worker-id': string
  'worker-image': string
  'workspace-root': string
}): Promise<void> {
  const port = flags.port
  const fabricPort = flags['fabric-port']
  const workerImage = flags['worker-image']
  const workerID = flags['worker-id']
  const workspaceRoot = path.resolve(repoRootPath, flags['workspace-root'])
  const databaseName = resolveAppDatabaseName()

  if (flags.services) {
    await startComposeServices({ pull: false, wait: true, waitTimeout: 60 })
  }

  await createLocalAppDatabase(databaseName)
  if (flags.migrate) await runAppMigrations()
  await ensureWorkerImage(workerImage, flags.build)

  const workerSpec = await renderWorkerBootstrapSpec({
    endpoint: `tcp://host.docker.internal:${fabricPort}`,
    workerID,
    image: workerImage,
    workspaceRoot
  })
  ensureWorkspaceDirs(workerSpec)
  await cleanupManagedWorker(defaultContainerName)

  const controlPlaneEnv = buildControlPlaneEnv(loadAppDevelopmentEnv(), { port, fabricPort })
  let stopRequested = false
  let controlPlane: ChildProcess | undefined
  let worker: ChildProcess | undefined

  const requestStop = () => {
    if (stopRequested) return
    stopRequested = true
    try {
      cleanupManagedWorkerSync(defaultContainerName)
    } catch (error) {
      console.error(`[dev] ${error instanceof Error ? error.message : String(error)}`)
    }
    if (controlPlane) signalChild(controlPlane, 'SIGTERM')
    if (worker) signalChild(worker, 'SIGTERM')
  }

  process.once('SIGINT', requestStop)
  process.once('SIGTERM', requestStop)

  try {
    controlPlane = startControlPlane(controlPlaneEnv)
    await waitForTCPPort('127.0.0.1', fabricPort, 30_000, () => controlPlane?.exitCode !== null)
    worker = startWorker(workerSpec)

    const exit = await waitForFirstExit([
      { name: 'control-plane', child: controlPlane },
      { name: 'worker', child: worker }
    ])

    if (stopRequested) return

    const code = exit.code ?? 1
    if (code !== 0) {
      throw new Error(`${exit.name} exited with code ${code}${exit.signal ? ` signal ${exit.signal}` : ''}`)
    }
  } finally {
    process.removeListener('SIGINT', requestStop)
    process.removeListener('SIGTERM', requestStop)
    await stopChild(worker)
    await stopChild(controlPlane)
    await cleanupManagedWorker(defaultContainerName)
  }
}

export function devCommand(): Crust {
  return new Crust('dev')
    .meta({ description: 'Start local Postgres, Phoenix control plane, and one Docker Agent Computer worker.' })
    .flags({
      services: {
        type: 'boolean',
        description: 'Start Docker Compose support services.',
        default: true
      },
      migrate: {
        type: 'boolean',
        description: 'Run control-plane Ecto migrations.',
        default: true
      },
      build: {
        type: 'boolean',
        description: 'Build a missing or stale worker image.',
        default: true
      },
      port: {
        type: 'number',
        description: 'Phoenix HTTP port.',
        default: defaultPhoenixPort
      },
      'fabric-port': {
        type: 'number',
        description: 'RuntimeFabric TCP bind port on 127.0.0.1.',
        default: defaultFabricPort
      },
      'worker-id': {
        type: 'string',
        description: 'Agent Computer worker id.',
        default: defaultWorkerID
      },
      'worker-image': {
        type: 'string',
        description: 'Agent Computer Docker image.',
        default: defaultWorkerImage
      },
      'workspace-root': {
        type: 'string',
        description: 'Host workspace root mounted into the worker.',
        default: defaultWorkspaceRoot
      }
    })
    .run(({ flags }) => runDev(flags))
}
