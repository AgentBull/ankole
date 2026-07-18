import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { chmod, lstat, mkdir, open, readFile, readdir, realpath, rename, rm, stat } from 'node:fs/promises'
import { dirname, join, relative, resolve } from 'node:path'
import {
  BrowserBackendSchema,
  BrowserMaterialSchema,
  BrowserProtocolVersion,
  type BrowserBackend,
  type BrowserMaterial
} from '@ankole/browser/protocol'

export const BrowserMaterialSourceEnvNames = [
  'BROWSER_BACKEND_JSON',
  'BROWSER_PROFILE_SEED_PATH',
  'BROWSER_PROFILE_SEED_FINGERPRINT'
] as const

const maxSeedFiles = 20_000
const maxSeedBytes = 1024 * 1024 * 1024
const routeRecordVersion = 1

type RouteRecord = {
  version: 1
  route_id: string
  immutable_key: string
  material_hash: string
  material_generation: number
}

export type BrowserMaterializeSettings = {
  workerEnv?: Record<string, string>
  ssrfFilter: boolean
}

export type RenderedFetchBrowserMaterializeSettings = BrowserMaterializeSettings & {
  idleTtlMs?: number
}

export type MaterializedBrowserRuntime = {
  route: string
  session: string
  socketPath: string
  materialPath: string
  material: BrowserMaterial
  artifactRoot: string
  nodePath: string
  runnerPath: string
  cleanup(): Promise<void>
}

export class BrowserRouteMaterializer {
  readonly root: string
  readonly socketPath: string
  readonly nodePath: string
  readonly runnerPath: string
  readonly localChromiumExecutable: string

  constructor(options: {
    root: string
    socketPath?: string
    nodePath?: string
    runnerPath?: string
    localChromiumExecutable?: string
  }) {
    this.root = resolve(options.root)
    this.socketPath = options.socketPath ?? '/run/ankole-browser/socket/browser.sock'
    this.nodePath = options.nodePath ?? '/opt/ankole-browser/node/bin/node'
    this.runnerPath = options.runnerPath ?? '/opt/ankole-browser/dist/runner/bootstrap.js'
    this.localChromiumExecutable =
      options.localChromiumExecutable ?? '/opt/ankole-browser/browsers/chromium/chrome-headless-shell'
  }

  async materializePersistent(input: {
    scopeRoot: string
    artifactRoot: string
    settings: BrowserMaterializeSettings
  }): Promise<MaterializedBrowserRuntime> {
    const backend = this.backend(input.settings.workerEnv)
    const profile = await this.profile(input.settings.workerEnv)
    const immutableKey = materialHash({
      backend: immutableBackendIdentity(backend),
      profile: { seed_fingerprint: profile.seed_fingerprint ?? null }
    })
    const routeRecordPath = join(resolve(input.scopeRoot), '.ankole', 'browser-route.json')
    const previous = await readRouteRecord(routeRecordPath)
    const route = previous?.immutable_key === immutableKey ? previous.route_id : opaqueRoute()
    const dataRoot = join(this.root, 'routes', route)
    const artifactRoot = resolve(input.artifactRoot)
    const materialBase = {
      protocol_version: BrowserProtocolVersion,
      route_id: route,
      data_root: dataRoot,
      artifact_root: artifactRoot,
      immutable_fingerprint: materialHash({ route, data_root: dataRoot, immutable_key: immutableKey }),
      profile,
      backend,
      navigation: { ssrf_filter: input.settings.ssrfFilter, allow_file_urls: false },
      idle_ttl_ms: 30 * 60 * 1_000
    }
    const nextMaterialHash = materialHash(materialBase)
    const generation =
      previous?.route_id === route && previous.material_hash !== nextMaterialHash
        ? previous.material_generation + 1
        : previous?.route_id === route
          ? previous.material_generation
          : 0
    await atomicJSON(routeRecordPath, {
      version: routeRecordVersion,
      route_id: route,
      immutable_key: immutableKey,
      material_hash: nextMaterialHash,
      material_generation: generation
    } satisfies RouteRecord)
    return await this.writeMaterial({ ...materialBase, material_generation: generation }, artifactRoot)
  }

  async materializeEphemeral(input: {
    settings: RenderedFetchBrowserMaterializeSettings
  }): Promise<MaterializedBrowserRuntime> {
    const backend = this.backend(input.settings.workerEnv)
    const profile = await this.profile(input.settings.workerEnv)
    const route = opaqueRoute()
    const dataRoot = join(this.root, 'routes', route)
    const artifactRoot = join(this.root, 'ephemeral-artifacts', route)
    const material: BrowserMaterial = BrowserMaterialSchema.parse({
      protocol_version: BrowserProtocolVersion,
      route_id: route,
      data_root: dataRoot,
      artifact_root: artifactRoot,
      immutable_fingerprint: materialHash({
        route,
        data_root: dataRoot,
        backend: immutableBackendIdentity(backend),
        profile: { seed_fingerprint: profile.seed_fingerprint ?? null }
      }),
      material_generation: 0,
      profile,
      backend,
      navigation: { ssrf_filter: input.settings.ssrfFilter, allow_file_urls: false },
      idle_ttl_ms: input.settings.idleTtlMs ?? 30 * 60 * 1_000
    })
    return await this.writeMaterial(material, artifactRoot)
  }

