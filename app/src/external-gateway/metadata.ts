import { isPlainObject } from '@pleisto/active-support'
import type { JsonObject, JsonValue } from '@/common/db-schema'

const channelNamePattern = /^[a-z][a-z0-9_]*$/
const groupMessageModes = new Set(['addressed_only', 'observe_all', 'may_intervene'])

export type GroupMessageMode = 'addressed_only' | 'observe_all' | 'may_intervene'

/**
 * One enabled `agents.metadata.external.adapters[]` entry after validation.
 *
 * `name` is intentionally separate from `adapter`: `name` is the public binding
 * key used in `/api/agents/:agentUid/webhooks/:channel` and in
 * `chat.webhooks[name]`, while `adapter` is the DI-registered factory id.
 */
export interface AgentExternalBinding {
  adapter: string
  enabled: boolean
  groupMessageMode?: GroupMessageMode
  name: string
}

/**
 * Raised when agent metadata does not describe External Gateway bindings in the shape
 * External Gateway V1 understands. Startup fails on this instead of silently skipping
 * a malformed enabled channel, because otherwise an operator would see the
 * agent as active while its IM ingress is actually unreachable.
 */
export class AgentChatMetadataError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AgentChatMetadataError'
  }
}

/**
 * Extracts the V1 external binding list from `agents.metadata`.
 *
 * Supported metadata shape:
 *
 * ```json
 * {
 *   "external": {
 *     "adapters": [
 *       {
 *         "name": "slack",
 *         "adapter": "slack",
 *         "enabled": true,
 *         "group_message_mode": "observe_all"
 *       }
 *     ]
 *   }
 * }
 * ```
 *
 * The legacy `chat.adapters` shape is still accepted while the repo migrates to
 * External Gateway naming. Missing adapter metadata means "this active agent has
 * no External Gateway bindings yet" and is not an error. Malformed configured
 * bindings are errors because they represent an explicit but impossible runtime
 * request.
 */
export function parseAgentExternalBindings(metadata: JsonObject): AgentExternalBinding[] {
  // Runtime only routes enabled bindings. Two same-named enabled bindings are an
  // impossible runtime request; a disabled duplicate is ignored here.
  const bindings = parseAgentExternalBindingList(metadata).filter(binding => binding.enabled)
  assertUniqueBindingNames(bindings)
  return bindings
}

/**
 * Like {@link parseAgentExternalBindings} but keeps disabled bindings too.
 *
 * The admin console manages disabled channels, so it needs the full list and
 * dedups across all names (not just enabled ones). This shares the per-binding
 * validation with the runtime path so the two cannot drift.
 */
export function parseAgentExternalBindingsAll(metadata: JsonObject): AgentExternalBinding[] {
  const bindings = parseAgentExternalBindingList(metadata)
  assertUniqueBindingNames(bindings)
  return bindings
}

/**
 * Writes the binding list back into `agents.metadata.external.adapters`, dropping
 * the legacy `chat` key. Shared by the console create/update/delete channel paths.
 */
export function writeAgentExternalBindings(
  metadata: JsonObject,
  bindings: readonly AgentExternalBinding[]
): JsonObject {
  const next = structuredClone(metadata)
  const external = jsonObject(next.external)
    ? structuredClone(next.external as JsonObject)
    : jsonObject(next.chat)
      ? structuredClone(next.chat as JsonObject)
      : {}
  external.adapters = bindings.map(binding => ({
    name: binding.name,
    adapter: binding.adapter,
    enabled: binding.enabled,
    ...(binding.groupMessageMode ? { group_message_mode: binding.groupMessageMode } : {})
  }))
  next.external = external
  delete next.chat
  return next
}

function parseAgentExternalBindingList(metadata: JsonObject): AgentExternalBinding[] {
  const external = jsonObject(metadata.external) ?? jsonObject(metadata.chat)
  if (!external) return []

  const adapters = external.adapters
  if (adapters === undefined) return []

  if (!Array.isArray(adapters)) {
    throw new AgentChatMetadataError('agents.metadata.external.adapters must be an array')
  }

  return adapters.map(parseBinding)
}

function assertUniqueBindingNames(bindings: readonly AgentExternalBinding[]): void {
  const seen = new Set<string>()
  for (const binding of bindings) {
    if (seen.has(binding.name)) {
      throw new AgentChatMetadataError(`duplicate External Gateway binding name: ${binding.name}`)
    }

    seen.add(binding.name)
  }
}

function parseBinding(value: JsonValue, index: number): AgentExternalBinding {
  const input = jsonObject(value)
  if (!input) throw new AgentChatMetadataError(`agents.metadata.external.adapters[${index}] must be an object`)

  const name = requiredChannelName(input.name, `agents.metadata.external.adapters[${index}].name`)
  const adapter = requiredChannelName(input.adapter, `agents.metadata.external.adapters[${index}].adapter`)
  const enabled = input.enabled === undefined ? true : input.enabled
  const groupMessageMode = optionalGroupMessageMode(
    input.group_message_mode ?? input.groupMessageMode,
    `agents.metadata.external.adapters[${index}].group_message_mode`
  )

  if (typeof enabled !== 'boolean') {
    throw new AgentChatMetadataError(`agents.metadata.external.adapters[${index}].enabled must be a boolean`)
  }

  return { name, adapter, enabled, groupMessageMode }
}

function requiredChannelName(value: JsonValue | undefined, field: string): string {
  if (typeof value !== 'string') throw new AgentChatMetadataError(`${field} must be a string`)

  const normalized = value.trim()
  if (!channelNamePattern.test(normalized)) {
    throw new AgentChatMetadataError(`${field} must match ${channelNamePattern}`)
  }

  return normalized
}

function optionalGroupMessageMode(value: JsonValue | undefined, field: string): GroupMessageMode | undefined {
  if (value === undefined) return undefined
  if (typeof value === 'string' && groupMessageModes.has(value)) return value as GroupMessageMode

  throw new AgentChatMetadataError(`${field} must be addressed_only, observe_all, or may_intervene`)
}

/**
 * Treats non-object JSON values as absent rather than invalid. Callers decide
 * whether absence is allowed for their specific field.
 */
function jsonObject(value: JsonValue | undefined): JsonObject | undefined {
  return isPlainObject(value) ? (value as JsonObject) : undefined
}
