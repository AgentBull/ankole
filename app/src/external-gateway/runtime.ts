import type { BullXExternalGatewayExternalIdentitySink } from '@agentbull/bullx-sdk/plugins'
import { get, isNonEmptyString, isString } from '@pleisto/active-support'
import { aiAgentRuntime } from '@/ai-agent/runtime'
import { singleton } from '@/common/di'
import type { Runtime } from '@/common/lifecycle'
import { logger } from '@/common/logger'
import { type AppConfigJsonValue, appConfigService } from '@/config/app-configure'
import { type AgentResult, listActiveAgents } from '@/principals/agents/service'
import { upsertPlatformSubjectHuman } from '@/principals/external-identities/service'
import { normalizeUid } from '@/principals/principals/service'
import { type ExternalGatewayAdapterFactory, resolveExternalGatewayAdapterFactory } from './adapter-registry'
import type { ExternalGatewayAgentExecutor } from './agent'
import {
  externalGatewayAgentEventQueue,
  type DrizzleExternalGatewayAgentEventQueue,
  type ExternalGatewayAgentDelivery
} from './agent-events'
import { agentChannelConfigKey } from './config'
import { createExternalGatewayAdapterContext, type RuntimeExternalBinding } from './handlers'
import { type AgentExternalBinding, type GroupMessageMode, parseAgentExternalBindings } from './metadata'
import { externalGatewayOutbox, type DrizzleExternalGatewayOutbox } from './outbox'
import { externalGatewayProjectionSink, type ExternalGatewayProjectionSink } from './core/projection'
import type { ExternalGatewayAdapter } from './core/events'

/**
 * Host implementation of the Principal bridge exposed to chat adapters.
 *
 * Keeping this object in External Gateway runtime, rather than inside the Lark
 * plugin, preserves the boundary: plugins emit platform subject facts and the
 * app decides how those facts become Principals and external identity rows.
 */
const externalGatewayExternalIdentitySink = {
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
} satisfies BullXExternalGatewayExternalIdentitySink

/**
 * In-memory runtime handle for one active agent's External Gateway bindings.
 *
 * The handle is process-local. Durable input delivery state lives in
 * `external_gateway_agent_events`; adapters only need to reconnect and resume
 * provider ingress on process start.
 */
interface AgentChatRuntimeInstance {
  agent: AgentResult
  adapters: Record<string, ExternalGatewayAdapter>
  bindings: RuntimeExternalBinding[]
}

/**
 * Startup summary reported in the main service log after External Gateway is ready.
 */
export interface ExternalGatewayRuntimeStats {
  readyAgents: number
  readyChannels: number
}

/**
 * Optional dependency overrides used by tests or future host runtimes.
 *
 * Production startup uses the database-backed active-agent loader, dynamic
 * app-config service, and DI adapter factory registry by default.
 */
export interface ExternalGatewayRuntimeStartOptions {
  agentExecutor?: ExternalGatewayAgentExecutor
  eventQueue?: DrizzleExternalGatewayAgentEventQueue
  getChannelConfig?: (key: string) => Promise<AppConfigJsonValue | undefined>
  loadActiveAgents?: () => Promise<AgentResult[]>
  outbox?: DrizzleExternalGatewayOutbox
  projection?: ExternalGatewayProjectionSink
  resolveAdapterFactory?: (id: string) => ExternalGatewayAdapterFactory
}

/**
 * Base runtime error reserved for External Gateway lifecycle failures.
 */
export class ExternalGatewayRuntimeError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'ExternalGatewayRuntimeError'
  }
}

/**
 * Owns all External Gateway adapter instances for active local agents.
 *
 * Ingress routing is direct: `agent uid + channel name -> that agent's adapter
 * context`. The context emits normalized events into projection and the agent
 * input window.
 */
