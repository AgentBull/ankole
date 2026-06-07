import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { isContextOverflow, streamSimple, type AssistantMessage } from '@earendil-works/pi-ai'
import { and, desc, eq, sql } from 'drizzle-orm'
import { DB, jsonbParam } from '@/common/database'
import {
  AiAgentConversations,
  AiAgentMessages,
  ExternalGatewayOutbox,
  type JsonObject,
  type JsonValue
} from '@/common/db-schema'
import { adapterSupportsCapability } from '@/external-gateway/core'
import type {
  ExternalGatewayAgentDelivery,
  ExternalGatewayAgentEnvelope,
  ExternalGatewaySlashCommandStub
} from '@/external-gateway/agent-events'
import type { ExternalGatewayAgentExecutionContext } from '@/external-gateway/agent'
import { commandEditIntent, commandFeedbackIntent } from './commands'
import { loadAiAgentRuntimeProfile, type AiAgentRuntimeProfile } from './config'
import {
  aiAgentConversationService,
  newGenerationLease,
  providerRefs,
  textContent,
  textFromContent,
  type AiAgentConversationRoute,
  type AiAgentConversationService,
  type AiAgentLlmTurnKind,
  type PendingFollowup,
  type PendingSteering
} from './conversation-service'
import { aiAgentContextRenderer, type AiAgentContextRenderer } from './context-renderer'
import { aiAgentDailyResetService, type AiAgentDailyResetService } from './daily-reset'
import { aiAgentAmbientBatcher, type AiAgentAmbientBatcher } from './ambient'
import { aiAgentCompressionService, type AiAgentCompressionService } from './compression'
import { aiAgentLifecycleRevisionService, type AiAgentLifecycleRevisionService } from './lifecycle-revisions'
import { aiAgentRunRegistry, type AiAgentRunRegistry } from './run-registry'
import { aiAgentClarifyRegistry, type AiAgentClarifyRegistry } from './clarify-registry'
import { createClarifyTool, type ClarifyRunBinding } from './tools/clarify-tool'
import { mapAnswer } from './tools/clarify-format'
import {
  Agent,
  convertToLlm,
  createUserMessage,
  estimateContextTokens,
  shouldCompact,
  textFromAgentMessage,
  type AfterToolCallContext,
  type AfterToolCallResult,
  type AgentMessage,
  type AgentTool,
  type BeforeToolCallContext,
  type BeforeToolCallResult
} from './core'
import { stringFromPath as stringFromMetadata, toJsonObject } from '@/common/json'
import { idempotencyKeyFromOutboundKey } from '@/external-gateway/outbox'

export interface AiAgentRuntimeOptions {
  ambient?: AiAgentAmbientBatcher
  compression?: AiAgentCompressionService
  conversations?: AiAgentConversationService
  dailyReset?: AiAgentDailyResetService
  lifecycle?: AiAgentLifecycleRevisionService
  loadProfile?: (agentUid: string) => Promise<AiAgentRuntimeProfile>
  registry?: AiAgentRunRegistry
  renderer?: AiAgentContextRenderer
  clarify?: AiAgentClarifyRegistry
  clarifyTimeoutMs?: number
  clarifyHeartbeatMs?: number
}

export class AiAgentRuntime {
  private readonly ambient: AiAgentAmbientBatcher
  private readonly compression: AiAgentCompressionService
  private readonly conversations: AiAgentConversationService
  private readonly dailyReset: AiAgentDailyResetService
  private readonly lifecycle: AiAgentLifecycleRevisionService
  private readonly loadProfile: (agentUid: string) => Promise<AiAgentRuntimeProfile>
  private readonly registry: AiAgentRunRegistry
  private readonly renderer: AiAgentContextRenderer
  private readonly ambientTimers = new Set<ReturnType<typeof setTimeout>>()
  private readonly tools = new Map<string, AgentTool<any>>()
  private activeToolNames: string[] = []
  private readonly clarify: AiAgentClarifyRegistry
  private readonly clarifyTimeoutMs?: number
  private readonly clarifyHeartbeatMs?: number
  private clarifyFactory?: (binding: ClarifyRunBinding) => AgentTool<any>

  constructor(options: AiAgentRuntimeOptions = {}) {
    this.ambient = options.ambient ?? aiAgentAmbientBatcher
    this.compression = options.compression ?? aiAgentCompressionService
    this.conversations = options.conversations ?? aiAgentConversationService
    this.dailyReset = options.dailyReset ?? aiAgentDailyResetService
    this.lifecycle = options.lifecycle ?? aiAgentLifecycleRevisionService
    this.loadProfile = options.loadProfile ?? loadAiAgentRuntimeProfile
    this.registry = options.registry ?? aiAgentRunRegistry
    this.renderer = options.renderer ?? aiAgentContextRenderer
    this.clarify = options.clarify ?? aiAgentClarifyRegistry
    this.clarifyTimeoutMs = options.clarifyTimeoutMs
    this.clarifyHeartbeatMs = options.clarifyHeartbeatMs
  }

  stop(): void {
    for (const timer of this.ambientTimers) clearTimeout(timer)
    this.ambientTimers.clear()
  }

  /**
   * Tool call policy (ported from AgentHarness tool management). v1 ships no tools, but the registry,
   * active-subset selection, and validation are in place so tools can be wired without reshaping the runtime.
   */
  getTools(): AgentTool<any>[] {
    return [...this.tools.values()]
  }

  setTools(tools: AgentTool<any>[], activeToolNames?: string[]): void {
    validateUniqueNames(
      tools.map(tool => tool.name),
      'Duplicate tool name(s)'
    )
    const next = new Map(tools.map(tool => [tool.name, tool] as const))
    const nextActive = activeToolNames ? [...activeToolNames] : this.activeToolNames.filter(name => next.has(name))
    validateToolNames(nextActive, next)
    this.tools.clear()
    for (const [name, tool] of next) this.tools.set(name, tool)
    this.activeToolNames = nextActive
  }

