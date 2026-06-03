import type { JsonObject, JsonValue } from '@/common/db-schema'

const channelNamePattern = /^[a-z][a-z0-9_]*$/

/**
 * One enabled `agents.metadata.chat.adapters[]` entry after validation.
 *
 * `name` is intentionally separate from `adapter`: `name` is the public channel
 * key used in `/api/agents/:agentUid/webhooks/:channel` and in
 * `chat.webhooks[name]`, while `adapter` is the DI-registered factory id that
 * creates the Chat SDK adapter for that channel.
 */
export interface AgentChannelBinding {
  adapter: string
  enabled: boolean
  name: string
}

/**
 * Raised when agent metadata does not describe Chat SDK channels in the shape
 * Chat Gateway V1 understands. Startup fails on this instead of silently skipping
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
 * Extracts the V1 channel list from `agents.metadata`.
 *
 * Supported metadata shape:
 *
 * ```json
 * {
 *   "chat": {
 *     "adapters": [
 *       { "name": "slack", "adapter": "slack", "enabled": true }
 *     ]
 *   }
 * }
 * ```
 *
 * Missing `chat` or `chat.adapters` means "this active agent has no Chat Gateway
 * channels yet" and is not an error. Malformed configured channels are errors
 * because they represent an explicit but impossible runtime request.
 */
export function parseAgentChannelBindings(metadata: JsonObject): AgentChannelBinding[] {
  const chat = jsonObject(metadata.chat)
  if (!chat) return []

  const adapters = chat.adapters
  if (adapters === undefined) return []

  if (!Array.isArray(adapters)) throw new AgentChatMetadataError('agents.metadata.chat.adapters must be an array')

  const bindings = adapters.map(parseBinding).filter(binding => binding.enabled)
  const seen = new Set<string>()

  for (const binding of bindings) {
    if (seen.has(binding.name)) {
      throw new AgentChatMetadataError(`duplicate enabled Chat Gateway channel name: ${binding.name}`)
    }

    seen.add(binding.name)
  }

  return bindings
}

function parseBinding(value: JsonValue, index: number): AgentChannelBinding {
  const input = jsonObject(value)
  if (!input) throw new AgentChatMetadataError(`agents.metadata.chat.adapters[${index}] must be an object`)

  const name = requiredChannelName(input.name, `agents.metadata.chat.adapters[${index}].name`)
  const adapter = requiredChannelName(input.adapter, `agents.metadata.chat.adapters[${index}].adapter`)
  const enabled = input.enabled === undefined ? true : input.enabled

  if (typeof enabled !== 'boolean') {
    throw new AgentChatMetadataError(`agents.metadata.chat.adapters[${index}].enabled must be a boolean`)
  }

  return { name, adapter, enabled }
}

function requiredChannelName(value: JsonValue | undefined, field: string): string {
  if (typeof value !== 'string') throw new AgentChatMetadataError(`${field} must be a string`)

  const normalized = value.trim()
  if (!channelNamePattern.test(normalized)) {
    throw new AgentChatMetadataError(`${field} must match ${channelNamePattern}`)
  }

  return normalized
}

/**
 * Treats non-object JSON values as absent rather than invalid. Callers decide
 * whether absence is allowed for their specific field.
 */
function jsonObject(value: JsonValue | undefined): JsonObject | undefined {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined

  return value
}
