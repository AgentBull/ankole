import type { BullXExternalGatewayExternalIdentitySink } from '@agentbull/bullx-sdk/plugins'
import { get, isNonEmptyString, isString } from '@pleisto/active-support'
import { aiAgentRuntime } from '@/ai-agent/runtime'
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
  type ExternalGatewayAgentDelivery,
  type ExternalGatewayAgentEventKey
} from './agent-events'
import { loadAiAgentParallelismConfig } from '@/ai-agent/config'
import { agentChannelConfigKey } from './config'
import { createExternalGatewayAdapterContext, type RuntimeExternalBinding } from './handlers'
import type { ExternalMediaComputerWriter } from './media-cache'
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
  getComputerFileWriter?: (agentUid: string, signal?: AbortSignal) => Promise<ExternalMediaComputerWriter>
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
export class ExternalGatewayRuntime implements Runtime<ExternalGatewayRuntimeStats> {
  private readonly instances = new Map<string, AgentChatRuntimeInstance>()
  private agentExecutor: ExternalGatewayAgentExecutor = aiAgentRuntime
  private drainingAgentEvents = false
  private drainRequested = false
  private eventQueue: DrizzleExternalGatewayAgentEventQueue = externalGatewayAgentEventQueue
  private outbox: DrizzleExternalGatewayOutbox = externalGatewayOutbox
  private projection: ExternalGatewayProjectionSink = externalGatewayProjectionSink
  private readonly drainTimers = new Set<ReturnType<typeof setTimeout>>()
  private drainPromise: Promise<void> | null = null
  /**
   * Process-local in-flight deliveries. Rows stay `pending` until
   * markDone/markFailed, so claiming excludes the in-flight event keys (not
   * whole rooms: same-room follow-up and steering input must keep flowing to
   * the executor while a generation runs). The per-agent parallelism quota
   * counts these deliveries; queued-only deliveries (follow-up appends) settle
   * in milliseconds and barely occupy a slot. Conversation-level safety stays
   * with the `ai_agent_conversations.generation` lease.
   */
  private readonly inFlightDeliveries = new Map<
    number,
    { agentUid: string; events: ExternalGatewayAgentEventKey[]; run: Promise<void> }
  >()
  private nextDeliveryId = 0
  private readonly outboxDrains = new Map<string, { requested: boolean; promise: Promise<void> }>()
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

    // Wait for every in-flight delivery: rows stay pending until they settle.
    await Promise.allSettled([...this.inFlightDeliveries.values()].map(delivery => delivery.run))

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

  triggerOutboxDrain(agentUid: string, bindingName: string, availableAt?: Date): void {
    this.scheduleOutboxDrain(agentUid, bindingName, availableAt)
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
          getComputerFileWriter: options.getComputerFileWriter,
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
    // A drain pass claims without awaiting deliveries, so it can finish in the
    // gap between an event insert and its schedule callback. Re-run requests
    // that arrive mid-pass instead of dropping the wakeup.
    if (this.drainPromise) {
      this.drainRequested = true
      return this.drainPromise
    }

    this.drainPromise = (async () => {
      do {
        this.drainRequested = false
        await this.drainAgentEvents()
      } while (this.drainRequested && this.started)
    })().finally(() => {
      this.drainPromise = null
    })
    return this.drainPromise
  }

  /**
   * Lane-scheduling claim loop. Each pass claims ready work for agents below
   * their conversation-parallelism quota, excluding rows already claimed by an
   * in-flight delivery, and starts the delivery WITHOUT awaiting it — lanes of
   * the same agent (and different agents) run concurrently. A settled delivery
   * re-arms the drain so freed quota and unblocked rows are re-scanned.
   */
  private async drainAgentEvents(): Promise<void> {
    if (this.drainingAgentEvents) return
    this.drainingAgentEvents = true

    try {
      const { maxConversationsPerAgent } = await loadAiAgentParallelismConfig()
      while (this.started) {
        const laneCounts = new Map<string, number>()
        for (const delivery of this.inFlightDeliveries.values()) {
          laneCounts.set(delivery.agentUid, (laneCounts.get(delivery.agentUid) ?? 0) + 1)
        }
        const eligibleAgents = [...this.instances.keys()].filter(
          agentUid => (laneCounts.get(agentUid) ?? 0) < maxConversationsPerAgent
        )
        const excludeEvents = [...this.inFlightDeliveries.values()].flatMap(delivery => delivery.events)

        if (eligibleAgents.length === 0) return
        const delivery = await this.eventQueue.claimReady({ agentUids: eligibleAgents, excludeEvents })
        if (!delivery) {
          const nextAvailableAt = await this.eventQueue.nextPendingAvailableAt({
            agentUids: eligibleAgents,
            excludeEvents
          })
          if (nextAvailableAt) this.scheduleAgentEventDrain(nextAvailableAt)
          return
        }

        const first = delivery.events[0]
        if (!first) continue
        const deliveryId = this.nextDeliveryId++
        const events = delivery.events.map(event => ({
          agentUid: event.agentUid,
          bindingName: event.bindingName,
          providerEventId: event.providerEventId
        }))
        const run = this.deliverLane(delivery).finally(() => {
          this.inFlightDeliveries.delete(deliveryId)
          // Freed quota / settled rows: re-scan promptly for queued work.
          if (this.started) this.scheduleAgentEventDrain()
        })
        this.inFlightDeliveries.set(deliveryId, { agentUid: first.agentUid, events, run })
      }
    } finally {
      this.drainingAgentEvents = false
    }
  }

  /** Runs one claimed delivery to completion and settles its input rows. */
  private async deliverLane(delivery: ExternalGatewayAgentDelivery): Promise<void> {
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

    const settledWork: Promise<void>[] = []
    const acceptance = await this.agentExecutor.acceptExternalGatewayDelivery(delivery, {
      adapter,
      agent: instance.agent,
      agentUid: first.agentUid,
      bindingName: first.bindingName,
      outbox: this.outbox,
      projection: this.projection,
      providerRealmId: providerRealmIdFromPayload(first.payload),
      scheduleOutboxDrain: availableAt => this.scheduleOutboxDrain(first.agentUid, first.bindingName, availableAt),
      trackSettled: settled => settledWork.push(settled)
    })
    // Hold the lane (and the per-agent quota slot) until the started work
    // settles. Work started after acceptance (delayed media-batch triggers)
    // is not awaited — those lanes free early by design.
    if (acceptance.settled) await acceptance.settled
    await Promise.all(settledWork)
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

  /**
   * One outbox drain per (agent, binding) at a time. Concurrent lanes of one
   * agent commit (and trigger drains) simultaneously; without this mutex two
   * overlapping drains would select the same pending rows and double-deliver.
   * Requests that arrive mid-drain re-run the drain instead of overlapping it.
   */
  private async runOutboxDrain(agentUid: string, bindingName: string): Promise<void> {
    const key = `${agentUid}\u0000${bindingName}`
    const existing = this.outboxDrains.get(key)
    if (existing) {
      existing.requested = true
      return existing.promise
    }
    const state = { requested: false, promise: Promise.resolve() }
    state.promise = (async () => {
      do {
        state.requested = false
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
      } while (state.requested && this.started)
    })().finally(() => {
      this.outboxDrains.delete(key)
    })
    this.outboxDrains.set(key, state)
    return state.promise
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

/** Shared External Gateway runtime instance. */
export const externalGatewayRuntime = new ExternalGatewayRuntime()