  getActiveTools(): AgentTool<any>[] {
    return this.activeToolNames.flatMap(name => {
      const tool = this.tools.get(name)
      return tool ? [tool] : []
    })
  }

  setActiveTools(toolNames: string[]): void {
    validateToolNames(toolNames, this.tools)
    this.activeToolNames = [...toolNames]
  }

  /** Enable/disable the run-bound clarify tool. clarify is rebuilt per run with the gateway binding. */
  setClarifyEnabled(enabled: boolean): void {
    this.clarifyFactory = enabled
      ? binding =>
          createClarifyTool(binding, {
            conversations: this.conversations,
            registry: this.clarify,
            timeoutMs: this.clarifyTimeoutMs,
            heartbeatMs: this.clarifyHeartbeatMs
          })
      : undefined
  }

  /** Active run-static tools plus the per-run clarify tool (when enabled and a reply target exists). */
  private buildActiveToolsForRun(binding: ClarifyRunBinding): AgentTool<any>[] {
    const tools = this.getActiveTools()
    if (this.clarifyFactory && binding.providerRoomId) return [...tools, this.clarifyFactory(binding)]
    return tools
  }

  private async transformGenerationContext(messages: AgentMessage[], _signal?: AbortSignal): Promise<AgentMessage[]> {
    // Context transform hook (AgentHarness 'context' event). Extension point for in-run context shaping;
    // v1 passes messages through unchanged because threshold compaction runs as a preflight before the run.
    return messages
  }

  private async beforeToolCall(
    _context: BeforeToolCallContext,
    _signal?: AbortSignal
  ): Promise<BeforeToolCallResult | undefined> {
    // Tool gate extension point (AgentHarness tool_call hook). v1 has no tools wired.
    return undefined
  }

  private async afterToolCall(
    _context: AfterToolCallContext,
    _signal?: AbortSignal
  ): Promise<AfterToolCallResult | undefined> {
    // Tool result patch extension point (AgentHarness tool_result hook). v1 has no tools wired.
    return undefined
  }

  async acceptExternalGatewayDelivery(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentExecutionContext
  ): Promise<{ status: 'accepted' }> {
    const first = delivery.events[0]
    if (!first) return { status: 'accepted' }
    const profile = await this.loadProfile(context.agentUid)
    const route = routeFromContext(context, first.providerRoomId)

    if (first.deliveryMode === 'addressed') {
      await this.acceptAddressed(delivery, context, route, profile)
    } else if (first.deliveryMode === 'ambient') {
      await this.acceptAmbient(delivery, context, route, profile)
    } else if (first.deliveryMode === 'command') {
      await this.acceptCommand(delivery, context, route, profile)
    } else if (first.deliveryMode === 'lifecycle') {
      await this.acceptLifecycle(delivery, context, route)
    }

    return { status: 'accepted' }
  }

  async recoverExternalGatewayBinding(context: ExternalGatewayAgentExecutionContext): Promise<void> {
    const profile = await this.loadProfile(context.agentUid)
    const rebuiltOutboxRows = await this.rebuildMissingAssistantOutbox(context)
    if (rebuiltOutboxRows > 0) context.scheduleOutboxDrain()

    const conversations = await DB.select()
      .from(AiAgentConversations)
      .where(
        and(
          eq(AiAgentConversations.agentUid, context.agentUid),
          sql`${AiAgentConversations.endedAt} is null`,
          sql`${AiAgentConversations.metadata}->'route'->>'binding_name' = ${context.bindingName}`,
          sql`coalesce(${AiAgentConversations.generation}->>'lease_id', '') <> ''`,
          sql`coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') = ''`
        )
      )

    for (const conversation of conversations) {
      const leaseId = conversation.generation.lease_id
      const triggerMessageId = conversation.generation.trigger_message_id
      if (!leaseId || !triggerMessageId) continue

      const [trigger] = await DB.select().from(AiAgentMessages).where(eq(AiAgentMessages.id, triggerMessageId)).limit(1)
      this.startGeneration({
        context,
        conversationId: conversation.id,
        leaseId,
        profile,
        providerRoomId:
          (trigger ? stringFromMetadata(trigger.metadata, ['provider_refs', 'room_id']) : undefined) ??
          stringFromMetadata(conversation.metadata, ['route', 'provider_room_id']) ??
          '',
        providerThreadId: trigger ? stringFromMetadata(trigger.metadata, ['provider_refs', 'thread_id']) : undefined,
        triggerMessageId
      })
    }

    await this.drainAmbientAndStartGeneration(context, profile)
  }

