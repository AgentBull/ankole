import { spawnSync } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const kernelRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

const remoteBackendEnvKeys = [
  'SCCACHE_BUCKET',
  'SCCACHE_REDIS',
  'SCCACHE_REDIS_ENDPOINT',
  'SCCACHE_MEMCACHED',
  'SCCACHE_MEMCACHED_ENDPOINT',
  'SCCACHE_GCS_BUCKET',
  'SCCACHE_AZURE_CONNECTION_STRING',
  'SCCACHE_AZURE_BLOB_CONTAINER',
  'SCCACHE_WEBDAV_ENDPOINT',
  'SCCACHE_GHA_ENABLED',
  'SCCACHE_S3_KEY_PREFIX'
] as const

export type CargoEnvOptions = {
  resolveExecutable?: (pathEnv: string | undefined) => string | null
  warn?: (message: string) => void
}

function resolveMode(raw: string | undefined): 'auto' | 'enabled' | 'disabled' {
  const normalized = raw?.trim().toLowerCase()
  if (!normalized || normalized === 'auto') return 'auto'
  if (normalized === '1' || normalized === 'true') return 'enabled'
  if (normalized === '0' || normalized === 'false') return 'disabled'
  throw new Error(`Invalid ANKOLE_SCCACHE value "${raw}"; expected 0, 1, true, false, or auto.`)
}

export function buildCargoEnv(env: NodeJS.ProcessEnv = process.env, options: CargoEnvOptions = {}): NodeJS.ProcessEnv {
  const mode = resolveMode(env.ANKOLE_SCCACHE)
  if (mode === 'disabled') return { ...env }
  if (env.RUSTC_WRAPPER?.trim()) return { ...env }

  const resolveExecutable =
    options.resolveExecutable ??
    ((pathEnv: string | undefined) => Bun.which('sccache', pathEnv ? { PATH: pathEnv } : undefined))
  const sccachePath = resolveExecutable(env.PATH ?? process.env.PATH)

  if (!sccachePath) {
    if (mode === 'enabled') {
      const warn = options.warn ?? ((message: string) => console.warn(`WARN: ${message}`))
      warn(
        'ANKOLE_SCCACHE=1 is set, but sccache is not on PATH; continuing with standard Cargo. Install it with: bun run kit env-setup'
      )
    }
    return { ...env }
  }

  const nextEnv: NodeJS.ProcessEnv = { ...env }
  for (const key of remoteBackendEnvKeys) {
    delete nextEnv[key]
  }

  nextEnv.RUSTC_WRAPPER = sccachePath
  nextEnv.CMAKE_C_COMPILER_LAUNCHER = env.CMAKE_C_COMPILER_LAUNCHER?.trim() || sccachePath
  nextEnv.CMAKE_CXX_COMPILER_LAUNCHER = env.CMAKE_CXX_COMPILER_LAUNCHER?.trim() || sccachePath
  nextEnv.SCCACHE_CACHE_SIZE = env.SCCACHE_CACHE_SIZE?.trim() || '20G'
  return nextEnv
}

export function runCargo(args: string[]): void {
  const result = spawnSync('cargo', args, {
    cwd: kernelRoot,
    env: buildCargoEnv(),
    stdio: 'inherit'
  })
  if (result.error) throw new Error(`cargo failed to start: ${result.error.message}`)
  if (result.status !== 0) {
    throw new Error(`cargo ${args.join(' ')} exited with ${result.status}`)
  }
}

if (import.meta.main) runCargo(process.argv.slice(2))