  private async writeMaterial(
    candidate: Omit<BrowserMaterial, 'material_generation'> & { material_generation: number },
    artifactRoot: string
  ): Promise<MaterializedBrowserRuntime> {
    const material = BrowserMaterialSchema.parse(candidate)
    await mkdir(material.data_root, { recursive: true })
    await mkdir(artifactRoot, { recursive: true })
    const materialPath = join(this.root, 'materials', `${material.route_id}-${crypto.randomUUID()}.json`)
    await atomicJSON(materialPath, material)
    await chmod(materialPath, 0o600)
    return {
      route: material.route_id,
      session: 'default',
      socketPath: this.socketPath,
      materialPath,
      material,
      artifactRoot,
      nodePath: this.nodePath,
      runnerPath: this.runnerPath,
      cleanup: async () => rm(materialPath, { force: true })
    }
  }

  private backend(workerEnv: Record<string, string> | undefined): BrowserBackend {
    const raw = workerEnv?.BROWSER_BACKEND_JSON?.trim()
    if (raw) {
      try {
        return BrowserBackendSchema.parse(JSON.parse(raw))
      } catch (error) {
        throw new Error(`BROWSER_BACKEND_JSON must contain final browser backend material: ${errorMessage(error)}`)
      }
    }
    return BrowserBackendSchema.parse({
      kind: 'local_chromium',
      executable: this.localChromiumExecutable,
      args: browserArgsFromEnv(process.env.ANKOLE_BROWSER_CHROMIUM_ARGS_JSON)
    })
  }

  private async profile(workerEnv: Record<string, string> | undefined): Promise<BrowserMaterial['profile']> {
    const configuredPath = workerEnv?.BROWSER_PROFILE_SEED_PATH?.trim()
    if (!configuredPath) return { mode: 'persistent_user_data_dir' }
    const seedPath = await realpath(configuredPath)
    if (!(await stat(seedPath)).isDirectory()) throw new Error('BROWSER_PROFILE_SEED_PATH must be a directory')
    const suppliedFingerprint = workerEnv?.BROWSER_PROFILE_SEED_FINGERPRINT?.trim()
    return {
      mode: 'persistent_user_data_dir',
      seed_path: seedPath,
      seed_fingerprint: suppliedFingerprint || (await fingerprintDirectory(seedPath))
    }
  }
}

export function withoutBrowserMaterialSourceEnv(workerEnv: Record<string, string>): Record<string, string> {
  const output = { ...workerEnv }
  for (const name of BrowserMaterialSourceEnvNames) delete output[name]
  return output
}

async function readRouteRecord(path: string): Promise<RouteRecord | undefined> {
  try {
    const parsed = JSON.parse(await readFile(path, 'utf8')) as Partial<RouteRecord>
    if (
      parsed.version !== routeRecordVersion ||
      typeof parsed.route_id !== 'string' ||
      !/^br_[A-Za-z0-9_-]{16,128}$/.test(parsed.route_id) ||
      typeof parsed.immutable_key !== 'string' ||
      typeof parsed.material_hash !== 'string' ||
      !Number.isInteger(parsed.material_generation) ||
      parsed.material_generation! < 0
    ) {
      throw new Error('browser route record is invalid')
    }
    return parsed as RouteRecord
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    throw error
  }
}

function immutableBackendIdentity(backend: BrowserBackend): Record<string, unknown> {
  if (backend.kind === 'local_chromium') return { kind: backend.kind, executable: backend.executable }
  return { kind: backend.kind, session_identity: backend.session_identity }
}

function opaqueRoute(): string {
  return `br_${Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString('base64url')}`
}

function materialHash(value: unknown): string {
  return `sha256:${createHash('sha256').update(canonicalJSON(value)).digest('hex')}`
}

function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`
  if (value && typeof value === 'object') {
    return `{${Object.entries(value)
      .sort(([left], [right]) => compareCodePoints(left, right))
      .map(([key, item]) => `${JSON.stringify(key)}:${canonicalJSON(item)}`)
      .join(',')}}`
  }
  return JSON.stringify(value)
}

async function fingerprintDirectory(root: string): Promise<string> {
  const hash = createHash('sha256')
  let files = 0
  let bytes = 0

  const visit = async (directory: string): Promise<void> => {
    const entries = (await readdir(directory, { withFileTypes: true })).sort((left, right) =>
      compareCodePoints(left.name, right.name)
    )
    for (const entry of entries) {
      const path = join(directory, entry.name)
      const name = relative(root, path).replaceAll('\\', '/')
      const info = await lstat(path)
      if (info.isSymbolicLink()) throw new Error(`browser profile seed cannot contain symlink: ${name}`)
      if (info.isDirectory()) {
        hash.update(`d\0${name}\0`)
        await visit(path)
        continue
      }
      if (!info.isFile()) throw new Error(`browser profile seed contains unsupported entry: ${name}`)
      files += 1
      bytes += info.size
      if (files > maxSeedFiles || bytes > maxSeedBytes) {
        throw new Error('browser profile seed exceeds materialization limits')
      }
      hash.update(`f\0${name}\0${info.size}\0`)
      for await (const chunk of createReadStream(path)) hash.update(chunk)
    }
  }
  await visit(root)
  return `sha256:${hash.digest('hex')}`
}

async function atomicJSON(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  const temporary = `${path}.${crypto.randomUUID()}.tmp`
  const file = await open(temporary, 'w', 0o600)
  try {
    await file.writeFile(`${JSON.stringify(value, null, 2)}\n`)
  } finally {
    await file.close()
  }
  await rename(temporary, path)
}

function browserArgsFromEnv(value: string | undefined): string[] {
  if (!value?.trim()) return []
  const parsed = JSON.parse(value) as unknown
  if (!Array.isArray(parsed) || !parsed.every(item => typeof item === 'string')) {
    throw new Error('ANKOLE_BROWSER_CHROMIUM_ARGS_JSON must be a JSON string array')
  }
  return parsed
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