  private async rebuildMissingAssistantOutbox(context: ExternalGatewayAgentExecutionContext): Promise<number> {
    const rows = await DB.select({
      conversationMetadata: AiAgentConversations.metadata,
      content: AiAgentMessages.content,
      metadata: AiAgentMessages.metadata
    })
      .from(AiAgentMessages)
      .innerJoin(AiAgentConversations, eq(AiAgentMessages.conversationId, AiAgentConversations.id))
      .where(
        and(
          eq(AiAgentMessages.agentUid, context.agentUid),
          eq(AiAgentMessages.role, 'assistant'),
          eq(AiAgentMessages.kind, 'normal'),
          sql`${AiAgentConversations.endedAt} is null`,
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`,
          sql`${AiAgentMessages.metadata}->'route'->>'binding_name' = ${context.bindingName}`,
          sql`coalesce(${AiAgentMessages.metadata}->'outbound'->>'outbound_key', '') <> ''`,
          sql`not exists (
            select 1 from ${ExternalGatewayOutbox} ob
            where ob.agent_uid = ${AiAgentMessages.agentUid}
              and ob.binding_name = ${context.bindingName}
              and ob.outbound_key = ${AiAgentMessages.metadata}->'outbound'->>'outbound_key'
          )`
        )
      )

    let rebuilt = 0
    for (const row of rows) {
      const outboundKey = stringFromMetadata(row.metadata, ['outbound', 'outbound_key'])
      const text = textFromContent(row.content).trim()
      if (!outboundKey || !text) continue
      await context.outbox.enqueuePending({
        agentUid: context.agentUid,
        bindingName: context.bindingName,
        intent: {
          operation: 'post',
          outboundKey,
          providerRoomId: stringFromMetadata(row.conversationMetadata, ['route', 'provider_room_id']) ?? '',
          providerThreadId:
            stringFromMetadata(row.metadata, ['route', 'provider_thread_id']) ??
            stringFromMetadata(row.conversationMetadata, ['route', 'provider_room_id']) ??
            '',
          finalPayload: { text }
        }
      })
      rebuilt += 1
    }
    return rebuilt
  }

  private async acceptAddressed(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentExecutionContext,
    route: AiAgentConversationRoute,
    profile: AiAgentRuntimeProfile
  ): Promise<void> {
    const conversation = await this.dailyReset.ensureFreshConversation(route, profile)

    // clarify text-intercept: a parked clarify keeps the generation active, so this must
    // precede the followup path. The next inbound message is the answer — resolve it and
    // let the parked run continue (no pending followup, no new generation).
    if (this.clarify.has(conversation.id)) {
      const lastEvent = delivery.events.at(-1)
      if (lastEvent) {
        const entry = this.clarify.get(conversation.id)
        const mapped = mapAnswer(messageText(payloadEnvelope(lastEvent)), entry?.choices)
        if (
          this.clarify.resolveByConversation(conversation.id, {
            kind: 'answer',
            text: mapped.text,
            choiceIndex: mapped.choiceIndex
          })
        ) {
          return
        }
      }
    }

    if (isActiveGeneration(conversation.generation)) {
      for (const event of delivery.events) {
        await this.conversations.appendPendingFollowup(conversation.id, {
          actor: actorFromEnvelope(payloadEnvelope(event)),
          created_at: new Date().toISOString(),
          event_id: event.providerEventId,
          event_source: payloadEnvelope(event).source,
          provider_refs: providerRefs({
            eventId: event.providerEventId,
            providerMessageId: event.providerMessageId,
            providerRoomId: event.providerRoomId,
            providerThreadId: event.providerThreadId
          }) as unknown as JsonObject,
          text: messageText(payloadEnvelope(event))
        })
      }
      return
    }

    let triggerMessageId: string | undefined
    for (const event of delivery.events) {
      const envelope = payloadEnvelope(event)
      const text = messageText(envelope)
      const userMessage = createUserMessage(text, event.createdAt.getTime())
      const row = await this.conversations.appendMessage({
        conversationId: conversation.id,
        role: 'user',
        kind: 'normal',
        content: textContent(text),
        agentMessage: userMessage,
        eventSource: envelope.source,
        eventId: event.providerEventId,
        metadata: {
          actor: actorFromEnvelope(envelope),
          provider_refs: providerRefs({
            eventId: event.providerEventId,
            providerMessageId: event.providerMessageId,
            providerRoomId: event.providerRoomId,
            providerThreadId: event.providerThreadId
          }) as unknown as JsonObject,
          route: routeMetadata(context, event.providerThreadId)
        }
      })
      triggerMessageId = row.id
    }

    const anchor = delivery.events.at(-1)
    if (triggerMessageId && anchor) {
      this.startGeneration({
        context,
        conversationId: conversation.id,
        profile,
        providerRoomId: anchor.providerRoomId,
        providerThreadId: anchor.providerThreadId,
        triggerMessageId
      })
    }
  }

  private async acceptAmbient(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentExecutionContext,
    route: AiAgentConversationRoute,
    profile: AiAgentRuntimeProfile
  ): Promise<void> {
    const conversation = await this.dailyReset.ensureFreshConversation(route, profile)
    for (const event of delivery.events) {
      const envelope = payloadEnvelope(event)
      await this.conversations.appendMessage({
        conversationId: conversation.id,
        role: 'im_ambient',
        kind: 'normal',
        content: textContent(messageText(envelope)),
        eventSource: envelope.source,
        eventId: event.providerEventId,
        metadata: {
          actor: actorFromEnvelope(envelope),
          provider_refs: providerRefs({
            eventId: event.providerEventId,
            providerMessageId: event.providerMessageId,
            providerRoomId: event.providerRoomId,
            providerThreadId: event.providerThreadId
          }) as unknown as JsonObject
        }
      })
      await this.ambient.schedule({
        agentUid: context.agentUid,
        bindingName: context.bindingName,
        conversationId: conversation.id,
        profile,
        providerRoomId: event.providerRoomId,
        providerThreadId: event.providerThreadId
      })
      this.scheduleAmbientDrain(context, profile, profile.ambient.batchWindowMs + 5)
    }
  }

  private async acceptCommand(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentExecutionContext,
    route: AiAgentConversationRoute,
    profile: AiAgentRuntimeProfile
  ): Promise<void> {
    const event = delivery.events[0]
    if (!event) return
    const envelope = payloadEnvelope(event)
    const command = commandFromEnvelope(envelope)
    if (!command) return
    const conversation = await this.conversations.getOrCreateActiveConversation(route)

    if (command.name === 'new') {
      // abortAndWait drives the parked clarify's signal -> onAbort -> resolve; the
      // explicit abort below is a backstop if the signal chain didn't settle it.
      await this.registry.abortAndWait(conversation.id, 'new_session')
      this.clarify.abort(conversation.id, 'superseded')
      await this.conversations.rolloverConversation(route, 'new_session')
      await this.enqueueFeedback(context, event, 'New conversation started.')
      return
    }

    if (command.name === 'stop') {
      // Fence first, then let abortAndWait's signal settle the parked clarify; the
      // explicit abort below is a backstop (avoids an extra model turn vs aborting clarify early).
      await this.conversations.cancelGeneration(conversation.id, 'stop', event.providerEventId)
      await this.registry.abortAndWait(conversation.id, 'stop')
      this.clarify.abort(conversation.id, 'aborted')
      await this.enqueueFeedback(context, event, 'Stopped.')
      return
    }

    if (command.name === 'steer') {
      const text = command.argsText.trim()
      if (!text) {
        await this.enqueueFeedback(context, event, 'Usage: /steer <instruction>')
        return
      }
      const steering = {
        command_event_id: event.providerEventId,
        created_at: new Date().toISOString(),
        text
      } satisfies PendingSteering
      if (isActiveGeneration(conversation.generation)) {
        await this.conversations.appendPendingSteering(conversation.id, steering)
        await this.enqueueFeedback(context, event, 'No tool boundary to steer; queued as next turn.')
      } else {
        const row = await this.materializeSteering(conversation.id, steering)
        await this.enqueueFeedback(context, event, 'No tool boundary to steer; queued as next turn.')
        this.startGeneration({
          context,
          conversationId: conversation.id,
          profile,
          providerRoomId: event.providerRoomId,
          providerThreadId: event.providerThreadId,
          triggerMessageId: row.id
        })
      }
      return
    }

    if (command.name === 'compress') {
      if (isActiveGeneration(conversation.generation)) {
        await this.enqueueFeedback(context, event, 'A response is still running; stop it before compressing.')
        return
      }
      if (!adapterSupportsCapability(context.adapter, 'outbound', 'edit_message')) {
        await this.enqueueFeedback(
          context,
          event,
          'Compression is unavailable on this channel because message edit is unsupported.'
        )
        return
      }
      const progressKey = `ai-agent-command-feedback:${event.providerEventId}:progress`
      await context.outbox.enqueuePending({
        agentUid: context.agentUid,
        bindingName: context.bindingName,
        intent: commandFeedbackIntent({
          commandEventId: event.providerEventId,
          phase: 'progress',
          providerRoomId: event.providerRoomId,
          providerThreadId: event.providerThreadId,
          text: 'Compressing conversation...'
        })
      })
      let finalText = 'Conversation compressed.'
      try {
        const result = await this.compression.compress({
          conversationId: conversation.id,
          profile,
          trigger: 'manual_command'
        })
        if (!result) finalText = 'Conversation already fits in the active context.'
      } catch (error) {
        finalText = `Compression failed: ${error instanceof Error ? error.message : String(error)}`
      }
      await context.outbox.enqueuePending({
        agentUid: context.agentUid,
        bindingName: context.bindingName,
        intent: commandEditIntent({
          commandEventId: event.providerEventId,
          providerRoomId: event.providerRoomId,
          providerThreadId: event.providerThreadId,
          targetOutboundKey: progressKey,
          text: finalText
        })
      })
      context.scheduleOutboxDrain()
      return
    }

    if (command.name === 'retry') {
      if (isActiveGeneration(conversation.generation)) {
        await this.enqueueFeedback(context, event, 'A response is still running; stop it before retrying.')
        return
      }
      await this.retryLastExchange(conversation.id, context, event, profile)
    }
  }

  private async acceptLifecycle(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentExecutionContext,
    route: AiAgentConversationRoute
  ): Promise<void> {
    const event = delivery.events[0]
    if (!event || (event.type !== 'message.recalled' && event.type !== 'message.deleted') || !event.providerMessageId) {
      return
    }
    const result = await this.lifecycle.handleRecallOrDelete({
      eventId: event.providerEventId,
      eventSource: payloadEnvelope(event).source,
      kind: event.type === 'message.recalled' ? 'recalled' : 'deleted',
      providerMessageId: event.providerMessageId,
      providerRoomId: event.providerRoomId,
      providerThreadId: event.providerThreadId,
      registry: this.registry,
      route
    })
    if (result.deleteIntents.length > 0) {
      await context.outbox.enqueuePendingMany({
        agentUid: context.agentUid,
        bindingName: context.bindingName,
        intents: result.deleteIntents
      })
      context.scheduleOutboxDrain()
    }
  }

  private startGeneration(input: {
    context: ExternalGatewayAgentExecutionContext
    conversationId: string
    leaseId?: string
    llmTurnKind?: AiAgentLlmTurnKind
    overflowAttempts?: number
    profile: AiAgentRuntimeProfile
    providerRoomId?: string
    providerThreadId?: string
    triggerMessageId?: string
  }): void {
    void this.runGeneration(input).catch(error => {
      console.error(error)
    })
  }

  private async runGeneration(input: {
    context: ExternalGatewayAgentExecutionContext
    conversationId: string
    leaseId?: string
    llmTurnKind?: AiAgentLlmTurnKind
    overflowAttempts?: number
    profile: AiAgentRuntimeProfile
    providerRoomId?: string
    providerThreadId?: string
    triggerMessageId?: string
  }): Promise<void> {
    const triggerMessageId = input.triggerMessageId ?? (await this.latestTriggerMessageId(input.conversationId))
    if (!triggerMessageId) return
    const lease = input.leaseId
      ? { leaseId: input.leaseId }
      : await this.conversations.acquireGenerationLease({
          conversationId: input.conversationId,
          triggerMessageId
        })
    if (!lease) return

    let rendered = await this.renderer.render(input.conversationId)
    // shouldCompact preflight (ported from AgentHarness threshold check): if the rebuilt context already
    // exceeds the model window minus the reserve, compress first so we don't burn a doomed provider call.
    // Best-effort; the provider context-overflow retry below remains the safety net.
    if (
      input.llmTurnKind !== 'overflow_retry' &&
      input.profile.primaryModel.model.contextWindow > 0 &&
      shouldCompact(estimateContextTokens(rendered.messages).tokens, input.profile.primaryModel.model.contextWindow, {
        enabled: input.profile.compression.enabled,
        reserveTokens: input.profile.compression.reserveTokens,
        keepRecentTokens: input.profile.compression.keepRecentTokens
      })
    ) {
      try {
        await this.compression.compress({
          conversationId: input.conversationId,
          profile: input.profile,
          trigger: 'threshold'
        })
        rendered = await this.renderer.render(input.conversationId)
      } catch (error) {
        console.error(error)
      }
    }
    const llmTurn = await this.conversations.startLlmTurn({
      agentUid: input.context.agentUid,
      conversationId: input.conversationId,
      kind: input.llmTurnKind ?? 'generation',
      profile: 'primary',
      provider: input.profile.primaryModel.config.providerId,
      model: input.profile.primaryModel.config.model,
      reasoning: input.profile.primaryModel.config.reasoning,
      triggerMessageId,
      inputMessageIds: rendered.inputMessageIds,
      inputSummaryMessageId: rendered.summaryMessageId ?? null,
      requestContext: {
        message_count: rendered.messages.length
      }
    })

    const abortController = new AbortController()
    const profileOptions = input.profile.primaryModel.options
    const providerObservation: JsonObject = {}
    const clarifyRoomId = input.providerRoomId ?? input.providerThreadId ?? ''
    const binding: ClarifyRunBinding = {
      conversationId: input.conversationId,
      leaseId: lease.leaseId,
      agentUid: input.context.agentUid,
      bindingName: input.context.bindingName,
      providerRoomId: clarifyRoomId,
      providerThreadId: input.providerThreadId ?? clarifyRoomId,
      outbox: input.context.outbox,
      scheduleOutboxDrain: input.context.scheduleOutboxDrain
    }
    const activeTools = this.buildActiveToolsForRun(binding)
    const agent = new Agent({
      initialState: {
        systemPrompt: 'You are a BullX AI coworker. Reply in plain text.',
        messages: rendered.messages,
        model: input.profile.primaryModel.model,
        thinkingLevel: input.profile.primaryModel.config.reasoning ?? 'medium',
        tools: activeTools
      },
      // core's low-level Agent has no `streamOptions`: forward curated provider request options via a
      // streamFn wrapper, and pass the harness `convertToLlm` so compaction-summary messages reach the model
      // (the Agent's default convertToLlm would drop them).
      convertToLlm,
      toolExecution: 'parallel',
      // Context transform hook (AgentHarness 'context' event) — extension point for in-run context shaping.
      transformContext: (messages, signal) => this.transformGenerationContext(messages, signal),
      // Tool call policy hooks (AgentHarness tool_call / tool_result) — only wired when tools are active.
      beforeToolCall:
        activeTools.length > 0 ? (toolContext, signal) => this.beforeToolCall(toolContext, signal) : undefined,
      afterToolCall:
        activeTools.length > 0 ? (toolContext, signal) => this.afterToolCall(toolContext, signal) : undefined,
      // Provider request policy + observability (AgentHarness stream options + before/after provider hooks).
      streamFn: (model, context, options) =>
        streamSimple(model, context, {
          ...options,
          ...profileOptions,
          metadata: { ...options?.metadata, conversation_id: input.conversationId, llm_turn_id: llmTurn.id },
          onPayload: async payload => {
            const replacement = await options?.onPayload?.(payload, model)
            observeProviderPayload(providerObservation, replacement ?? payload)
            return replacement
          },
          onResponse: async response => {
            await options?.onResponse?.(response, model)
            observeProviderResponse(providerObservation, response)
          }
        })
    })
    this.registry.set({
      conversationId: input.conversationId,
      leaseId: lease.leaseId,
      triggerMessageId,
      agent,
      abortController,
      startedAt: new Date()
    })

    try {
      if (abortController.signal.aborted) agent.abort()
      else abortController.signal.addEventListener('abort', () => agent.abort(), { once: true })
      await agent.continue()
      const assistant = [...agent.state.messages].reverse().find(message => message.role === 'assistant') as
        | AssistantMessage
        | undefined
      if (!assistant) {
        await this.conversations.finishLlmTurn({
          llmTurnId: llmTurn.id,
          status: 'failed',
          response: { error: 'Provider did not return an assistant message' }
        })
        await this.conversations.clearGenerationLease(input.conversationId, lease.leaseId)
        this.registry.delete(input.conversationId, lease.leaseId)
        return
      }

      if (!(await this.conversations.generationCanCommit(input.conversationId, lease.leaseId))) {
        await this.conversations.finishLlmTurn({
          llmTurnId: llmTurn.id,
          status: 'cancelled',
          response: {
            fenced: true,
            stop_reason: assistant.stopReason,
            response_id: assistant.responseId ?? null
          },
          usage: assistant.usage as unknown as JsonObject,
          providerMetadata: {
            pi_provider: input.profile.primaryModel.config.piProvider,
            response_id: assistant.responseId ?? null,
            response_model: assistant.responseModel ?? null,
            ...providerObservation
          }
        })
        this.registry.delete(input.conversationId, lease.leaseId)
        return
      }

      await this.conversations.finishLlmTurn({
        llmTurnId: llmTurn.id,
        status:
          assistant.stopReason === 'aborted' ? 'cancelled' : assistant.stopReason === 'error' ? 'failed' : 'succeeded',
        response: normalizedAssistantResponse(assistant),
        usage: assistant.usage as unknown as JsonObject,
        providerMetadata: {
          pi_provider: input.profile.primaryModel.config.piProvider,
          response_id: assistant.responseId ?? null,
          response_model: assistant.responseModel ?? null,
          ...providerObservation
        }
      })

      if (
        assistant.stopReason === 'error' &&
        isContextOverflow(assistant, input.profile.primaryModel.model.contextWindow)
      ) {
        const overflowAttempts = input.overflowAttempts ?? 0
        if (overflowAttempts >= input.profile.compression.maxOverflowRetries) {
          // Fall through to the visible error row below after the configured retry budget is exhausted.
        } else {
          await this.compression.compress({
            conversationId: input.conversationId,
            profile: input.profile,
            trigger: 'provider_context_overflow'
          })
          await this.conversations.clearGenerationLease(input.conversationId, lease.leaseId)
          this.registry.delete(input.conversationId, lease.leaseId)
          this.startGeneration({
            ...input,
            leaseId: undefined,
            llmTurnKind: 'overflow_retry',
            overflowAttempts: overflowAttempts + 1
          })
          return
        }
      }

      const text = textFromAgentMessage(assistant).trim()
      const commit = await this.commitAssistantResult({
        assistant,
        bindingName: input.context.bindingName,
        conversationId: input.conversationId,
        leaseId: lease.leaseId,
        llmTurnId: llmTurn.id,
        providerRoomId: input.providerRoomId,
        providerThreadId: input.providerThreadId,
        routeMetadata: routeMetadata(input.context),
        text,
        triggerMessageId
      })
      if (!commit) {
        this.registry.delete(input.conversationId, lease.leaseId)
        return
      }
      if (commit.enqueuedOutput) {
        input.context.scheduleOutboxDrain()
      }

      this.registry.delete(input.conversationId, lease.leaseId)
      if (commit.nextGeneration) {
        this.startGeneration({
          ...input,
          leaseId: commit.nextGeneration.leaseId,
          providerRoomId: commit.nextGeneration.providerRoomId,
          providerThreadId: commit.nextGeneration.providerThreadId,
          triggerMessageId: commit.nextGeneration.triggerMessageId
        })
      }
    } catch (error) {
      await this.conversations.finishLlmTurn({
        llmTurnId: llmTurn.id,
        status: abortController.signal.aborted ? 'cancelled' : 'failed',
        response: { error: error instanceof Error ? error.message : String(error) }
      })
      await this.conversations.clearGenerationLease(input.conversationId, lease.leaseId)
      this.registry.delete(input.conversationId, lease.leaseId)
    }
  }

  private async retryLastExchange(
    conversationId: string,
    context: ExternalGatewayAgentExecutionContext,
    event: ExternalGatewayAgentDelivery['events'][number],
    profile: AiAgentRuntimeProfile
  ): Promise<void> {
    const rendered = await this.conversations.renderedMessages(conversationId)
    const latestAssistant = [...rendered].reverse().find(row => row.role === 'assistant')
    const triggerMessageId = latestAssistant
      ? stringFromMetadata(latestAssistant.metadata, ['generation', 'trigger_message_id'])
      : rendered.findLast(row => row.role === 'user')?.id
    if (!triggerMessageId) {
      await this.enqueueFeedback(context, event, 'Nothing to retry.')
      return
    }
    const triggerIndex = rendered.findIndex(row => row.id === triggerMessageId)
    const retrySuffix = triggerIndex < 0 ? [] : rendered.slice(triggerIndex + 1)
    for (const row of retrySuffix) {
      await DB.update(AiAgentMessages)
        .set({
          metadata: sql`jsonb_set(${AiAgentMessages.metadata}, '{transcript_effect}', ${jsonbParam({ state: 'superseded', source_event_id: event.providerEventId })}, true)`,
          updatedAt: sql`now()`
        })
        .where(eq(AiAgentMessages.id, row.id))
    }
    if (latestAssistant) {
      const outboundKey = stringFromMetadata(latestAssistant.metadata, ['outbound', 'outbound_key'])
      if (outboundKey) {
        await context.outbox.enqueuePending({
          agentUid: context.agentUid,
          bindingName: context.bindingName,
          intent: {
            operation: 'delete',
            outboundKey: `ai-agent-retry-delete:${event.providerEventId}:${latestAssistant.id}`,
            providerRoomId: event.providerRoomId,
            providerThreadId: event.providerThreadId,
            finalPayload: { targetOutboundKey: outboundKey }
          }
        })
      }
    }
    this.startGeneration({
      context,
      conversationId,
      llmTurnKind: 'retry_generation',
      profile,
      providerRoomId: event.providerRoomId,
      providerThreadId: event.providerThreadId,
      triggerMessageId
    })
    await this.enqueueFeedback(context, event, 'Retrying the last exchange.')
  }

  private async drainAmbientAndStartGeneration(
    context: ExternalGatewayAgentExecutionContext,
    profile: AiAgentRuntimeProfile
  ): Promise<void> {
    const conversations = await this.ambient.drainDue({
      agentUid: context.agentUid,
      bindingName: context.bindingName,
      profile
    })
    for (const conversation of conversations) {
      this.startGeneration({
        context,
        conversationId: conversation.conversationId,
        profile,
        providerRoomId: conversation.providerRoomId,
        providerThreadId: conversation.providerThreadId
      })
    }
    await this.scheduleNextAmbientDrain(context, profile)
  }

  private scheduleAmbientDrain(
    context: ExternalGatewayAgentExecutionContext,
    profile: AiAgentRuntimeProfile,
    delayMs: number
  ): void {
    const timer = setTimeout(
      () => {
        this.ambientTimers.delete(timer)
        this.drainAmbientAndStartGeneration(context, profile).catch(() => undefined)
      },
      Math.max(0, delayMs)
    )
    this.ambientTimers.add(timer)
  }

  private async scheduleNextAmbientDrain(
    context: ExternalGatewayAgentExecutionContext,
    profile: AiAgentRuntimeProfile
  ): Promise<void> {
    const delayMs = await this.ambient.nextDueDelayMs({
      agentUid: context.agentUid,
      bindingName: context.bindingName
    })
    if (delayMs === undefined) return
    this.scheduleAmbientDrain(context, profile, delayMs + 5)
  }

  private async latestTriggerMessageId(conversationId: string): Promise<string | undefined> {
    const [row] = await DB.select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          sql`${AiAgentMessages.role} in ('user', 'im_ambient')`,
          sql`${AiAgentMessages.kind} in ('normal', 'introspection')`,
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`
        )
      )
      .orderBy(desc(AiAgentMessages.createdAt))
      .limit(1)
    return row?.id
  }

