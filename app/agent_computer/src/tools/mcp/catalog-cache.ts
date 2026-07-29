import { createHash } from 'node:crypto'
import { injectableWorkerEnv } from '../computer/env'
import { listMCPServerCatalog, type MCPClientOperationOptions, type MCPServerCatalog } from './client'
import { mcpServerConnectionIdentity, type MCPServerConfig } from './config'
import { compareCodePointStrings } from './ordering'

const CATALOG_CACHE_TTL_MS = 5 * 60 * 1000
const MAX_CATALOG_CACHE_ENTRIES = 32

interface CatalogCacheEntry {
  expiresAt: number
  catalog: MCPServerCatalog
}

const catalogCache = new Map<string, CatalogCacheEntry>()

/** Returns a process-cached catalog without causing any external connection. */
export function peekMCPServerCatalog(
  server: MCPServerConfig,
  workerEnv?: Record<string, string>
): MCPServerCatalog | undefined {
  const key = catalogCacheKey(server, workerEnv)
  const entry = catalogCache.get(key)
  if (!entry) return undefined
  if (entry.expiresAt <= Date.now()) {
    catalogCache.delete(key)
    return undefined
  }

  // Refresh insertion order for bounded LRU eviction without extending TTL.
  catalogCache.delete(key)
  catalogCache.set(key, entry)
  return entry.catalog
}

/** Loads one selected server catalog and caches only a successful bounded result. */
export async function resolveMCPServerCatalog(
  server: MCPServerConfig,
  options: MCPClientOperationOptions
): Promise<MCPServerCatalog> {
  const cached = peekMCPServerCatalog(server, options.workerEnv)
  if (cached) return cached

  // Pending loads are deliberately not shared across turns: one caller's
  // AbortSignal must never cancel another caller that happens to use the same
  // server and credential identity.
  const catalog = await listMCPServerCatalog(server, options)
  assertCatalogContainsNoWorkerEnv(server, catalog, options.workerEnv)
  setCatalogCacheEntry(catalogCacheKey(server, options.workerEnv), catalog)
  return catalog
}

function assertCatalogContainsNoWorkerEnv(
  server: MCPServerConfig,
  catalog: MCPServerCatalog,
  workerEnv?: Record<string, string>
): void {
  const secrets = workerEnvValuesVisibleToServer(server, workerEnv)
  if (secrets.length === 0 || !containsAnySecret(catalog, secrets)) return
  throw new Error('MCP catalog contained WorkerEnv data and was rejected')
}

function workerEnvValuesVisibleToServer(server: MCPServerConfig, workerEnv?: Record<string, string>): string[] {
  const resolvedWorkerEnv = Object.fromEntries(injectableWorkerEnv(workerEnv))
  const values =
    server.transport === 'streamable_http'
      ? server.bearerTokenEnvVar
        ? [resolvedWorkerEnv[server.bearerTokenEnvVar]]
        : []
      : Object.values(resolvedWorkerEnv)
  return [...new Set(values.filter((value): value is string => typeof value === 'string' && value.length > 0))]
}

function containsAnySecret(value: unknown, secrets: string[]): boolean {
  if (typeof value === 'string') return secrets.some(secret => value.includes(secret))
  if (Array.isArray(value)) return value.some(entry => containsAnySecret(entry, secrets))
  if (value === null || typeof value !== 'object') return false
  return Object.entries(value as Record<string, unknown>).some(
    ([key, entry]) => containsAnySecret(key, secrets) || containsAnySecret(entry, secrets)
  )
}

function setCatalogCacheEntry(key: string, catalog: MCPServerCatalog): void {
  const now = Date.now()
  for (const [candidate, entry] of catalogCache) {
    if (entry.expiresAt <= now) catalogCache.delete(candidate)
  }
  catalogCache.delete(key)
  while (catalogCache.size >= MAX_CATALOG_CACHE_ENTRIES) {
    const oldest = catalogCache.keys().next().value
    if (typeof oldest !== 'string') break
    catalogCache.delete(oldest)
  }
  catalogCache.set(key, { expiresAt: now + CATALOG_CACHE_TTL_MS, catalog })
}

function catalogCacheKey(server: MCPServerConfig, workerEnv?: Record<string, string>): string {
  const resolvedWorkerEnv = Object.fromEntries(injectableWorkerEnv(workerEnv))
  const credentialIdentity =
    server.transport === 'streamable_http'
      ? server.bearerTokenEnvVar
        ? [[server.bearerTokenEnvVar, resolvedWorkerEnv[server.bearerTokenEnvVar] ?? null]]
        : []
      : Object.entries(resolvedWorkerEnv).sort(([left], [right]) => compareCodePointStrings(left, right))

  return createHash('sha256')
    .update(
      JSON.stringify({
        server: mcpServerConnectionIdentity(server),
        skillGeneration: server.generation,
        credentialIdentity
      })
    )
    .digest('hex')
}
