import { styledWarn } from './utils'

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

export type SccacheMode = 'auto' | 'enabled' | 'disabled'

export type SccacheOptions = {
  resolveExecutable?: (pathEnv: string | undefined) => string | null
  warn?: (message: string) => void
}

export function resolveSccacheMode(value: string | undefined): SccacheMode {
  const normalized = value?.trim().toLowerCase()
  if (!normalized || normalized === 'auto') return 'auto'
  if (normalized === '1' || normalized === 'true') return 'enabled'
  if (normalized === '0' || normalized === 'false') return 'disabled'
  throw new Error(`Invalid ANKOLE_SCCACHE value "${value}"; expected 0, 1, true, false, or auto.`)
}

/**
 * Automatically wraps Cargo with `sccache` backed strictly by the local SSD
 * cache whenever `sccache` is installed on `PATH`. Contributors without
 * `sccache` fall back silently to standard Cargo, `ANKOLE_SCCACHE=0` disables
 * the wrapper explicitly, and an explicit `RUSTC_WRAPPER` always wins.
 */
export function applyOptionalLocalSccacheEnv(env: NodeJS.ProcessEnv, options: SccacheOptions = {}): NodeJS.ProcessEnv {
  const mode = resolveSccacheMode(env.ANKOLE_SCCACHE)
  if (mode === 'disabled') return { ...env }
  if (env.RUSTC_WRAPPER?.trim()) return { ...env }

  const resolveExecutable =
    options.resolveExecutable ??
    ((pathEnv: string | undefined) => Bun.which('sccache', pathEnv ? { PATH: pathEnv } : undefined))
  const sccachePath = resolveExecutable(env.PATH ?? process.env.PATH)

  if (!sccachePath) {
    if (mode === 'enabled') {
      const warn = options.warn ?? ((message: string) => console.warn(styledWarn(message)))
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