  private async commitAssistantResult(input: {
    assistant: AssistantMessage
    bindingName: string
    conversationId: string
    leaseId: string
    llmTurnId: string
    providerRoomId?: string
    providerThreadId?: string
    routeMetadata: JsonObject
    text: string
    triggerMessageId: string
  }): Promise<
    | {
        enqueuedOutput: boolean
        nextGeneration?: {
          leaseId: string
          providerRoomId?: string
          providerThreadId?: string
          triggerMessageId: string
        }
      }
    | undefined
  > {
    return DB.transaction(async tx => {
      const [conversation] = await tx
        .select()
        .from(AiAgentConversations)
        .where(eq(AiAgentConversations.id, input.conversationId))
        .for('update')
        .limit(1)
      if (!conversation) return undefined
      if (conversation.endedAt) return undefined
      if (conversation.generation.lease_id !== input.leaseId || conversation.generation.cancelled_at) return undefined

      const pendingFollowups = normalizePendingArray<PendingFollowup>(conversation.generation.pending_followups)
      const pendingSteering = normalizePendingArray<PendingSteering>(conversation.generation.pending_steering)
      const assistantMessageId = genUUIDv7()
      const isVisibleOutput =
        input.text.length > 0 && input.assistant.stopReason !== 'error' && input.assistant.stopReason !== 'aborted'
      const outboundKey = `ai-agent-final:${assistantMessageId}`
      let nextTriggerMessageId: string | undefined
      let nextProviderRoomId = input.providerRoomId
      let nextProviderThreadId = input.providerThreadId

      await tx.insert(AiAgentMessages).values({
        id: assistantMessageId,
        agentUid: conversation.agentUid,
        conversationId: input.conversationId,
        role: 'assistant',
        kind: input.assistant.stopReason === 'error' || input.assistant.stopReason === 'aborted' ? 'error' : 'normal',
        status: 'complete',
        content: jsonbParam(
          textContent(input.text || input.assistant.errorMessage || 'The model did not return a text response.')
        ),
        agentMessage: jsonbParam(toJsonObject(input.assistant)),
        metadata: jsonbParam({
          llm_turn_id: input.llmTurnId,
          generation: { trigger_message_id: input.triggerMessageId, lease_id: input.leaseId },
          ...(isVisibleOutput ? { outbound: { outbound_key: outboundKey } } : {}),
          route: input.routeMetadata
        })
      })

      if (isVisibleOutput) {
        const providerRoomId =
          input.providerRoomId ?? stringFromMetadata(conversation.metadata, ['route', 'provider_room_id']) ?? ''
        const providerThreadId = input.providerThreadId ?? input.providerRoomId ?? providerRoomId
        await tx
          .insert(ExternalGatewayOutbox)
          .values({
            agentUid: conversation.agentUid,
            bindingName: input.bindingName,
            providerRoomId,
            providerThreadId,
            outboundKey,
            operation: 'post',
            finalPayload: jsonbParam({ text: input.text }),
            status: 'pending',
            idempotencyKey: idempotencyKeyFromOutboundKey(outboundKey),
            recoveryState: 'not_started'
          })
          .onConflictDoNothing()
      }

      for (const steering of pendingSteering) {
        const messageId = genUUIDv7()
        const marker = steeringMarker(steering)
        await tx.insert(AiAgentMessages).values({
          id: messageId,
          agentUid: conversation.agentUid,
          conversationId: input.conversationId,
          role: 'user',
          kind: 'introspection',
          status: 'complete',
          content: jsonbParam(textContent(marker)),
          agentMessage: jsonbParam(toJsonObject(createUserMessage(marker, new Date(steering.created_at).getTime()))),
          eventSource: 'ai-agent.command.steer',
          eventId: steering.command_event_id,
          metadata: jsonbParam({
            control: {
              origin: 'steering',
              type: 'steering',
              source_command_event_id: steering.command_event_id,
              command_event_id: steering.command_event_id
            }
          })
        })
        nextTriggerMessageId = messageId
      }

      for (const followup of pendingFollowups) {
        const messageId = genUUIDv7()
        await tx.insert(AiAgentMessages).values({
          id: messageId,
          agentUid: conversation.agentUid,
          conversationId: input.conversationId,
          role: 'user',
          kind: 'normal',
          status: 'complete',
          content: jsonbParam(textContent(followup.text)),
          agentMessage: jsonbParam(
            toJsonObject(createUserMessage(followup.text, new Date(followup.created_at).getTime()))
          ),
          eventSource: followup.event_source,
          eventId: followup.event_id,
          metadata: jsonbParam({
            actor: followup.actor ?? {},
            provider_refs: followup.provider_refs,
            control: { origin: 'followup_or_steer_fallback' }
          })
        })
        nextTriggerMessageId = messageId
        nextProviderRoomId = stringFromMetadata(followup.provider_refs, ['room_id']) ?? nextProviderRoomId
        nextProviderThreadId = stringFromMetadata(followup.provider_refs, ['thread_id']) ?? nextProviderThreadId
      }

      const nextLeaseId = nextTriggerMessageId ? genUUIDv7() : undefined
      await tx
        .update(AiAgentConversations)
        .set({
          generation: jsonbParam(nextLeaseId ? newGenerationLease(nextLeaseId, nextTriggerMessageId!) : {}),
          updatedAt: sql`now()`
        })
        .where(eq(AiAgentConversations.id, input.conversationId))

      return {
        enqueuedOutput: isVisibleOutput,
        nextGeneration:
          nextLeaseId && nextTriggerMessageId
            ? {
                leaseId: nextLeaseId,
                providerRoomId: nextProviderRoomId,
                providerThreadId: nextProviderThreadId,
                triggerMessageId: nextTriggerMessageId
              }
            : undefined
      }
    })
  }

