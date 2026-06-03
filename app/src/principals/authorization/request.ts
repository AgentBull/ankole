import { normalizeUid, type Principal, PrincipalDomainError } from '../principals/service'

const resourceGlobCharacters = /[*?[\]{}]/

/**
 * Normalized request shape consumed by the TS AuthZ loader and native engine.
 */
export interface AuthorizationRequest {
  principalUid: string
  resource: string
  action: string
  context: Record<string, unknown>
}

/**
 * Normalizes a caller-facing authorization request.
 *
 * Request resources are concrete resource keys, not patterns. Persisted grants
 * may contain glob syntax, but a request such as `ai_agent:*` is rejected so a
 * caller cannot ask whether it has a whole pattern of access in one check.
 */
export function buildAuthorizationRequest(
  principalOrUid: Principal | string,
  resource: string,
  action: string,
  context: Record<string, unknown> = {}
): AuthorizationRequest {
  return {
    principalUid: typeof principalOrUid === 'string' ? normalizeUid(principalOrUid) : principalOrUid.uid,
    resource: normalizeResource(resource),
    action: normalizeAction(action),
    context: normalizeContext(context)
  }
}

/**
 * Splits `resource:action` permission keys.
 *
 * The last colon separates action from resource, which allows resource keys to
 * keep using colon-delimited hierarchy such as `ai_agent:default`.
 */
export function splitPermissionKey(permission: string): { resource: string; action: string } {
  const parts = permission.split(':')
  if (parts.length < 2) {
    throw new PrincipalDomainError('invalid_request', 'permission key must include resource and action')
  }

  const action = parts.pop()
  if (!action) throw new PrincipalDomainError('invalid_request', 'permission action must not be empty')

  return {
    resource: normalizeResource(parts.join(':')),
    action: normalizeAction(action)
  }
}

/**
 * Normalizes a concrete resource key and rejects glob characters.
 */
export function normalizeResource(resource: string): string {
  const normalized = normalizeNonEmptyString(resource, 'resource')
  if (resourceGlobCharacters.test(normalized)) {
    throw new PrincipalDomainError('invalid_request', 'request resource must not contain glob characters')
  }

  return normalized
}

/**
 * Normalizes an exact action key.
 *
 * Actions do not use colon hierarchy; colon belongs to resource keys and the
 * `resource:action` permission-key separator.
 */
export function normalizeAction(action: string): string {
  const normalized = normalizeNonEmptyString(action, 'action')
  if (normalized.includes(':')) throw new PrincipalDomainError('invalid_request', 'action must not contain colon')

  return normalized
}

/**
 * Ensures caller-supplied request context is JSON-object shaped.
 *
 * Native CEL conditions receive this under `context.request`.
 */
export function normalizeContext(context: Record<string, unknown>): Record<string, unknown> {
  if (!isJsonObject(context)) throw new PrincipalDomainError('invalid_request', 'context must be a JSON object')

  return context
}

function normalizeNonEmptyString(value: string, field: string): string {
  if (typeof value !== 'string') throw new PrincipalDomainError('invalid_request', `${field} must be a string`)

  const normalized = value.trim()
  if (!normalized) throw new PrincipalDomainError('invalid_request', `${field} must not be empty`)

  return normalized
}

function isJsonObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
