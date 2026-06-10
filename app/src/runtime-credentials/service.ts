import { aeadDecrypt, aeadEncrypt, genUUIDv7, genericHash } from '@agentbull/bullx-native-addons'
import type { Computer } from '@agentbull/bullx-computer'
import { and, eq, isNull, sql } from 'drizzle-orm'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import { RuntimeCredentials, type JsonObject } from '@/common/db-schema'
import { getSecretKey, SecretKeyPurpose } from '@/common/kms'
import { isJsonObject } from '@/common/json'

export type RuntimeCredentialConsumerKind = 'skill' | 'tool' | 'runtime'
export type RuntimeCredentialScope = { kind: 'default'; agentUid?: undefined } | { kind: 'agent'; agentUid: string }

export interface RuntimeCredentialRef {
  consumerKind: RuntimeCredentialConsumerKind
  consumerName: string
  credentialName: string
}

export interface SetRuntimeCredentialInput extends RuntimeCredentialRef {
  scope: RuntimeCredentialScope
  payload: string
  payloadMediaType?: string
  metadata?: JsonObject
  executor?: QueryExecutor
}

export interface DeleteRuntimeCredentialInput extends RuntimeCredentialRef {
  scope: RuntimeCredentialScope
  executor?: QueryExecutor
}

export interface ResolveRuntimeCredentialInput extends RuntimeCredentialRef {
  agentUid: string
  executor?: QueryExecutor
}

export interface ResolvedRuntimeCredential extends RuntimeCredentialRef {
  id: string
  scope: RuntimeCredentialScope
  payload: string
  payloadMediaType: string
  payloadBlake3: string
  metadata: JsonObject
}

export interface MaterializeRuntimeCredentialInput extends ResolveRuntimeCredentialInput {
  computer: Pick<Computer, 'writeFiles'>
  path: string
  mode?: number
}

export async function setRuntimeCredential(input: SetRuntimeCredentialInput): Promise<ResolvedRuntimeCredential> {
  const executor = input.executor ?? DB
  const ref = normalizeRef(input)
  const scope = normalizeScope(input.scope)
  const payloadMediaType = normalizePayloadMediaType(input.payloadMediaType)
  const metadata = normalizeMetadata(input.metadata)
  const payloadBlake3 = stableHash(input.payload)
  const encryptedPayload = encryptPayload(ref, scope, input.payload)
  const id = genUUIDv7()
  const shared = {
    consumerKind: ref.consumerKind,
    consumerName: ref.consumerName,
    credentialName: ref.credentialName,
    scopeKind: scope.kind,
    agentUid: scope.kind === 'agent' ? scope.agentUid : null,
    encryptedPayload,
    payloadMediaType,
    payloadBlake3,
    metadata: jsonbParam(metadata),
    enabled: true,
    updatedAt: sql`now()`
  }

  const conflict =
    scope.kind === 'default'
      ? {
          target: [RuntimeCredentials.consumerKind, RuntimeCredentials.consumerName, RuntimeCredentials.credentialName],
          targetWhere: sql`${RuntimeCredentials.scopeKind} = 'default'`,
          set: shared
        }
      : {
          target: [
            RuntimeCredentials.consumerKind,
            RuntimeCredentials.consumerName,
            RuntimeCredentials.credentialName,
            RuntimeCredentials.agentUid
          ],
          targetWhere: sql`${RuntimeCredentials.scopeKind} = 'agent'`,
          set: shared
        }

  const [row] = await executor
    .insert(RuntimeCredentials)
    .values({
      id,
      ...shared
    })
    .onConflictDoUpdate(conflict)
    .returning()

  if (!row) throw new RuntimeCredentialError('credential_write_failed', 'failed to persist runtime credential')
  return rowToResolved(row)
}

export async function deleteRuntimeCredential(input: DeleteRuntimeCredentialInput): Promise<void> {
  const executor = input.executor ?? DB
  const ref = normalizeRef(input)
  const scope = normalizeScope(input.scope)
  await executor.delete(RuntimeCredentials).where(scopeWhere(ref, scope))
}

export async function resolveRuntimeCredential(
  input: ResolveRuntimeCredentialInput
): Promise<ResolvedRuntimeCredential | null> {
  const executor = input.executor ?? DB
  const ref = normalizeRef(input)
  const agentUid = normalizeAgentUid(input.agentUid)
  const [agentRow] = await executor
    .select()
    .from(RuntimeCredentials)
    .where(and(scopeWhere(ref, { kind: 'agent', agentUid }), eq(RuntimeCredentials.enabled, true)))
    .limit(1)
  if (agentRow) return rowToResolved(agentRow)

  const [defaultRow] = await executor
    .select()
    .from(RuntimeCredentials)
    .where(and(scopeWhere(ref, { kind: 'default' }), eq(RuntimeCredentials.enabled, true)))
    .limit(1)
  return defaultRow ? rowToResolved(defaultRow) : null
}

export async function materializeRuntimeCredential(
  input: MaterializeRuntimeCredentialInput
): Promise<ResolvedRuntimeCredential | null> {
  const credential = await resolveRuntimeCredential(input)
  if (!credential) return null
  const path = normalizeMaterializationPath(input.path)
  await input.computer.writeFiles([
    {
      path,
      content: credential.payload,
      mode: input.mode ?? 0o600
    }
  ])
  return credential
}