  private async enqueueFeedback(
    context: ExternalGatewayAgentExecutionContext,
    event: ExternalGatewayAgentDelivery['events'][number],
    text: string
  ): Promise<void> {
    await context.outbox.enqueuePending({
      agentUid: context.agentUid,
      bindingName: context.bindingName,
      intent: commandFeedbackIntent({
        commandEventId: event.providerEventId,
        providerRoomId: event.providerRoomId,
        providerThreadId: event.providerThreadId,
        text
      })
    })
    context.scheduleOutboxDrain()
  }

  private materializeSteering(conversationId: string, steering: PendingSteering) {
    return this.conversations.appendMessage({
      conversationId,
      role: 'user',
      kind: 'normal',
      content: textContent(steering.text),
      agentMessage: createUserMessage(steering.text, new Date(steering.created_at).getTime()),
      eventSource: 'ai-agent.command.steer',
      eventId: steering.command_event_id,
      metadata: {
        control: {
          origin: 'steer_fallback',
          type: 'steer_fallback',
          source_command_event_id: steering.command_event_id,
          command_event_id: steering.command_event_id
        }
      }
    })
  }
}

export const aiAgentRuntime = new AiAgentRuntime()

function routeFromContext(
  context: ExternalGatewayAgentExecutionContext,
  providerRoomId: string
): AiAgentConversationRoute {
  return {
    agentUid: context.agentUid,
    bindingName: context.bindingName,
    providerRealmId: context.providerRealmId ?? null,
    providerRoomId
  }
}

