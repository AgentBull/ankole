import { type Adapter, Chat } from './core'
import type { BullXChatGatewayExternalIdentitySink } from '@agentbull/bullx-sdk/plugins'
import { singleton } from '@/common/di'
import { logger } from '@/common/logger'
import { type AppConfigJsonValue, appConfigService } from '@/config/app-configure'
import { type AgentResult, listActiveAgents } from '@/principals/agents/service'
import { upsertPlatformSubjectHuman } from '@/principals/external-identities/service'
import { normalizeUid } from '@/principals/principals/service'
import { type ChatGatewayAdapterFactory, resolveChatGatewayAdapterFactory } from './adapter-registry'
import { agentChannelConfigKey } from './config'
import { registerEchoPlaceholderHandlers } from './echo-handler'
import { type AgentChannelBinding, parseAgentChannelBindings } from './metadata'
import { chatGatewayProjectionSink, type ChatGatewayProjectionSink } from './core/projection'

type AgentChat = Chat<Record<string, Adapter>>
type WebhookHandler = (
  request: Request,
  options?: { runInBackground?: (task: Promise<unknown>) => void }
) => Promise<Response>

/**
 * Host implementation of the Principal bridge exposed to chat adapters.
 *
 * Keeping this object in Chat Gateway runtime, rather than inside the Lark
 * plugin, preserves the boundary: plugins emit platform subject facts and the
 * app decides how those facts become Principals and external identity rows.
 */
const chatGatewayExternalIdentitySink = {
  upsertPlatformSubject: async input => {
    const { principal, identity } = await upsertPlatformSubjectHuman({
      provider: input.provider,
      externalId: input.externalId,
      displayName: input.displayName,
      avatarUrl: input.avatarUrl,
      email: input.email,
      phone: input.phone,
      verifiedAt: input.verifiedAt,
      metadata: input.metadata
    })

    return {
      principalUid: principal.uid,
      externalIdentityId: identity.id
    }
  }
} satisfies BullXChatGatewayExternalIdentitySink

/**
 * In-memory runtime handle for one active agent's Chat SDK instance.
 *
 * V1 keeps this process-local. Rebuilding instances on process start is cheap
 * because the durable Chat SDK state lives in PostgreSQL under the agent's
 * `keyPrefix`.
 */
interface AgentChatRuntimeInstance {
  agent: AgentResult
  bindings: AgentChannelBinding[]
  chat: AgentChat
}

/**
 * Startup summary reported in the main service log after Chat Gateway is ready.
 */
export interface ChatGatewayRuntimeStats {
  readyAgents: number
  readyChannels: number
}

/**
 * Optional dependency overrides used by tests or future host runtimes.
 *
 * Production startup uses the database-backed active-agent loader, dynamic
 * app-config service, and DI adapter factory registry by default.
 */
export interface ChatGatewayRuntimeStartOptions {
  getChannelConfig?: (key: string) => Promise<AppConfigJsonValue | undefined>
  loadActiveAgents?: () => Promise<AgentResult[]>
  projection?: ChatGatewayProjectionSink
  resolveAdapterFactory?: (id: string) => ChatGatewayAdapterFactory
}

/**
 * Base runtime error reserved for Chat Gateway lifecycle failures.
 */
export class ChatGatewayRuntimeError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'ChatGatewayRuntimeError'
  }
}

/**
 * Owns all Chat SDK instances for active local agents.
 *
 * The runtime is deliberately simpler than the Elixir gateway: there is no CEL
 * routing or MailBox handoff in V1. The ingress routing rule is
 * `agent uid + channel name -> that agent's Chat SDK webhook handler`; inside
 * the Chat instance, addressed messages get the temporary echo path while
 * ambient group messages are only projected as latest-state context.
 */
@singleton()
export class ChatGatewayRuntime {
  private readonly instances = new Map<string, AgentChatRuntimeInstance>()
  private started = false
  private startPromise: Promise<ChatGatewayRuntimeStats> | null = null

  /**
   * Loads active agents, builds one Chat SDK instance per agent with enabled
   * chat channels, and explicitly initializes all adapters before the HTTP
   * server is allowed to listen.
   */
  async start(options: ChatGatewayRuntimeStartOptions = {}): Promise<ChatGatewayRuntimeStats> {
    if (this.started) return this.stats()

    if (!this.startPromise) this.startPromise = this.doStart(options)

    return this.startPromise
  }

  /**
   * Shuts down every initialized Chat SDK instance.
   */
  async stop(): Promise<void> {
    const instances = [...this.instances.values()]
    this.instances.clear()
    this.started = false
    this.startPromise = null

    const results = await Promise.allSettled(instances.map(instance => instance.chat.shutdown()))
    for (const result of results) {
      if (result.status === 'rejected') {
        logger.error({ error: result.reason }, 'Failed to stop Chat Gateway chat instance')
      }
    }
  }

