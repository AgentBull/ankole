import type { Adapter } from 'chat'
import { rootContainer } from '@/common/di'
import type { AppConfigJsonValue } from '@/config/app-configure'
import type { AgentResult } from '@/principals/agents/service'
import type { AgentChannelBinding } from './metadata'
import type { ChatGatewayProjectionSink } from './projection'

/**
 * Runtime inputs passed to a plugin-provided Chat SDK adapter factory.
 *
 * The factory receives the owning agent, the normalized channel binding, and
 * the encrypted dynamic app config value for `agents.<agent_uid>.<channel>`.
 * Concrete plugins decide their own config schema after the plugin system is
 * wired; Chat Gateway V1 only guarantees this value is JSON-compatible.
 */
export interface ChatGatewayAdapterFactoryContext {
  agent: AgentResult
  channel: AgentChannelBinding
  config: AppConfigJsonValue | undefined
  /**
   * Latest-state projection sink for external channel facts.
   *
   * Factories pass this to concrete adapters so inbound edit/delete/reaction
   * events can update `chat_channels` and `chat_messages` without each plugin
   * needing to know BullX database details.
   */
  projection: ChatGatewayProjectionSink
}

/**
 * Factory registered by adapters/plugins to bridge BullX agents into Chat SDK.
 *
 * The `id` must match `agents.metadata.chat.adapters[].adapter`. The returned
 * object is a normal Chat SDK `Adapter`; Chat Gateway does not wrap external
 * platform behavior except for routing the webhook request to
 * `chat.webhooks[channel]`.
 */
export interface ChatGatewayAdapterFactory {
  id: string
  create(context: ChatGatewayAdapterFactoryContext): Adapter | Promise<Adapter>
}

/**
 * Raised when an enabled channel asks for a factory that no plugin registered.
 *
 * This is a startup failure by design. Skipping the channel would leave the
 * service apparently healthy while external webhooks for that agent return 404.
 */
export class MissingChatGatewayAdapterFactoryError extends Error {
  constructor(id: string) {
    super(`Chat Gateway adapter factory is not registered: ${id}`)
    this.name = 'MissingChatGatewayAdapterFactoryError'
  }
}

/**
 * Raised when two built-in modules or enabled plugins try to own the same
 * Chat Gateway adapter factory id.
 */
export class DuplicateChatGatewayAdapterFactoryError extends Error {
  constructor(id: string) {
    super(`Chat Gateway adapter factory is already registered: ${id}`)
    this.name = 'DuplicateChatGatewayAdapterFactoryError'
  }
}

/**
 * Registers a Chat SDK adapter factory in the root tsyringe container.
 *
 * Keeping this in DI rather than a module-local map is deliberate: future plugin
 * activation will register factories as side effects of plugin loading, and the
 * runtime only needs to resolve by factory id.
 */
export function registerChatGatewayAdapterFactory(factory: ChatGatewayAdapterFactory): void {
  const token = chatGatewayAdapterFactoryToken(factory.id)
  if (rootContainer.isRegistered(token)) throw new DuplicateChatGatewayAdapterFactoryError(factory.id)

  rootContainer.registerInstance(token, factory)
}

/**
 * Resolves an adapter factory by metadata id.
 */
export function resolveChatGatewayAdapterFactory(id: string): ChatGatewayAdapterFactory {
  try {
    return rootContainer.resolve<ChatGatewayAdapterFactory>(chatGatewayAdapterFactoryToken(id))
  } catch (error) {
    throw new MissingChatGatewayAdapterFactoryError(id)
  }
}

/**
 * Stable DI token namespace for Chat Gateway adapter factories.
 */
export function chatGatewayAdapterFactoryToken(id: string): string {
  return `chat-gateway.adapter-factory.${id}`
}