function commandFromEnvelope(envelope: ExternalGatewayAgentEnvelope): ExternalGatewaySlashCommandStub | undefined {
  return envelope.data.command
}

function messageText(envelope: ExternalGatewayAgentEnvelope): string {
  const text = envelope.data.message?.text
  return typeof text === 'string' ? text : ''
}

function actorFromEnvelope(envelope: ExternalGatewayAgentEnvelope): JsonObject {
  const message = envelope.data.message
  const author = message?.author
  return typeof author === 'object' && author !== null && !Array.isArray(author) ? (author as JsonObject) : {}
}

function routeMetadata(context: ExternalGatewayAgentExecutionContext, providerThreadId?: string): JsonObject {
  return {
    agent_uid: context.agentUid,
    binding_name: context.bindingName,
    provider_realm_id: context.providerRealmId ?? null,
    provider_thread_id: providerThreadId ?? null
  }
}

function normalizedAssistantResponse(message: AssistantMessage): JsonObject {
  return {
    content: JSON.parse(JSON.stringify(message.content)) as JsonValue,
    stop_reason: message.stopReason,
    error_message: message.errorMessage ?? null,
    response_id: message.responseId ?? null
  }
}

function normalizePendingArray<T>(value: unknown): T[] {
  return Array.isArray(value) ? (value as T[]) : []
}