function rowToResolved(row: typeof RuntimeCredentials.$inferSelect): ResolvedRuntimeCredential {
  const ref = {
    consumerKind: row.consumerKind as RuntimeCredentialConsumerKind,
    consumerName: row.consumerName,
    credentialName: row.credentialName
  }
  const scope: RuntimeCredentialScope =
    row.scopeKind === 'agent' ? { kind: 'agent', agentUid: normalizeAgentUid(row.agentUid ?? '') } : { kind: 'default' }
  return {
    id: row.id,
    ...ref,
    scope,
    payload: decryptPayload(ref, scope, row.encryptedPayload),
    payloadMediaType: row.payloadMediaType,
    payloadBlake3: row.payloadBlake3,
    metadata: row.metadata ?? {}
  }
}

function scopeWhere(ref: RuntimeCredentialRef, scope: RuntimeCredentialScope) {
  const base = and(
    eq(RuntimeCredentials.consumerKind, ref.consumerKind),
    eq(RuntimeCredentials.consumerName, ref.consumerName),
    eq(RuntimeCredentials.credentialName, ref.credentialName),
    eq(RuntimeCredentials.scopeKind, scope.kind)
  )
  return scope.kind === 'default'
    ? and(base, isNull(RuntimeCredentials.agentUid))
    : and(base, eq(RuntimeCredentials.agentUid, normalizeAgentUid(scope.agentUid)))
}

function encryptPayload(ref: RuntimeCredentialRef, scope: RuntimeCredentialScope, payload: string): string {
  return aeadEncrypt(payload, encryptionKey(ref, scope))
}

function decryptPayload(ref: RuntimeCredentialRef, scope: RuntimeCredentialScope, encryptedPayload: string): string {
  return aeadDecrypt(encryptedPayload, encryptionKey(ref, scope)).toString('utf-8')
}

function encryptionKey(ref: RuntimeCredentialRef, scope: RuntimeCredentialScope): string {
  const scopeKey = scope.kind === 'agent' ? `agent:${normalizeAgentUid(scope.agentUid)}` : 'default'
  return getSecretKey(
    SecretKeyPurpose.DATABASE_ENCRYPTION,
    `runtime_credentials:${ref.consumerKind}:${ref.consumerName}:${ref.credentialName}:${scopeKey}`
  )
}

function normalizeRef(input: RuntimeCredentialRef): RuntimeCredentialRef {
  return {
    consumerKind: normalizeConsumerKind(input.consumerKind),
    consumerName: normalizeName(input.consumerName, 'consumerName'),
    credentialName: normalizeName(input.credentialName, 'credentialName')
  }
}

function normalizeConsumerKind(value: string): RuntimeCredentialConsumerKind {
  if (value === 'skill' || value === 'tool' || value === 'runtime') return value
  throw new RuntimeCredentialError('invalid_consumer_kind', `invalid credential consumer kind: ${value}`)
}

function normalizeScope(scope: RuntimeCredentialScope): RuntimeCredentialScope {
  if (scope.kind === 'default') return { kind: 'default' }
  if (scope.kind === 'agent') return { kind: 'agent', agentUid: normalizeAgentUid(scope.agentUid) }
  throw new RuntimeCredentialError('invalid_scope', `invalid credential scope: ${JSON.stringify(scope)}`)
}

function normalizeName(value: string, field: string): string {
  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-')
  if (!/^[a-z][a-z0-9_-]{0,63}$/.test(normalized)) {
    throw new RuntimeCredentialError('invalid_name', `invalid ${field}: ${value}`)
  }
  return normalized
}

function normalizeAgentUid(value: string): string {
  const uid = value.trim().toLowerCase()
  if (!uid) throw new RuntimeCredentialError('invalid_agent_uid', 'agent_uid is required')
  return uid
}

function normalizePayloadMediaType(value: string | undefined): string {
  const mediaType = (value ?? 'text/plain').trim()
  if (!mediaType) throw new RuntimeCredentialError('invalid_payload_media_type', 'payload media type is required')
  return mediaType
}

function normalizeMetadata(value: JsonObject | undefined): JsonObject {
  if (value === undefined) return {}
  if (!isJsonObject(value)) throw new RuntimeCredentialError('invalid_metadata', 'metadata must be a JSON object')
  return value
}

function normalizeMaterializationPath(value: string): string {
  const path = value.trim().replace(/\\/g, '/').replace(/^\/+/, '').replace(/\/+/g, '/')
  if (!path || path.split('/').some(part => !part || part === '.' || part === '..')) {
    throw new RuntimeCredentialError(
      'invalid_materialization_path',
      `invalid credential materialization path: ${value}`
    )
  }
  if (!path.startsWith('temp/')) {
    throw new RuntimeCredentialError(
      'invalid_materialization_path',
      'credential materialization path must be under /workspace/temp'
    )
  }
  return path
}

function stableHash(payload: string): string {
  return genericHash(payload)
}

export class RuntimeCredentialError extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message)
    this.name = 'RuntimeCredentialError'
  }
}
