import { SQL as BunSQL } from 'bun'
import { sql, type SQL as DrizzleSQL } from 'drizzle-orm'
import { drizzle } from 'drizzle-orm/bun-sql'
import { AppEnv } from '@/config/env'
import * as schema from './db-schema'
import type { JsonValue } from './db-schema'
import { logger } from './logger'
import { seconds } from '@pleisto/active-support'

let closingDatabase = false

export const databaseRuntimeConfig = {
  poolMax: AppEnv.BULLX_DATABASE_POOL_MAX,
  idleTimeoutSeconds: seconds('10m')
} as const

// `bun --hot` re-evaluates this module on every reload; constructing a fresh
// BunSQL each time would leak the previous pool's connections (idle for up to
// 1h) until PostgreSQL exhausts max_connections. Cache the client on
// globalThis so reloads reuse the same pool.
declare global {
  var __bullxSqlClient: BunSQL | undefined
}

const sqlClient = (globalThis.__bullxSqlClient ??= new BunSQL(AppEnv.DATABASE_URL, {
  max: databaseRuntimeConfig.poolMax,
  // Below the idle reap window of network load balancers commonly fronting
  // PostgreSQL (e.g. Volces NLB kills idle TCP flows at ~900s): the client must
  // retire idle connections first or it inherits half-open sockets that surface
  // as ERR_POSTGRES_CONNECTION_CLOSED storms.
  idleTimeout: seconds('10m'),
  connectionTimeout: seconds('20s'),
  maxLifetime: 0,
  onconnect: () => {
    logger.trace('PostgreSQL connection opened')
  },
  onclose: error => {
    if (error && !closingDatabase) logger.error({ error }, 'PostgreSQL connection closed with error')
  }
}))

export const DB = drizzle({
  client: sqlClient,
  schema,
  logger: {
    logQuery(query, params) {
      logger.trace({ query, paramCount: params.length }, 'SQL Query')
    }
  }
})

export type AppDatabase = typeof DB
export type AppDbTransaction = Parameters<Parameters<AppDatabase['transaction']>[0]>[0]

/**
 * Shared query executor accepted by helpers that can run inside an existing
 * transaction.
 *
 * Keeping this type here avoids ad hoc executor aliases in domain services.
 * The important guarantee is not which concrete Drizzle class is used, but that
 * the executor exposes the same query-builder and nested transaction surface.
 */
export type QueryExecutor = AppDatabase | AppDbTransaction

/**
 * Builds a JSONB SQL expression for the current Bun SQL + Drizzle driver path.
 *
 * Drizzle's plain `jsonb()` column encoder currently routes objects and arrays
 * through driver values in a way that is not equivalent to PostgreSQL JSONB for
 * this app: arrays are expanded as SQL lists, and scalar casts differ by value
 * type. Business services should not know those details, so every explicit
 * JSONB write goes through this helper.
 */
export function jsonbParam<TValue extends JsonValue>(value: TValue): DrizzleSQL<TValue> {
  if (Array.isArray(value)) return jsonbArrayParam(value) as DrizzleSQL<TValue>

  if (typeof value === 'number' || typeof value === 'boolean') return sql<TValue>`to_jsonb(${value})`

  return sql<TValue>`${value}::jsonb`
}

function jsonbArrayParam(value: JsonValue[]): DrizzleSQL<JsonValue[]> {
  if (value.length === 0) return sql<JsonValue[]>`'[]'::jsonb`

  return sql<JsonValue[]>`jsonb_build_array(${sql.join(
    value.map(item => jsonbParam(item)),
    sql`, `
  )})`
}

export async function closeDatabase(options?: { timeout?: number }): Promise<void> {
  if (closingDatabase) return

  closingDatabase = true
  await sqlClient.close(options)
}