function steeringMarker(steering: PendingSteering): string {
  return `<human_steering_note command_event_id="${steering.command_event_id}">${steering.text}</human_steering_note>`
}

function observeProviderPayload(observation: JsonObject, payload: unknown): void {
  // Provider request observability (AgentHarness before_provider_payload). Record a lightweight fingerprint;
  // the full payload can be large and may carry message content.
  if (payload && typeof payload === 'object' && !Array.isArray(payload)) {
    observation.request_payload_keys = Object.keys(payload as Record<string, unknown>)
  }
}

function observeProviderResponse(observation: JsonObject, response: unknown): void {
  // Provider response observability (AgentHarness after_provider_response).
  if (!response || typeof response !== 'object') return
  const { status, headers } = response as { status?: unknown; headers?: unknown }
  if (typeof status === 'number') observation.response_status = status
  const requestId = headerValue(headers, 'x-request-id') ?? headerValue(headers, 'request-id')
  if (requestId) observation.provider_request_id = requestId
  observation.observed_at = new Date().toISOString()
}

function headerValue(headers: unknown, key: string): string | undefined {
  if (!headers) return undefined
  if (typeof Headers !== 'undefined' && headers instanceof Headers) return headers.get(key) ?? undefined
  if (typeof headers === 'object') {
    const value = (headers as Record<string, unknown>)[key]
    return typeof value === 'string' ? value : undefined
  }
  return undefined
}

function validateUniqueNames(names: string[], message: string): void {
  const seen = new Set<string>()
  const duplicates = new Set<string>()
  for (const name of names) {
    if (seen.has(name)) duplicates.add(name)
    seen.add(name)
  }
  if (duplicates.size > 0) throw new AiAgentRuntimeError(`${message}: ${[...duplicates].join(', ')}`)
}

function validateToolNames(names: string[], tools: Map<string, AgentTool<any>>): void {
  validateUniqueNames(names, 'Duplicate active tool name(s)')
  const missing = names.filter(name => !tools.has(name))
  if (missing.length > 0) throw new AiAgentRuntimeError(`Unknown tool(s): ${missing.join(', ')}`)
}

export class AiAgentRuntimeError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AiAgentRuntimeError'
  }
}

function payloadEnvelope(event: ExternalGatewayAgentDelivery['events'][number]): ExternalGatewayAgentEnvelope {
  return event.payload as unknown as ExternalGatewayAgentEnvelope
}

function isActiveGeneration(generation: { lease_id?: unknown; cancelled_at?: unknown }): boolean {
  return typeof generation.lease_id === 'string' && generation.lease_id.length > 0 && !generation.cancelled_at
}
