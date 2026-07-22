import { appRootPath, loadAppDevelopmentEnv, runMixCaptured } from './utils'

export type WorkerBootstrapMount = {
  source: string
  target: string
  readonly: boolean
}

export type WorkerBootstrapSpec = {
  contract_version: 2
  kind: 'container' | 'worker'
  image: string
  docker: {
    cap_add: string[]
    security_opts: string[]
    extra_hosts: Array<{ host: string; address: string }>
  }
  env: Record<string, string>
  host_setup_dirs: string[]
  mounts: WorkerBootstrapMount[]
}

export type DockerRunOptions = {
  name?: string
  labels?: Record<string, string>
  additionalMounts?: WorkerBootstrapMount[]
  command?: string[]
}

export type RenderWorkerBootstrapOptions = {
  endpoint: string
  workerID: string
  image: string
  agentsRoot: string
}

export async function renderContainerBootstrapSpec(image: string): Promise<WorkerBootstrapSpec> {
  return await renderBootstrapSpec(['--scope', 'container', '--image', image], 'container')
}

export async function renderWorkerBootstrapSpec(options: RenderWorkerBootstrapOptions): Promise<WorkerBootstrapSpec> {
  return await renderBootstrapSpec(
    [
      '--scope',
      'worker',
      '--endpoint',
      options.endpoint,
      '--worker-id',
      options.workerID,
      '--image',
      options.image,
      '--agents-root',
      options.agentsRoot
    ],
    'worker'
  )
}

export function parseWorkerBootstrapSpec(output: string): WorkerBootstrapSpec {
  const jsonLine = output
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .findLast(line => line.startsWith('{') && line.endsWith('}'))

  if (!jsonLine) throw new Error('worker bootstrap output did not contain a JSON object')

  const parsed: unknown = JSON.parse(jsonLine)
  if (!isRecord(parsed) || parsed.contract_version !== 2) {
    throw new Error('unsupported worker bootstrap contract version')
  }
  if (!isWorkerBootstrapSpec(parsed)) throw new Error('worker bootstrap contract is invalid')
  return parsed
}

export function buildDockerRunArgs(spec: WorkerBootstrapSpec, options: DockerRunOptions = {}): string[] {
  const mounts = [...spec.mounts, ...(options.additionalMounts ?? [])]

  return [
    'run',
    '--rm',
    ...(options.name ? ['--name', options.name] : []),
    ...Object.entries(options.labels ?? {}).flatMap(([key, value]) => ['--label', `${key}=${value}`]),
    ...spec.docker.cap_add.flatMap(capability => ['--cap-add', capability]),
    ...spec.docker.security_opts.flatMap(option => ['--security-opt', option]),
    ...spec.docker.extra_hosts.flatMap(host => ['--add-host', `${host.host}=${host.address}`]),
    ...Object.entries(spec.env)
      .toSorted(([left], [right]) => left.localeCompare(right))
      .flatMap(([key, value]) => ['-e', `${key}=${value}`]),
    ...mounts.flatMap(mount => ['--mount', bindMountArg(mount)]),
    spec.image,
    ...(options.command ?? [])
  ]
}

async function renderBootstrapSpec(
  args: string[],
  expectedKind: WorkerBootstrapSpec['kind']
): Promise<WorkerBootstrapSpec> {
  const result = await runMixCaptured(['ankole.actor_runtime.worker_bootstrap', '--format', 'json', ...args], {
    cwd: appRootPath,
    env: loadAppDevelopmentEnv()
  })

  if (result.status !== 0) {
    throw new Error(`worker bootstrap render failed: ${result.stderr || result.stdout}`)
  }

  const spec = parseWorkerBootstrapSpec(result.stdout)
  if (spec.kind !== expectedKind) {
    throw new Error(`worker bootstrap command returned ${spec.kind}; expected ${expectedKind}`)
  }
  return spec
}

function bindMountArg(mount: WorkerBootstrapMount): string {
  return `type=bind,src=${mount.source},dst=${mount.target}${mount.readonly ? ',readonly' : ''}`
}

function isWorkerBootstrapSpec(value: Record<string, unknown>): value is WorkerBootstrapSpec {
  return (
    (value.kind === 'container' || value.kind === 'worker') &&
    isNonEmptyString(value.image) &&
    isDockerSpec(value.docker) &&
    isStringRecord(value.env) &&
    isStringArray(value.host_setup_dirs) &&
    Array.isArray(value.mounts) &&
    value.mounts.every(isMount)
  )
}

function isDockerSpec(value: unknown): value is WorkerBootstrapSpec['docker'] {
  return (
    isRecord(value) &&
    isStringArray(value.cap_add) &&
    isStringArray(value.security_opts) &&
    Array.isArray(value.extra_hosts) &&
    value.extra_hosts.every(host => isRecord(host) && isNonEmptyString(host.host) && isNonEmptyString(host.address))
  )
}

function isMount(value: unknown): value is WorkerBootstrapMount {
  return (
    isRecord(value) &&
    isNonEmptyString(value.source) &&
    isNonEmptyString(value.target) &&
    typeof value.readonly === 'boolean'
  )
}

function isStringRecord(value: unknown): value is Record<string, string> {
  return isRecord(value) && Object.values(value).every(item => typeof item === 'string')
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every(item => typeof item === 'string')
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