  /**
   * Handles the public external chat webhook route.
   *
   * Returning 404 for unknown/not-ready agents and unknown channels keeps the
   * surface indistinguishable from "no such webhook exists"; platform-specific
   * auth and payload validation remain adapter responsibilities.
   */
  async handleWebhook(agentUid: string, channel: string, request: Request): Promise<Response> {
    if (!this.started) return new Response('Chat Gateway runtime is not ready', { status: 404 })

    let normalizedAgentUid: string
    try {
      normalizedAgentUid = normalizeUid(agentUid)
    } catch {
      return new Response(`Unknown agent: ${agentUid}`, { status: 404 })
    }

    const instance = this.instances.get(normalizedAgentUid)
    if (!instance) return new Response(`Unknown agent: ${agentUid}`, { status: 404 })

    const handler = (instance.chat.webhooks as Record<string, WebhookHandler>)[channel]
    if (!handler) return new Response(`Unknown channel: ${channel}`, { status: 404 })

    return handler(request, {
      runInBackground: task => {
        // Keep webhook responses fast while still surfacing async failures in
        // the service log. Durable projection runs inside those background tasks.
        task.catch(error => {
          logger.error({ error, agentUid: normalizedAgentUid, channel }, 'Chat Gateway webhook background task failed')
        })
      }
    })
  }

  /**
   * Returns the currently installed in-memory runtime shape.
   */
  stats(): ChatGatewayRuntimeStats {
    let readyChannels = 0
    for (const instance of this.instances.values()) readyChannels += instance.bindings.length

    return {
      readyAgents: this.instances.size,
      readyChannels
    }
  }

  private async doStart(options: ChatGatewayRuntimeStartOptions): Promise<ChatGatewayRuntimeStats> {
    const loadActiveAgents = options.loadActiveAgents ?? listActiveAgents
    const agents = await loadActiveAgents()
    const instances = new Map<string, AgentChatRuntimeInstance>()

    try {
      // Build into a temporary map so a partial startup never replaces a
      // previously ready runtime. Any error below is a service startup failure.
      for (const agent of agents) {
        const instance = await this.buildAgentChatInstance(agent, options)
        if (instance) instances.set(agent.agent.uid, instance)
      }

      this.instances.clear()
      for (const [agentUid, instance] of instances) this.instances.set(agentUid, instance)

      this.started = true
      const stats = this.stats()
      logger.info(stats, 'Chat Gateway runtime started')
      return stats
    } catch (error) {
      await this.shutdownInstances([...instances.values()])
      this.startPromise = null
      throw error
    }
  }

  private async buildAgentChatInstance(
    agent: AgentResult,
    options: ChatGatewayRuntimeStartOptions
  ): Promise<AgentChatRuntimeInstance | undefined> {
    const bindings = parseAgentChannelBindings(agent.agent.metadata)
    // Active agents without chat channel metadata are still valid agents; they
    // simply do not participate in Chat Gateway V1.
    if (bindings.length === 0) {
      return undefined
    }

    const resolveFactory = options.resolveAdapterFactory ?? resolveChatGatewayAdapterFactory
    const getChannelConfig = options.getChannelConfig ?? appConfigService.getByKey.bind(appConfigService)
    const projection = options.projection ?? chatGatewayProjectionSink
    const adapters: Record<string, Adapter> = {}
    for (const binding of bindings) {
      const factory = resolveFactory(binding.adapter)
      const adapter = await factory.create({
        agent,
        channel: binding,
        config: await getChannelConfig(agentChannelConfigKey(agent.agent.uid, binding.name)),
        externalIdentities: chatGatewayExternalIdentitySink
      })
      adapters[binding.name] = adapter
    }

    const chat = new Chat({
      userName: agent.principal.displayName ?? agent.agent.uid,
      adapters,
      // Chat Gateway state keys such as subscriptions, locks, and queues are
      // process-agnostic. Prefixing by agent prevents two agents using the same
      // channel thread id from sharing subscription or queue state.
      stateKeyPrefix: `bullx-agent:${agent.agent.uid}`,
      // Queue preserves all inbound messages per thread while a previous
      // handler is still running. That is the least surprising default for an
      // agent boundary; dropping messages would make debugging webhook ingress
      // much harder.
      concurrency: 'queue',
      logger: 'info'
    })

    registerEchoPlaceholderHandlers(chat, agent, projection)
    await chat.initialize()

    logger.debug(
      {
        agentUid: agent.agent.uid,
        channels: bindings.map(binding => binding.name)
      },
      'Chat Gateway agent chat instance ready'
    )

    return {
      agent,
      bindings,
      chat
    }
  }

  private async shutdownInstances(instances: AgentChatRuntimeInstance[]): Promise<void> {
    const results = await Promise.allSettled(instances.map(instance => instance.chat.shutdown()))
    for (const result of results) {
      if (result.status === 'rejected') {
        logger.error({ error: result.reason }, 'Failed to roll back Chat Gateway startup')
      }
    }
  }
}