@singleton()
export class ExternalGatewayRuntime implements Runtime<ExternalGatewayRuntimeStats> {
  private readonly instances = new Map<string, AgentChatRuntimeInstance>()
  private agentExecutor: ExternalGatewayAgentExecutor = aiAgentRuntime
  private drainingAgentEvents = false
  private eventQueue: DrizzleExternalGatewayAgentEventQueue = externalGatewayAgentEventQueue
  private outbox: DrizzleExternalGatewayOutbox = externalGatewayOutbox
  private projection: ExternalGatewayProjectionSink = externalGatewayProjectionSink
  private readonly drainTimers = new Set<ReturnType<typeof setTimeout>>()
  private drainPromise: Promise<void> | null = null
  private started = false
  private startPromise: Promise<ExternalGatewayRuntimeStats> | null = null

  /**
   * Loads active agents, builds enabled channel adapters, and explicitly
   * initializes every adapter before the HTTP server is allowed to listen.
   */
  async start(options: ExternalGatewayRuntimeStartOptions = {}): Promise<ExternalGatewayRuntimeStats> {
    if (this.started) return this.stats()

    if (!this.startPromise) this.startPromise = this.doStart(options)

    return this.startPromise
  }

  /**
   * Shuts down every initialized adapter instance.
   */
  async stop(): Promise<void> {
    this.started = false
    this.startPromise = null

    for (const timer of this.drainTimers) clearTimeout(timer)
    this.drainTimers.clear()

    if (this.drainPromise) {
      await this.drainPromise.catch(error => {
        logger.error({ error }, 'Failed to finish External Gateway agent event drain before shutdown')
      })
    }

    await this.agentExecutor.stop?.()

    const instances = [...this.instances.values()]
    this.instances.clear()
    const results = await Promise.allSettled(
      instances.flatMap(instance => Object.values(instance.adapters).map(adapter => adapter.disconnect?.()))
    )
    for (const result of results) {
      if (result.status === 'rejected') {
        logger.error({ error: result.reason }, 'Failed to stop External Gateway chat instance')
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
    if (!this.started) return new Response('External Gateway runtime is not ready', { status: 404 })

    let normalizedAgentUid: string
    try {
      normalizedAgentUid = normalizeUid(agentUid)
    } catch {
      return new Response(`Unknown agent: ${agentUid}`, { status: 404 })
    }

    const instance = this.instances.get(normalizedAgentUid)
    if (!instance) return new Response(`Unknown agent: ${agentUid}`, { status: 404 })

    const adapter = instance.adapters[channel]
    if (!adapter) return new Response(`Unknown channel: ${channel}`, { status: 404 })

    return adapter.handleWebhook(request)
  }

  /**
   * Returns the currently installed in-memory runtime shape.
   */
  stats(): ExternalGatewayRuntimeStats {
    let readyChannels = 0
    for (const instance of this.instances.values()) readyChannels += instance.bindings.length

    return {
      readyAgents: this.instances.size,
      readyChannels
    }
  }

  private async doStart(options: ExternalGatewayRuntimeStartOptions): Promise<ExternalGatewayRuntimeStats> {
    const loadActiveAgents = options.loadActiveAgents ?? listActiveAgents
    const agents = await loadActiveAgents()
    const instances = new Map<string, AgentChatRuntimeInstance>()
    this.agentExecutor = options.agentExecutor ?? aiAgentRuntime
    this.eventQueue = options.eventQueue ?? externalGatewayAgentEventQueue
    this.outbox = options.outbox ?? externalGatewayOutbox
    this.projection = options.projection ?? externalGatewayProjectionSink

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
      this.scheduleAgentEventDrain()
      for (const [agentUid, instance] of this.instances) {
        for (const binding of instance.bindings) {
          this.scheduleOutboxDrain(agentUid, binding.name)
          await this.recoverAgentBinding(instance, binding.name)
        }
      }
      logger.info(stats, 'External Gateway runtime started')
      return stats
    } catch (error) {
      await this.shutdownInstances([...instances.values()])
      this.startPromise = null
      throw error
    }
  }

  private async buildAgentChatInstance(
    agent: AgentResult,
    options: ExternalGatewayRuntimeStartOptions
  ): Promise<AgentChatRuntimeInstance | undefined> {
    const configuredBindings = parseAgentExternalBindings(agent.agent.metadata)
    // Active agents without external binding metadata are still valid agents; they
    // simply do not participate in External Gateway V1.
    if (configuredBindings.length === 0) {
      return undefined
    }

    const resolveFactory = options.resolveAdapterFactory ?? resolveExternalGatewayAdapterFactory
    const getChannelConfig = options.getChannelConfig ?? appConfigService.getByKey.bind(appConfigService)
    const projection = this.projection
    const adapters: Record<string, ExternalGatewayAdapter> = {}
    const bindings: RuntimeExternalBinding[] = []
    for (const binding of configuredBindings) {
      const factory = resolveFactory(binding.adapter)
      const config = await getChannelConfig(agentChannelConfigKey(agent.agent.uid, binding.name))
      const runtimeBinding = {
        ...binding,
        groupMessageMode: resolveGroupMessageMode(binding, config)
      }
      const adapter = await factory.create({
        agent,
        channel: runtimeBinding,
        config,
        externalIdentities: externalGatewayExternalIdentitySink
      })
      adapters[runtimeBinding.name] = adapter
      bindings.push(runtimeBinding)
      await adapter.initialize?.(
        createExternalGatewayAdapterContext({
          adapter,
          agent,
          binding: runtimeBinding,
          eventQueue: this.eventQueue,
          projection,
          scheduleDrain: availableAt => this.scheduleAgentEventDrain(availableAt),
          roomHasPendingClarify: roomId => this.agentExecutor.roomHasPendingClarify?.(roomId) ?? false
        })
      )
    }

    logger.debug(
      {
        agentUid: agent.agent.uid,
        channels: bindings.map(binding => binding.name)
      },
      'External Gateway agent chat instance ready'
    )

    return {
      adapters,
      agent,
      bindings
    }
  }

  private scheduleAgentEventDrain(availableAt?: Date): void {
    const delayMs = Math.max(0, (availableAt?.getTime() ?? Date.now()) - Date.now())
    const timer = setTimeout(() => {
      this.drainTimers.delete(timer)
      this.runAgentEventDrain().catch(error => {
        logger.error({ error }, 'External Gateway agent event drain failed')
      })
    }, delayMs)
    this.drainTimers.add(timer)
  }

  private async runAgentEventDrain(): Promise<void> {
    if (this.drainPromise) return this.drainPromise

    this.drainPromise = this.drainAgentEvents().finally(() => {
      this.drainPromise = null
    })
    return this.drainPromise
  }

  private async drainAgentEvents(): Promise<void> {
    if (this.drainingAgentEvents) return
    this.drainingAgentEvents = true

    try {
      while (this.started) {
        const delivery = await this.eventQueue.claimReady({
          agentUids: [...this.instances.keys()]
        })
        if (!delivery) {
          const nextAvailableAt = await this.eventQueue.nextPendingAvailableAt({
            agentUids: [...this.instances.keys()]
          })
          if (nextAvailableAt) this.scheduleAgentEventDrain(nextAvailableAt)
          return
        }

        try {
          await this.deliverAgentEvents(delivery)
          await this.eventQueue.markDone(delivery.events)
          const first = delivery.events[0]
          if (first) this.scheduleOutboxDrain(first.agentUid, first.bindingName)
        } catch (error) {
          await this.eventQueue.markFailed(delivery.events, error)
          logger.error(
            { error, events: delivery.events.map(event => event.providerEventId) },
            'External Gateway agent delivery failed'
          )
        }
      }
    } finally {
      this.drainingAgentEvents = false
    }
  }

  private async deliverAgentEvents(delivery: ExternalGatewayAgentDelivery): Promise<void> {
    const first = delivery.events[0]
    if (!first) return

    const instance = this.instances.get(first.agentUid)
    if (!instance) {
      throw new ExternalGatewayRuntimeError(`Agent is not ready for External Gateway event: ${first.agentUid}`)
    }

    const adapter = instance.adapters[first.bindingName]
    if (!adapter) {
      throw new ExternalGatewayRuntimeError(`Binding is not ready for External Gateway event: ${first.bindingName}`)
    }

    await this.agentExecutor.acceptExternalGatewayDelivery(delivery, {
      adapter,
      agent: instance.agent,
      agentUid: first.agentUid,
      bindingName: first.bindingName,
      outbox: this.outbox,
      projection: this.projection,
      providerRealmId: providerRealmIdFromPayload(first.payload),
      scheduleOutboxDrain: availableAt => this.scheduleOutboxDrain(first.agentUid, first.bindingName, availableAt)
    })
  }

  private async recoverAgentBinding(instance: AgentChatRuntimeInstance, bindingName: string): Promise<void> {
    const adapter = instance.adapters[bindingName]
    if (!adapter || !this.agentExecutor.recoverExternalGatewayBinding) return

    await this.agentExecutor.recoverExternalGatewayBinding({
      adapter,
      agent: instance.agent,
      agentUid: instance.agent.agent.uid,
      bindingName,
      outbox: this.outbox,
      projection: this.projection,
      scheduleOutboxDrain: availableAt => this.scheduleOutboxDrain(instance.agent.agent.uid, bindingName, availableAt)
    })
  }

  private scheduleOutboxDrain(agentUid: string, bindingName: string, availableAt?: Date): void {
    const delayMs = Math.max(0, (availableAt?.getTime() ?? Date.now()) - Date.now())
    const timer = setTimeout(() => {
      this.drainTimers.delete(timer)
      this.runOutboxDrain(agentUid, bindingName).catch(error => {
        logger.error({ error, agentUid, bindingName }, 'External Gateway outbox drain failed')
      })
    }, delayMs)
    this.drainTimers.add(timer)
  }

  private async runOutboxDrain(agentUid: string, bindingName: string): Promise<void> {
    const instance = this.instances.get(agentUid)
    if (!instance) return
    const adapter = instance.adapters[bindingName]
    if (!adapter) return
    await this.outbox.dispatchPendingForBinding({
      adapter,
      agent: instance.agent,
      bindingName,
      projection: this.projection,
      room: {}
    })
  }

  private async shutdownInstances(instances: AgentChatRuntimeInstance[]): Promise<void> {
    const results = await Promise.allSettled(
      instances.flatMap(instance => Object.values(instance.adapters).map(adapter => adapter.disconnect?.()))
    )
    for (const result of results) {
      if (result.status === 'rejected') {
        logger.error({ error: result.reason }, 'Failed to roll back External Gateway startup')
      }
    }
  }
}

const groupMessageModes = new Set<GroupMessageMode>(['addressed_only', 'observe_all', 'may_intervene'])

function resolveGroupMessageMode(
  binding: AgentExternalBinding,
  config: AppConfigJsonValue | undefined
): GroupMessageMode {
  if (binding.groupMessageMode) return binding.groupMessageMode

  const configured = groupMessageModeFromConfig(config)
  if (configured) return configured

  return 'observe_all'
}

function groupMessageModeFromConfig(config: AppConfigJsonValue | undefined): GroupMessageMode | undefined {
  const mode = get(config, 'group_message_mode') ?? get(config, 'groupMessageMode')
  return isString(mode) && groupMessageModes.has(mode as GroupMessageMode) ? (mode as GroupMessageMode) : undefined
}

function providerRealmIdFromPayload(payload: unknown): string | undefined {
  const realm = get(payload, 'data.room.metadata.providerRealmId') ?? get(payload, 'data.room.metadata.tenantKey')
  return isNonEmptyString(realm) ? realm : undefined
}
