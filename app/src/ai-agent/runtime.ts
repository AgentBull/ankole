import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { isContextOverflow, streamSimple, type AssistantMessage, type ToolResultMessage } from '@earendil-works/pi-ai'
import { match } from '@pleisto/active-support'
import { and, asc, desc, eq, sql } from 'drizzle-orm'
import { DB, jsonbParam } from '@/common/database'
import { logger } from '@/common/logger'
import {
  AiAgentConversations,
  AiAgentLlmTurns,
  AiAgentMessages,
  ExternalGatewayOutbox,
  type JsonObject,
  type JsonValue
} from '@/common/db-schema'
import { adapterSupportsCapability } from '@/external-gateway/core/capabilities'
import type {
  ExternalGatewayAgentDelivery,
  ExternalGatewayAgentEnvelope,
  ExternalGatewaySlashCommandStub
} from '@/external-gateway/agent-events'
import type { ExternalGatewayAgentExecutionContext } from '@/external-gateway/agent'
import type { ExternalGatewayStreamingCardHandle } from '@/external-gateway/core/events'
import { commandEditIntent, commandFeedbackIntent } from './commands'
import { loadAiAgentRuntimeProfile, type AiAgentRuntimeProfile } from './config'
import {
  aiAgentConversationService,
  buildRouteMetadata,
  isActiveGeneration,
  newGenerationLease,
  providerRefs,
  textContent,
  textFromContent,
  type AiAgentConversationRoute,
  type AiAgentConversationService,
  type AiAgentLlmTurnKind,
  type AiAgentLlmTurnStatus,
  type PendingFollowup,
  type PendingSteering
} from './conversation-service'
import { aiAgentContextRenderer, type AiAgentContextRenderer, type RenderedAiAgentContext } from './context-renderer'
import { aiAgentDailyResetService, type AiAgentDailyResetService } from './daily-reset'
import { aiAgentAmbientBatcher, type AiAgentAmbientBatcher } from './ambient'
import { aiAgentCompressionService, type AiAgentCompressionService } from './compression'
import { aiAgentLifecycleRevisionService, type AiAgentLifecycleRevisionService } from './lifecycle-revisions'
import { aiAgentRunRegistry, type AiAgentRunRegistry } from './run-registry'
import { aiAgentClarifyRegistry, type AiAgentClarifyRegistry, type ClarifyEntry } from './clarify-registry'
import { createClarifyTool, type ClarifyRunBinding } from './tools/clarify-tool'
import { createCheckBackLaterTool } from './tools/check-back-later-tool'
import { createComputerTools, type ComputerToolsDeps } from './tools/computer'
import { type ClarifyAnswerValue, parseClarifyAnswerValue, renderClarifyChoicePrompt } from './tools/choice-prompt'
import { mapAnswer } from './tools/clarify-format'
import {
  Agent,
  type BeforeLlmCallContext,
  type BeforeLlmCallResult,
  convertToLlm,
  createCustomMessage,
  createUserMessage,
  shouldCompact,
  textFromAgentMessage,
  type AfterToolCallContext,
  type AfterToolCallResult,
  type AgentMessage,
  type AgentEvent,
  type AgentTool,
  type BeforeToolCallContext,
  type BeforeToolCallResult,
  type ShouldStopAfterTurnContext
} from './core'
import { isJsonObject, stringFromPath as stringFromMetadata, toJsonObject, toJsonValue } from '@/common/json'
import { idempotencyKeyFromOutboundKey } from '@/external-gateway/outbox'
import { interactiveOutputCardPayload, larkNativeCardPayload } from '@/external-gateway/interactive-output'
import { createTodoTool, TodoStore, todoItemsFromToolDetails, type TodoToolDetails } from './tools/todo-tool'
import { buildAgentSystemPrompt } from './library/service'
import { createSkillTools } from './library/tools'
import { estimateContextTokensJsonAware } from './token-estimate'
import { classifyLlmError } from './core/llm-error-classifier'
import {
  appendMessageContextHistory,
  buildMessageContextMetadata,
  loadMessageContextHistory,
  mergeMessageContextMetadata,
  type MessageContextHistoryItem
} from './message-context'

/**
 * Hard cap on LLM turns per generation. On reaching it the loop runs one tool-free
 * grace summary turn (so a runaway tool-calling model still produces a usable answer)
 * and stops. Generous by default; can be lifted to the runtime profile later.
 */
const MAX_GENERATION_TURNS = 100

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

type RunGenerationInput = {
  abortSignal?: AbortSignal
  context: ExternalGatewayAgentExecutionContext
  conversationId: string
  disableInteractiveTools?: boolean
  leaseId?: string
  llmTurnKind?: AiAgentLlmTurnKind
  overflowAttempts?: number
  profile: AiAgentRuntimeProfile
  providerRoomId?: string
  providerThreadId?: string
  suppressVisibleOutput?: boolean
  triggerMessageId?: string
}

interface GenerationRunContext {
  abortController: AbortController
  abortFromParent?: () => void
  input: RunGenerationInput
  leaseId: string
  recorder: GenerationTrajectoryRecorder
  triggerMessageId: string
}

interface StreamedAssistantCard {
  cardId: string
  messageId: string
  outboundKey: string
}

interface GenerationStreamingSink {
  onStreamingText?: (fullText: string) => void
  finalize(assistant: AssistantMessage, text: string): Promise<StreamedAssistantCard | undefined>
}

interface TodoProgressState {
  args: unknown
  outboundKey: string
  posted: boolean
  toolCallId: string
}

interface NextGeneration {
  leaseId: string
  providerRoomId?: string
  providerThreadId?: string
  triggerMessageId: string
}

type CommitAssistantResult =
  | {
      assistantMessageId: string
      enqueuedOutput: boolean
      nextGeneration?: NextGeneration
    }
  | undefined

type GenerationResultStatus = 'succeeded' | 'failed' | 'cancelled' | 'fenced'

interface GenerationResult {
  enqueuedOutput: boolean
  status: GenerationResultStatus
}

export interface AiAgentProgrammaticTurnInput {
  conversationProviderRoomId: string
  disableInteractiveTools?: boolean
  eventId: string
  eventSource: string
  kind: Extract<AiAgentLlmTurnKind, 'scheduled_task' | 'checkback_generation'>
  message: string
  metadata?: JsonObject
  outputProviderRoomId?: string
  outputProviderThreadId?: string
  signal?: AbortSignal
  suppressVisibleOutput?: boolean
}

export interface AiAgentProgrammaticTurnResult extends GenerationResult {
  conversationId: string
  triggerMessageId: string
}

type RunOutcome =
  | {
      kind: 'committed'
      assistant: AssistantMessage
      stream: GenerationStreamingSink
    }
  | {
      kind: 'overflow_retry'
      assistant: AssistantMessage
      attempts: number
    }
  | {
      kind: 'fenced'
      assistant: AssistantMessage
    }
  | {
      kind: 'failed'
      aborted: boolean
      error: unknown
    }
  | {
      kind: 'no_assistant'
    }

interface LlmTurnFinish {
  providerMetadata?: JsonObject
  response?: JsonObject
  status: AiAgentLlmTurnStatus
  toolResults?: JsonValue[]
  usage?: JsonObject
}

class GenerationTrajectoryRecorder {
  private callIndex = 0
  private openTurnId?: string
  private readonly messageRefs = new WeakMap<object, JsonValue>()
  private readonly providerObservations = new Map<string, JsonObject>()
  private previousToolsSnapshot?: string
  public lastFinishedTurnId?: string

  constructor(
    private readonly input: RunGenerationInput,
    private readonly leaseId: string,
    private readonly triggerMessageId: string,
    private readonly rendered: RenderedAiAgentContext,
    private readonly conversations: AiAgentConversationService
  ) {
    rendered.messages.forEach((message, index) => {
      const ref = rendered.inputMessageRefs[index]
      if (ref && typeof message === 'object' && message !== null) this.messageRefs.set(message, ref)
    })
  }

  async beforeLlmCall(context: BeforeLlmCallContext): Promise<BeforeLlmCallResult> {
    const callIndex = this.callIndex++
    const requestRefs = context.messages.map((message, index) => this.refForMessage(message, index))
    const toolsSnapshot = snapshotTools(context.llmContext.tools as AgentTool<any>[] | undefined)
    const requestPatches = callIndex === 0 ? [...this.rendered.modelViewPatches] : []
    const toolsSnapshotJson = JSON.stringify(toolsSnapshot)
    if (toolsSnapshotJson !== this.previousToolsSnapshot) {
      requestPatches.push({
        type: 'llm_tool_definitions',
        tools: toolsSnapshot
      })
      this.previousToolsSnapshot = toolsSnapshotJson
    }
    const branchId = branchIdForRendered(this.input.conversationId, this.rendered)
    const llmTurn = await this.conversations.startLlmTurn({
      agentUid: this.input.context.agentUid,
      branchId,
      callIndex,
      conversationId: this.input.conversationId,
      kind: this.input.llmTurnKind ?? 'generation',
      leaseId: this.leaseId,
      model: this.input.profile.primaryModel.config.model,
      parentBranchId: parentBranchIdForRendered(this.input.conversationId, this.rendered),
      profile: 'primary',
      provider: this.input.profile.primaryModel.config.providerId,
      reasoning: this.input.profile.primaryModel.config.reasoning,
      inputMessageIds: inputMessageIdsFromRefs(requestRefs),
      inputSummaryMessageId: this.rendered.summaryMessageId ?? null,
      requestContext: {
        agent_message_count: context.messages.length,
        llm_message_count: context.llmMessages.length,
        llm_message_roles: context.llmMessages.map(message => message.role),
        system_prompt: context.llmContext.systemPrompt ?? null,
        tool_count: toolsSnapshot.length,
        tool_names: toolsSnapshot.flatMap(tool =>
          typeof tool === 'object' && tool !== null && !Array.isArray(tool) && typeof tool.name === 'string'
            ? [tool.name]
            : []
        )
      },
      requestPatches,
      requestRefs,
      triggerMessageId: this.triggerMessageId
    })
    this.openTurnId = llmTurn.id
    this.providerObservations.set(llmTurn.id, {})
    return { metadata: { llm_turn_id: llmTurn.id } }
  }

  providerObservation(llmTurnId: unknown): JsonObject {
    return typeof llmTurnId === 'string' ? (this.providerObservations.get(llmTurnId) ?? {}) : {}
  }

  async finishTurn(message: AgentMessage, toolResults: ToolResultMessage[]): Promise<void> {
    const llmTurnId = this.openTurnId
    if (!llmTurnId) return

    const providerObservation = this.providerObservations.get(llmTurnId) ?? {}
    const toolResultsJson = toolResults.flatMap(result => {
      const json = trajectoryToolResult(result, llmTurnId)
      return json === null ? [] : [json]
    })
    const finish =
      message.role === 'assistant'
        ? assistantLlmTurnFinish(message, providerObservation, this.input.profile)
        : ({
            status: 'failed',
            response: { error: 'LLM turn ended without an assistant message' },
            providerMetadata: providerObservation
          } satisfies LlmTurnFinish)

    await this.conversations.finishLlmTurn({
      llmTurnId,
      ...finish,
      toolResults: toolResultsJson
    })
    if (message && typeof message === 'object') {
      this.messageRefs.set(message, { type: 'llm_turn_response', llm_turn_id: llmTurnId })
    }
    for (const result of toolResults) {
      this.messageRefs.set(result, {
        type: 'llm_turn_tool_result',
        llm_turn_id: llmTurnId,
        tool_call_id: result.toolCallId
      })
    }
    this.lastFinishedTurnId = llmTurnId
    this.openTurnId = undefined
  }

  async failOpenTurn(status: AiAgentLlmTurnStatus, response: JsonObject): Promise<void> {
    const llmTurnId = this.openTurnId
    if (!llmTurnId) return
    await this.conversations.finishLlmTurn({
      llmTurnId,
      status,
      response,
      providerMetadata: this.providerObservations.get(llmTurnId) ?? {}
    })
    this.openTurnId = undefined
  }

  private refForMessage(message: AgentMessage, index: number): JsonValue {
    if (message && typeof message === 'object') {
      const ref = this.messageRefs.get(message)
      if (ref) return ref
    }
    return {
      type: 'inline_agent_message',
      index,
      role: typeof message === 'object' && message !== null && 'role' in message ? message.role : null,
      message: toJsonValue(message)
    }
  }
}

function branchIdForRendered(conversationId: string, rendered: RenderedAiAgentContext): string {
  return rendered.summaryMessageId ? `summary:${rendered.summaryMessageId}` : `conversation:${conversationId}:root`
}

function parentBranchIdForRendered(conversationId: string, rendered: RenderedAiAgentContext): string | null {
  return rendered.summaryMessageId ? `conversation:${conversationId}:root` : null
}

function inputMessageIdsFromRefs(refs: JsonValue[]): string[] {
  return refs.flatMap(ref => {
    if (typeof ref !== 'object' || ref === null || Array.isArray(ref)) return []
    if (ref.type !== 'ai_agent_message' || typeof ref.id !== 'string') return []
    return [ref.id]
  })
}

function trajectoryToolResult(result: ToolResultMessage, llmTurnId: string): JsonValue | null {
  const json = toJsonValue(result)
  if (!isJsonObject(json)) return json
  const details = isJsonObject(json.details) ? json.details : {}
  const execution = isJsonObject(details.bullx_execution) ? details.bullx_execution : {}
  const toolCallId = typeof json.toolCallId === 'string' ? json.toolCallId : execution.tool_call_id
  const idempotencyKey =
    typeof toolCallId === 'string' && toolCallId.length > 0 ? `llm-turn:${llmTurnId}:tool-call:${toolCallId}` : null
  return {
    ...json,
    details: {
      ...details,
      bullx_execution: {
        ...execution,
        llm_turn_id: llmTurnId,
        idempotency_key: idempotencyKey
      }
    }
  }
}

function latestTodoItemsFromToolResults(toolResults: JsonValue[]): unknown[] | undefined {
  for (let index = toolResults.length - 1; index >= 0; index--) {
    const result = toolResults[index]
    if (!isJsonObject(result)) continue
    if (toolNameFromToolResult(result) !== 'todo') continue

    const fromDetails = todoItemsFromToolDetails(result.details)
    if (fromDetails) return fromDetails

    const fromContent = todoItemsFromToolContent(result.content)
    if (fromContent) return fromContent
  }
  return undefined
}

function toolNameFromToolResult(result: JsonObject): string | undefined {
  if (typeof result.toolName === 'string') return result.toolName
  if (typeof result.tool_name === 'string') return result.tool_name
  const details = isJsonObject(result.details) ? result.details : undefined
  const execution = details && isJsonObject(details.bullx_execution) ? details.bullx_execution : undefined
  return typeof execution?.tool_name === 'string' ? execution.tool_name : undefined
}

function todoItemsFromToolContent(content: unknown): unknown[] | undefined {
  if (!Array.isArray(content)) return undefined
  for (const block of content) {
    if (!isJsonObject(block) || typeof block.text !== 'string') continue
    try {
      const parsed = JSON.parse(block.text)
      const todos = todoItemsFromToolDetails(parsed)
      if (todos) return todos
    } catch {
      // Ignore non-JSON tool text.
    }
  }
  return undefined
}

function formatTodoProgressStart(args: unknown): string {
  const todos = todoArgs(args)
  if (!todos) return '📋 todo: "reading task list"'
  const verb = todoMerge(args) ? 'updating' : 'planning'
  return `📋 todo: "${verb} ${todos.length} task(s)"`
}

function formatTodoProgressEnd(args: unknown, result: unknown, isError: boolean): string {
  if (isError) return '📋 plan failed'
  const summary = todoSummaryFromResult(result)
  const todos = todoArgs(args)
  const merge = todoMerge(args)
  if (!summary) return formatTodoProgressStart(args)
  if (!todos) {
    if (summary.total > 0) return `📋 plan ${summary.completed}/${summary.total} task(s)`
    return '📋 plan reading tasks'
  }
  if (merge) {
    if (summary.total > 0 && summary.completed > 0) return `📋 plan update ${summary.completed}/${summary.total} ✓`
    return `📋 plan update ${todos.length} task(s)`
  }
  if (summary.total > 0 && summary.completed > 0) return `📋 plan ${summary.completed}/${summary.total} task(s)`
  return `📋 plan ${todos.length} task(s)`
}

function todoSummaryFromResult(result: unknown): TodoToolDetails['summary'] | undefined {
  if (!isJsonObject(result)) return undefined
  const details = isJsonObject(result.details) ? result.details : undefined
  const summary = details && isJsonObject(details.summary) ? details.summary : undefined
  if (!summary) return undefined
  return {
    total: numberValue(summary.total),
    pending: numberValue(summary.pending),
    in_progress: numberValue(summary.in_progress),
    completed: numberValue(summary.completed),
    cancelled: numberValue(summary.cancelled)
  }
}

function todoArgs(args: unknown): unknown[] | undefined {
  return isJsonObject(args) && Array.isArray(args.todos) ? args.todos : undefined
}

function todoMerge(args: unknown): boolean {
  return isJsonObject(args) && args.merge === true
}

function numberValue(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function snapshotTools(tools: AgentTool<any>[] | undefined): JsonValue[] {
  return (tools ?? []).flatMap(tool => {
    const snapshot = toJsonValue({
      name: tool.name,
      description: tool.description ?? null,
      parameters: tool.parameters ?? null,
      execution_mode: tool.executionMode ?? null,
      is_read_only: tool.isReadOnly ?? null,
      is_destructive: tool.isDestructive ?? null
    })
    return snapshot === null ? [] : [snapshot]
  })
}

function estimateGenerationContextTokens(
  messages: AgentMessage[],
  systemPrompt: string,
  tools: AgentTool<any>[]
): number {
  const messageTokens = estimateContextTokensJsonAware(messages)
  const systemTokens = Math.ceil(systemPrompt.length / 4)
  const toolChars = tools.reduce((sum, tool) => {
    return sum + tool.name.length + tool.description.length + safeJsonStringify(tool.parameters).length
  }, 0)
  return messageTokens + systemTokens + Math.ceil(toolChars / 4)
}

function hasUsefulThresholdCompaction(input: {
  contextWindow: number
  keepRecentTokens: number
  messages: AgentMessage[]
  requestTokens: number
  reserveTokens: number
}): boolean {
  if (input.messages.length <= 2) return false
  const limit = input.contextWindow - input.reserveTokens
  const overage = input.requestTokens - limit
  if (overage <= 0) return false
  const messageTokens = estimateContextTokensJsonAware(input.messages)
  const estimatedReducibleTokens = Math.max(0, messageTokens - input.keepRecentTokens)
  return estimatedReducibleTokens >= overage
}

function safeJsonStringify(value: unknown): string {
  try {
    return JSON.stringify(value) ?? ''
  } catch {
    return ''
  }
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
  private computerFactory?: (binding: ClarifyRunBinding) => AgentTool<any>[]

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

  /** Enable/disable the run-bound computer tools (terminal/process/read_file/patch). */
  setComputerEnabled(enabled: boolean, deps: ComputerToolsDeps): void {
    this.computerFactory = enabled ? binding => createComputerTools(binding, deps) : undefined
  }

  /** Active run-static tools plus run-bound foundational tools (computer, clarify). */
  private buildActiveToolsForRun(
    binding: ClarifyRunBinding,
    todoStore: TodoStore,
    options: { disableInteractiveTools?: boolean } = {}
  ): AgentTool<any>[] {
    const tools = [
      ...this.getActiveTools(),
      ...createSkillTools({ agentUid: binding.agentUid }),
      createTodoTool(todoStore),
      createCheckBackLaterTool(binding)
    ]
    if (this.computerFactory) tools.push(...this.computerFactory(binding))
    if (!options.disableInteractiveTools && this.clarifyFactory && binding.providerRoomId) {
      tools.push(this.clarifyFactory(binding))
    }
    return tools
  }

  private async transformGenerationContext(
    messages: AgentMessage[],
    todoStore: TodoStore,
    _signal?: AbortSignal
  ): Promise<AgentMessage[]> {
    const activeSnapshot = todoStore.formatActiveSnapshot()
    if (!activeSnapshot) return messages
    return [
      ...messages,
      createCustomMessage('todo_active_snapshot', activeSnapshot, false, { source: 'todo' }, new Date().toISOString())
    ]
  }

  private async loadTodoStore(conversationId: string): Promise<TodoStore> {
    const store = new TodoStore()
    const turns = await DB.select({ toolResults: AiAgentLlmTurns.toolResults })
      .from(AiAgentLlmTurns)
      .where(
        and(
          eq(AiAgentLlmTurns.conversationId, conversationId),
          eq(AiAgentLlmTurns.status, 'succeeded'),
          sql`${AiAgentLlmTurns.kind} in ('generation', 'retry_generation', 'overflow_retry')`
        )
      )
      .orderBy(desc(AiAgentLlmTurns.completedAt), desc(AiAgentLlmTurns.startedAt), desc(AiAgentLlmTurns.id))

    for (const turn of turns) {
      const todos = latestTodoItemsFromToolResults(turn.toolResults)
      if (todos) {
        store.hydrate(todos)
        return store
      }
    }

    return store
  }

  private shouldStopAfterGenerationTurn(context: ShouldStopAfterTurnContext): boolean {
    const text = textFromAgentMessage(context.message).trim()
    if (!text) return false
    if (context.toolResults.length === 0) return true
    return context.toolResults.every(result => !result.isError && result.toolName === 'todo')
  }

  private async handleTodoProgressEvent(
    input: RunGenerationInput,
    event: AgentEvent,
    states: Map<string, TodoProgressState>
  ): Promise<void> {
    try {
      if (event.type === 'tool_execution_start' && event.toolName === 'todo') {
        await this.startTodoProgress(input, event.toolCallId, event.args, states)
      } else if (event.type === 'tool_execution_end' && event.toolName === 'todo') {
        await this.finishTodoProgress(input, event.toolCallId, event.result, event.isError, states)
      }
    } catch (error) {
      logger.debug({ error, conversationId: input.conversationId }, 'Todo tool progress update failed')
    }
  }

  private async startTodoProgress(
    input: RunGenerationInput,
    toolCallId: string,
    args: unknown,
    states: Map<string, TodoProgressState>
  ): Promise<void> {
    if (!this.canShowTodoProgress(input)) return
    const providerRoomId = input.providerRoomId ?? input.providerThreadId
    const providerThreadId = input.providerThreadId ?? providerRoomId
    if (!providerRoomId || !providerThreadId) return

    const outboundKey = `ai-agent-tool-progress:${input.conversationId}:${toolCallId}`
    states.set(toolCallId, { args, outboundKey, posted: true, toolCallId })
    await input.context.outbox.enqueuePending({
      agentUid: input.context.agentUid,
      bindingName: input.context.bindingName,
      intent: {
        operation: 'post',
        outboundKey,
        providerRoomId,
        providerThreadId,
        finalPayload: { text: formatTodoProgressStart(args) }
      }
    })
    input.context.scheduleOutboxDrain()
  }

  private async finishTodoProgress(
    input: RunGenerationInput,
    toolCallId: string,
    result: unknown,
    isError: boolean,
    states: Map<string, TodoProgressState>
  ): Promise<void> {
    const state = states.get(toolCallId)
    if (!state?.posted) return
    const providerRoomId = input.providerRoomId ?? input.providerThreadId
    const providerThreadId = input.providerThreadId ?? providerRoomId
    if (!providerRoomId || !providerThreadId) return

    await input.context.outbox.enqueuePending({
      agentUid: input.context.agentUid,
      bindingName: input.context.bindingName,
      intent: {
        operation: 'edit',
        outboundKey: `${state.outboundKey}:done`,
        providerRoomId,
        providerThreadId,
        finalPayload: {
          targetOutboundKey: state.outboundKey,
          text: formatTodoProgressEnd(state.args, result, isError)
        }
      }
    })
    input.context.scheduleOutboxDrain()
  }

  private canShowTodoProgress(input: RunGenerationInput): boolean {
    return (
      Boolean(input.providerThreadId) &&
      adapterSupportsCapability(input.context.adapter, 'outbound', 'post_message') &&
      adapterSupportsCapability(input.context.adapter, 'outbound', 'edit_message')
    )
  }

  private async beforeToolCall(
    _context: BeforeToolCallContext,
    _signal?: AbortSignal
  ): Promise<BeforeToolCallResult | undefined> {
    // Tool gate extension point (AgentHarness tool_call hook). No global gate today;
    // per-tool execution policy lives in the tools themselves (e.g. clarify).
    return undefined
  }

  private async afterToolCall(
    _context: AfterToolCallContext,
    _signal?: AbortSignal
  ): Promise<AfterToolCallResult | undefined> {
    // Tool result patch extension point (AgentHarness tool_result hook). No global
    // post-processing today; tools shape their own results.
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
    } else if (first.deliveryMode === 'action') {
      await this.acceptAction(delivery, context)
    } else if (first.deliveryMode === 'lifecycle') {
      await this.acceptLifecycle(delivery, context, route)
    }

    return { status: 'accepted' }
  }

  async runProgrammaticTurn(
    context: ExternalGatewayAgentExecutionContext,
    input: AiAgentProgrammaticTurnInput
  ): Promise<AiAgentProgrammaticTurnResult> {
    const profile = await this.loadProfile(context.agentUid)
    const conversation = await this.conversations.getOrCreateActiveConversation({
      agentUid: context.agentUid,
      bindingName: context.bindingName,
      providerRealmId: context.providerRealmId ?? null,
      providerRoomId: input.conversationProviderRoomId
    })
    const userMessage = createUserMessage(input.message)
    const history = await loadMessageContextHistory(conversation.id)
    const messageContext = buildMessageContextMetadata({ sentAt: new Date() }, history)
    const row = await this.conversations.appendMessage({
      conversationId: conversation.id,
      role: 'user',
      kind: 'normal',
      content: textContent(input.message),
      agentMessage: userMessage,
      eventSource: input.eventSource,
      eventId: input.eventId,
      metadata: mergeMessageContextMetadata(
        {
          ...input.metadata,
          route: routeMetadata(context, {
            providerRoomId: input.outputProviderRoomId,
            providerThreadId: input.outputProviderThreadId
          }),
          control: {
            ...toJsonObject(input.metadata?.control ?? {}),
            origin: input.kind
          }
        },
        messageContext
      )
    })
    const existingAssistant = await this.existingAssistantForTrigger(conversation.id, row.id)
    if (existingAssistant) {
      return {
        conversationId: conversation.id,
        triggerMessageId: row.id,
        status: existingAssistant.kind === 'error' ? 'failed' : 'succeeded',
        enqueuedOutput: hasOutbound(existingAssistant.metadata)
      }
    }
    const result = await this.runGeneration({
      context,
      conversationId: conversation.id,
      disableInteractiveTools: input.disableInteractiveTools,
      llmTurnKind: input.kind,
      abortSignal: input.signal,
      profile,
      providerRoomId: input.outputProviderRoomId,
      providerThreadId: input.outputProviderThreadId,
      suppressVisibleOutput: input.suppressVisibleOutput,
      triggerMessageId: row.id
    })
    return {
      ...result,
      conversationId: conversation.id,
      triggerMessageId: row.id
    }
  }

  private async existingAssistantForTrigger(
    conversationId: string,
    triggerMessageId: string
  ): Promise<typeof AiAgentMessages.$inferSelect | undefined> {
    const [assistant] = await DB.select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          eq(AiAgentMessages.role, 'assistant'),
          sql`${AiAgentMessages.metadata}->'generation'->>'trigger_message_id' = ${triggerMessageId}`
        )
      )
      .orderBy(desc(AiAgentMessages.createdAt), desc(AiAgentMessages.id))
      .limit(1)
    return assistant
  }

  /** True when this provider room has a pending clarify (group free-text reply gate). */
  roomHasPendingClarify(providerRoomId: string): boolean {
    return this.clarify.pendingConversationForRoom(providerRoomId) !== undefined
  }

  /**
   * Resolve a clarify from an interactive card button. First interaction wins and
   * locks: resolveByConversation is a single-shot funnel, so a second click (any
   * member) finds no entry and is silently ignored. On success we edit the card to
   * its locked state (buttons disabled, choice marked).
   */
  private async acceptAction(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentExecutionContext
  ): Promise<void> {
    const event = delivery.events[0]
    if (!event) return
    const action = (payloadEnvelope(event).data as { action?: { value?: unknown } } | undefined)?.action
    const answer = parseClarifyAnswerValue(action?.value)
    if (!answer) return

    const entry = this.clarify.get(answer.interactionId)
    const resolved = this.clarify.resolveByConversation(answer.interactionId, {
      kind: 'answer',
      text: answer.choiceValue,
      choiceIndex: answer.choiceIndex >= 0 ? answer.choiceIndex : undefined
    })
    if (resolved && entry) {
      await this.enqueueClarifyCardLock(context, event, entry, answer)
      context.scheduleOutboxDrain()
    }
  }

  private async enqueueClarifyCardLock(
    context: ExternalGatewayAgentExecutionContext,
    event: ExternalGatewayAgentDelivery['events'][number],
    entry: ClarifyEntry,
    answer: ClarifyAnswerValue
  ): Promise<void> {
    if (!entry.cardCapable) return
    const lockedOutput = renderClarifyChoicePrompt({
      question: entry.question,
      choices: entry.choices,
      correlationId: entry.conversationId,
      fallbackText: `Answered: ${answer.choiceValue}`,
      locked: true,
      answeredChoiceIndex: answer.choiceIndex >= 0 ? answer.choiceIndex : undefined,
      answeredText: answer.choiceValue
    })
    await context.outbox.enqueuePending({
      agentUid: context.agentUid,
      bindingName: context.bindingName,
      intent: {
        operation: 'edit',
        outboundKey: `ai-agent-clarify-lock:${entry.conversationId}:${entry.toolCallId}`,
        providerRoomId: event.providerRoomId,
        providerThreadId: event.providerThreadId,
        finalPayload: toJsonObject({
          targetOutboundKey: entry.askedOutboundKey,
          ...interactiveOutputCardPayload(lockedOutput)
        })
      }
    })
  }

  async recoverExternalGatewayBinding(context: ExternalGatewayAgentExecutionContext): Promise<void> {
    const profile = await this.loadProfile(context.agentUid)
    const rebuiltOutboxRows = await this.rebuildMissingAssistantOutbox(context)
    if (rebuiltOutboxRows > 0) context.scheduleOutboxDrain()

    const conversations = await this.conversations.findRecoverableGenerations(context.agentUid, context.bindingName)

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
        const envelope = payloadEnvelope(event)
        await this.conversations.appendPendingFollowup(conversation.id, {
          actor: actorFromEnvelope(envelope),
          created_at: new Date().toISOString(),
          event_id: event.providerEventId,
          event_source: envelope.source,
          provider_refs: providerRefs({
            eventId: event.providerEventId,
            providerMessageId: event.providerMessageId,
            providerRoomId: event.providerRoomId,
            providerThreadId: event.providerThreadId
          }),
          room: roomFromEnvelope(envelope),
          sent_at: sentAtFromEnvelope(envelope, event).toISOString(),
          text: messageText(envelope)
        })
      }
      return
    }

    let triggerMessageId: string | undefined
    const history = await loadMessageContextHistory(conversation.id)
    for (const event of delivery.events) {
      const envelope = payloadEnvelope(event)
      const text = messageText(envelope)
      const actor = actorFromEnvelope(envelope)
      const room = roomFromEnvelope(envelope)
      const sentAt = sentAtFromEnvelope(envelope, event)
      const userMessage = createUserMessage(text, sentAt.getTime())
      const messageContext = buildMessageContextMetadata({ actor, room, sentAt }, history)
      const row = await this.conversations.appendMessage({
        conversationId: conversation.id,
        role: 'user',
        kind: 'normal',
        content: textContent(text),
        agentMessage: userMessage,
        eventSource: envelope.source,
        eventId: event.providerEventId,
        metadata: mergeMessageContextMetadata(
          {
            actor,
            provider_refs: providerRefs({
              eventId: event.providerEventId,
              providerMessageId: event.providerMessageId,
              providerRoomId: event.providerRoomId,
              providerThreadId: event.providerThreadId
            }),
            route: routeMetadata(context, {
              providerRoomId: event.providerRoomId,
              providerThreadId: event.providerThreadId
            })
          },
          messageContext
        )
      })
      appendMessageContextHistory(history, row.metadata)
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
    const history = await loadMessageContextHistory(conversation.id)
    for (const event of delivery.events) {
      const envelope = payloadEnvelope(event)
      const actor = actorFromEnvelope(envelope)
      const room = roomFromEnvelope(envelope)
      const sentAt = sentAtFromEnvelope(envelope, event)
      const messageContext = buildMessageContextMetadata({ actor, room, sentAt }, history)
      const row = await this.conversations.appendMessage({
        conversationId: conversation.id,
        role: 'im_ambient',
        kind: 'normal',
        content: textContent(messageText(envelope)),
        eventSource: envelope.source,
        eventId: event.providerEventId,
        metadata: mergeMessageContextMetadata(
          {
            actor,
            provider_refs: providerRefs({
              eventId: event.providerEventId,
              providerMessageId: event.providerMessageId,
              providerRoomId: event.providerRoomId,
              providerThreadId: event.providerThreadId
            }),
            route: routeMetadata(context, {
              providerRoomId: event.providerRoomId,
              providerThreadId: event.providerThreadId
            })
          },
          messageContext
        )
      })
      appendMessageContextHistory(history, row.metadata)
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

  private startGeneration(input: RunGenerationInput): void {
    void this.runGeneration(input).catch(error => {
      logger.error({ error, conversationId: input.conversationId }, 'AI agent generation failed')
    })
  }

  private async runGeneration(input: RunGenerationInput): Promise<GenerationResult> {
    const triggerMessageId = input.triggerMessageId ?? (await this.latestTriggerMessageId(input.conversationId))
    if (!triggerMessageId) return { status: 'failed', enqueuedOutput: false }
    const lease = input.leaseId
      ? { leaseId: input.leaseId }
      : await this.conversations.acquireGenerationLease({
          conversationId: input.conversationId,
          triggerMessageId
        })
    if (!lease) return { status: 'fenced', enqueuedOutput: false }

    // Middle compaction tier: have the renderer clear old re-derivable tool results
    // once the model-bound context reaches the same threshold full compaction uses,
    // so the cheap (no-LLM) pass runs first and may obviate the summary below.
    const microcompactOptions =
      input.profile.compression.microcompactEnabled && input.profile.primaryModel.model.contextWindow > 0
        ? {
            microcompact: {
              keepRecent: input.profile.compression.microcompactKeepRecent,
              triggerTokens: input.profile.primaryModel.model.contextWindow - input.profile.compression.reserveTokens
            }
          }
        : undefined

    const todoStore = await this.loadTodoStore(input.conversationId)
    const clarifyRoomId = input.providerRoomId ?? input.providerThreadId ?? ''
    const binding: ClarifyRunBinding = {
      conversationId: input.conversationId,
      leaseId: lease.leaseId,
      agentUid: input.context.agentUid,
      bindingName: input.context.bindingName,
      providerRealmId: input.context.providerRealmId,
      providerRoomId: clarifyRoomId,
      providerThreadId: input.providerThreadId ?? clarifyRoomId,
      triggerMessageId,
      cardCapable: adapterSupportsCapability(input.context.adapter, 'outbound', 'card'),
      outbox: input.context.outbox,
      scheduleOutboxDrain: input.context.scheduleOutboxDrain
    }
    const activeTools = this.buildActiveToolsForRun(binding, todoStore, {
      disableInteractiveTools: input.disableInteractiveTools
    })
    const systemPrompt = await buildAgentSystemPrompt(input.context.agentUid)

    let rendered = await this.renderer.render(input.conversationId, microcompactOptions)
    // shouldCompact preflight (ported from AgentHarness threshold check): if the rebuilt context already
    // exceeds the model window minus the reserve, compress first so we don't burn a doomed provider call.
    // Best-effort; the provider context-overflow retry below remains the safety net.
    const estimatedRequestTokens = estimateGenerationContextTokens(rendered.messages, systemPrompt, activeTools)
    if (
      input.llmTurnKind !== 'overflow_retry' &&
      input.profile.primaryModel.model.contextWindow > 0 &&
      hasUsefulThresholdCompaction({
        contextWindow: input.profile.primaryModel.model.contextWindow,
        keepRecentTokens: input.profile.compression.keepRecentTokens,
        messages: rendered.messages,
        requestTokens: estimatedRequestTokens,
        reserveTokens: input.profile.compression.reserveTokens
      }) &&
      shouldCompact(estimatedRequestTokens, input.profile.primaryModel.model.contextWindow, {
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
        rendered = await this.renderer.render(input.conversationId, microcompactOptions)
      } catch (error) {
        logger.error({ error, conversationId: input.conversationId }, 'AI agent threshold compaction failed')
      }
    }
    const abortController = new AbortController()
    const abortFromParent = () => abortController.abort(input.abortSignal?.reason)
    if (input.abortSignal?.aborted) abortFromParent()
    else input.abortSignal?.addEventListener('abort', abortFromParent, { once: true })
    const stream = this.buildGenerationStreamingSink(input, lease.leaseId)
    const recorder = new GenerationTrajectoryRecorder(
      input,
      lease.leaseId,
      triggerMessageId,
      rendered,
      this.conversations
    )
    const runContext: GenerationRunContext = {
      abortController,
      abortFromParent,
      input,
      leaseId: lease.leaseId,
      recorder,
      triggerMessageId
    }
    let outcome: RunOutcome
    try {
      const agent = await this.buildGenerationAgent({
        activeTools,
        input,
        recorder,
        rendered,
        stream,
        systemPrompt,
        todoStore
      })
      this.registry.set({
        conversationId: input.conversationId,
        leaseId: lease.leaseId,
        triggerMessageId,
        agent,
        abortController,
        startedAt: new Date()
      })
      outcome = await this.runGenerationAgent({
        abortController,
        agent,
        input,
        leaseId: lease.leaseId,
        stream
      })
    } catch (error) {
      outcome = {
        kind: 'failed',
        aborted: abortController.signal.aborted,
        error
      }
    }
    try {
      return await this.finishGenerationRun(runContext, outcome)
    } finally {
      input.abortSignal?.removeEventListener('abort', abortFromParent)
    }
  }

  private buildGenerationStreamingSink(input: RunGenerationInput, leaseId: string): GenerationStreamingSink {
    // Live streaming-card sink (CardKit). Created lazily on the first non-empty
    // answer text so a thinking-only or instantly-failing turn leaves no empty card.
    const streamingCapable =
      Boolean(input.providerThreadId) &&
      adapterSupportsCapability(input.context.adapter, 'outbound', 'streaming') &&
      typeof input.context.adapter.beginStreamingCard === 'function'
    const outboundKey = `ai-agent-stream:${input.conversationId}:${leaseId}`
    let card: ExternalGatewayStreamingCardHandle | undefined
    let cardStart: Promise<void> | undefined
    let cardFailed = false
    let latestText = ''
    const ensureCard = (): void => {
      if (cardFailed || card || cardStart) return
      cardStart = input.context.adapter.beginStreamingCard!({
        threadId: input.providerThreadId!,
        idempotencyKey: idempotencyKeyFromOutboundKey(outboundKey)
      })
        .then(handle => {
          card = handle
          void handle.update(latestText)
        })
        .catch(() => {
          cardFailed = true
        })
    }

    return {
      onStreamingText: streamingCapable
        ? (fullText: string) => {
            if (!fullText) return
            latestText = fullText
            if (card) {
              void card.update(fullText)
              return
            }
            ensureCard()
          }
        : undefined,
      finalize: async (assistant, text) => {
        if (cardStart) await cardStart.catch(() => {})
        return card ? this.finalizeStreamingCard(card, assistant, text, outboundKey) : undefined
      }
    }
  }

  private async buildGenerationAgent(input: {
    activeTools: AgentTool<any>[]
    input: RunGenerationInput
    recorder: GenerationTrajectoryRecorder
    rendered: RenderedAiAgentContext
    stream: GenerationStreamingSink
    systemPrompt: string
    todoStore: TodoStore
  }): Promise<Agent> {
    const profileOptions = input.input.profile.primaryModel.options
    const agent = new Agent({
      initialState: {
        systemPrompt: input.systemPrompt,
        messages: input.rendered.messages,
        model: input.input.profile.primaryModel.model,
        thinkingLevel: input.input.profile.primaryModel.config.reasoning ?? 'medium',
        tools: input.activeTools
      },
      // core's low-level Agent has no `streamOptions`: forward curated provider request options via a
      // streamFn wrapper, and pass the harness `convertToLlm` so compaction-summary messages reach the model
      // (the Agent's default convertToLlm would drop them).
      convertToLlm,
      toolExecution: 'parallel',
      // Iteration budget + graceful summary, and a one-shot nudge when the model
      // returns an empty reply right after tools (instead of ending the run silently).
      maxTurns: MAX_GENERATION_TURNS,
      nudgeOnEmptyAfterTools: true,
      onStreamingText: input.stream.onStreamingText,
      // Context transform hook (AgentHarness 'context' event) — extension point for in-run context shaping.
      transformContext: (messages, signal) => this.transformGenerationContext(messages, input.todoStore, signal),
      shouldStopAfterTurn: context => this.shouldStopAfterGenerationTurn(context),
      // Tool call policy hooks (AgentHarness tool_call / tool_result) — only wired when tools are active.
      beforeToolCall:
        input.activeTools.length > 0 ? (toolContext, signal) => this.beforeToolCall(toolContext, signal) : undefined,
      afterToolCall:
        input.activeTools.length > 0 ? (toolContext, signal) => this.afterToolCall(toolContext, signal) : undefined,
      beforeLlmCall: (llmContext, _signal) => input.recorder.beforeLlmCall(llmContext),
      // Provider request policy + observability (AgentHarness stream options + before/after provider hooks).
      streamFn: (model, context, options) => {
        const llmTurnId = options?.metadata?.llm_turn_id
        const providerObservation = input.recorder.providerObservation(llmTurnId)
        return streamSimple(model, context, {
          ...options,
          ...profileOptions,
          metadata: {
            ...options?.metadata,
            conversation_id: input.input.conversationId
          },
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
      }
    })
    agent.subscribe(async event => {
      if (event.type === 'turn_end') await input.recorder.finishTurn(event.message, event.toolResults)
    })
    const todoProgress = new Map<string, TodoProgressState>()
    agent.subscribe(async event => {
      await this.handleTodoProgressEvent(input.input, event, todoProgress)
    })
    return agent
  }

  private async runGenerationAgent(input: {
    abortController: AbortController
    agent: Agent
    input: RunGenerationInput
    leaseId: string
    stream: GenerationStreamingSink
  }): Promise<RunOutcome> {
    if (input.abortController.signal.aborted) input.agent.abort()
    else input.abortController.signal.addEventListener('abort', () => input.agent.abort(), { once: true })
    await input.agent.continue()
    const assistant = [...input.agent.state.messages].reverse().find(message => message.role === 'assistant') as
      | AssistantMessage
      | undefined
    if (!assistant) return { kind: 'no_assistant' }

    if (!(await this.conversations.generationCanCommit(input.input.conversationId, input.leaseId))) {
      return {
        kind: 'fenced',
        assistant
      }
    }

    if (
      assistant.stopReason === 'error' &&
      isContextOverflow(assistant, input.input.profile.primaryModel.model.contextWindow)
    ) {
      const attempts = input.input.overflowAttempts ?? 0
      if (attempts < input.input.profile.compression.maxOverflowRetries) {
        return {
          kind: 'overflow_retry',
          assistant,
          attempts
        }
      }
      // Fall through to a visible error row after the configured retry budget is exhausted.
    }

    return {
      kind: 'committed',
      assistant,
      stream: input.stream
    }
  }

  private async finishGenerationRun(run: GenerationRunContext, outcome: RunOutcome): Promise<GenerationResult> {
    let clearLease = false
    let nextGenerationInput: RunGenerationInput | undefined
    let result: GenerationResult = { status: 'failed', enqueuedOutput: false }
    try {
      switch (outcome.kind) {
        case 'no_assistant':
          await run.recorder.failOpenTurn('failed', { error: 'Provider did not return an assistant message' })
          clearLease = true
          result = { status: 'failed', enqueuedOutput: false }
          break
        case 'failed':
          await run.recorder.failOpenTurn(outcome.aborted ? 'cancelled' : 'failed', {
            error: errorMessage(outcome.error)
          })
          clearLease = true
          result = { status: outcome.aborted ? 'cancelled' : 'failed', enqueuedOutput: false }
          break
        case 'fenced':
          result = { status: 'fenced', enqueuedOutput: false }
          break
        case 'overflow_retry':
          await this.compression.compress({
            conversationId: run.input.conversationId,
            profile: run.input.profile,
            trigger: 'provider_context_overflow'
          })
          clearLease = true
          nextGenerationInput = {
            ...run.input,
            leaseId: undefined,
            llmTurnKind: 'overflow_retry',
            overflowAttempts: outcome.attempts + 1
          }
          result = { status: 'failed', enqueuedOutput: false }
          break
        case 'committed': {
          const llmTurnId = run.recorder.lastFinishedTurnId
          if (!llmTurnId) {
            await run.recorder.failOpenTurn('failed', { error: 'No completed LLM turn for committed assistant' })
            clearLease = true
            break
          }
          const text = textFromAgentMessage(outcome.assistant).trim()
          const streamedCard = await outcome.stream.finalize(outcome.assistant, text)
          const commit = await this.commitAssistantResult({
            assistant: outcome.assistant,
            bindingName: run.input.context.bindingName,
            conversationId: run.input.conversationId,
            leaseId: run.leaseId,
            llmTurnId,
            providerRoomId: run.input.providerRoomId,
            providerThreadId: run.input.providerThreadId,
            routeMetadata: routeMetadata(run.input.context, {
              providerRoomId: run.input.providerRoomId,
              providerThreadId: run.input.providerThreadId
            }),
            suppressVisibleOutput: run.input.suppressVisibleOutput,
            text,
            triggerMessageId: run.triggerMessageId,
            streamedCard
          })
          if (commit?.enqueuedOutput) run.input.context.scheduleOutboxDrain()
          if (commit?.nextGeneration) {
            nextGenerationInput = {
              ...run.input,
              leaseId: commit.nextGeneration.leaseId,
              providerRoomId: commit.nextGeneration.providerRoomId,
              providerThreadId: commit.nextGeneration.providerThreadId,
              triggerMessageId: commit.nextGeneration.triggerMessageId
            }
          }
          result = {
            status:
              outcome.assistant.stopReason === 'aborted'
                ? 'cancelled'
                : outcome.assistant.stopReason === 'error'
                  ? 'failed'
                  : 'succeeded',
            enqueuedOutput: commit?.enqueuedOutput ?? false
          }
          break
        }
      }
    } catch (error) {
      await run.recorder.failOpenTurn(run.abortController.signal.aborted ? 'cancelled' : 'failed', {
        error: errorMessage(error)
      })
      clearLease = true
      result = { status: run.abortController.signal.aborted ? 'cancelled' : 'failed', enqueuedOutput: false }
    } finally {
      if (run.abortFromParent) run.input.abortSignal?.removeEventListener('abort', run.abortFromParent)
      try {
        if (clearLease) await this.conversations.clearGenerationLease(run.input.conversationId, run.leaseId)
      } finally {
        this.registry.delete(run.input.conversationId, run.leaseId)
      }
    }
    if (nextGenerationInput) this.startGeneration(nextGenerationInput)
    return result
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

  private async finalizeStreamingCard(
    card: ExternalGatewayStreamingCardHandle,
    assistant: AssistantMessage,
    text: string,
    outboundKey: string
  ): Promise<{ messageId: string; cardId: string; outboundKey: string } | undefined> {
    const status = match(assistant.stopReason)
      .with('aborted', () => 'cancelled' as const)
      .with('error', () => 'failed' as const)
      .otherwise(() => 'completed' as const)
    try {
      await card.finish(text || userFacingAssistantErrorText(assistant) || '', status)
    } catch {
      // Best-effort close: a failed PATCH still leaves a delivered card message, so
      // the caller records it as sent rather than double-posting the answer.
    }
    if (status !== 'completed' || text.length === 0 || !card.messageId || !card.cardId) return undefined
    return { messageId: card.messageId, cardId: card.cardId, outboundKey }
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
    suppressVisibleOutput?: boolean
    text: string
    triggerMessageId: string
    streamedCard?: StreamedAssistantCard
  }): Promise<CommitAssistantResult> {
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
        !input.suppressVisibleOutput &&
        input.text.length > 0 &&
        input.assistant.stopReason !== 'error' &&
        input.assistant.stopReason !== 'aborted'
      const outboundKey = input.streamedCard?.outboundKey ?? `ai-agent-final:${assistantMessageId}`
      let nextTriggerMessageId: string | undefined
      let nextProviderRoomId = input.providerRoomId
      let nextProviderThreadId = input.providerThreadId
      const messageContextHistory: MessageContextHistoryItem[] = (
        await tx
          .select({ metadata: AiAgentMessages.metadata })
          .from(AiAgentMessages)
          .where(
            and(
              eq(AiAgentMessages.conversationId, input.conversationId),
              sql`${AiAgentMessages.role} in ('user', 'im_ambient')`,
              sql`${AiAgentMessages.kind} in ('normal', 'introspection')`,
              sql`${AiAgentMessages.metadata}->'transcript_effect' is null`
            )
          )
          .orderBy(asc(AiAgentMessages.createdAt), asc(AiAgentMessages.id))
      ).map(row => ({ metadata: row.metadata }))

      await tx.insert(AiAgentMessages).values({
        id: assistantMessageId,
        agentUid: conversation.agentUid,
        conversationId: input.conversationId,
        role: 'assistant',
        kind: input.assistant.stopReason === 'error' || input.assistant.stopReason === 'aborted' ? 'error' : 'normal',
        status: 'complete',
        content: jsonbParam(
          textContent(
            input.text || userFacingAssistantErrorText(input.assistant) || 'The model did not return a text response.'
          )
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
        // A successful streaming card already delivered the answer as a live card
        // message: record it as sent (drain skips sent rows) so we never double-post.
        // Otherwise enqueue the usual pending post for the outbox to dispatch.
        await tx
          .insert(ExternalGatewayOutbox)
          .values(
            input.streamedCard
              ? {
                  agentUid: conversation.agentUid,
                  bindingName: input.bindingName,
                  providerRoomId,
                  providerThreadId,
                  outboundKey,
                  operation: 'card',
                  finalPayload: jsonbParam(
                    toJsonObject(
                      larkNativeCardPayload(
                        toJsonObject({ type: 'card', data: { card_id: input.streamedCard.cardId } }),
                        input.text
                      )
                    )
                  ),
                  providerMessageId: input.streamedCard.messageId,
                  status: 'sent',
                  idempotencyKey: idempotencyKeyFromOutboundKey(outboundKey),
                  recoveryState: 'not_started'
                }
              : {
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
                }
          )
          .onConflictDoNothing()
      }

      for (const steering of pendingSteering) {
        const messageId = genUUIDv7()
        const marker = steeringMarker(steering)
        const sentAt = dateFromString(steering.created_at) ?? new Date()
        const messageContext = buildMessageContextMetadata({ sentAt }, messageContextHistory)
        const metadata = mergeMessageContextMetadata(
          {
            control: {
              origin: 'steering',
              type: 'steering',
              source_command_event_id: steering.command_event_id,
              command_event_id: steering.command_event_id
            }
          },
          messageContext
        )
        await tx.insert(AiAgentMessages).values({
          id: messageId,
          agentUid: conversation.agentUid,
          conversationId: input.conversationId,
          role: 'user',
          kind: 'introspection',
          status: 'complete',
          content: jsonbParam(textContent(marker)),
          agentMessage: jsonbParam(toJsonObject(createUserMessage(marker, sentAt.getTime()))),
          eventSource: 'ai-agent.command.steer',
          eventId: steering.command_event_id,
          metadata: jsonbParam(metadata)
        })
        appendMessageContextHistory(messageContextHistory, metadata)
        nextTriggerMessageId = messageId
      }

      for (const followup of pendingFollowups) {
        const messageId = genUUIDv7()
        const sentAt = dateFromString(followup.sent_at) ?? new Date(followup.created_at)
        const messageContext = buildMessageContextMetadata(
          {
            actor: followup.actor ?? {},
            room: followup.room,
            sentAt
          },
          messageContextHistory
        )
        const metadata = mergeMessageContextMetadata(
          {
            actor: followup.actor ?? {},
            provider_refs: followup.provider_refs,
            control: { origin: 'followup_or_steer_fallback' }
          },
          messageContext
        )
        await tx.insert(AiAgentMessages).values({
          id: messageId,
          agentUid: conversation.agentUid,
          conversationId: input.conversationId,
          role: 'user',
          kind: 'normal',
          status: 'complete',
          content: jsonbParam(textContent(followup.text)),
          agentMessage: jsonbParam(toJsonObject(createUserMessage(followup.text, sentAt.getTime()))),
          eventSource: followup.event_source,
          eventId: followup.event_id,
          metadata: jsonbParam(metadata)
        })
        appendMessageContextHistory(messageContextHistory, metadata)
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
        assistantMessageId,
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
    // DM -> divider system notice, group -> compact notice card, neither -> plain
    // post (Elixir render_control_notice parity). Surface/caps drive only the
    // operation; the outboundKey stays stable so idempotency is unaffected.
    const surface = context.adapter.isDM?.(event.providerThreadId) ? 'dm' : 'group'
    await context.outbox.enqueuePending({
      agentUid: context.agentUid,
      bindingName: context.bindingName,
      intent: commandFeedbackIntent({
        commandEventId: event.providerEventId,
        providerRoomId: event.providerRoomId,
        providerThreadId: event.providerThreadId,
        text,
        surface,
        caps: {
          dividerCapable: adapterSupportsCapability(context.adapter, 'outbound', 'divider'),
          cardCapable: adapterSupportsCapability(context.adapter, 'outbound', 'card')
        }
      })
    })
    context.scheduleOutboxDrain()
  }

  private async materializeSteering(conversationId: string, steering: PendingSteering) {
    const sentAt = dateFromString(steering.created_at) ?? new Date()
    const history = await loadMessageContextHistory(conversationId)
    const messageContext = buildMessageContextMetadata({ sentAt }, history)
    return this.conversations.appendMessage({
      conversationId,
      role: 'user',
      kind: 'normal',
      content: textContent(steering.text),
      agentMessage: createUserMessage(steering.text, sentAt.getTime()),
      eventSource: 'ai-agent.command.steer',
      eventId: steering.command_event_id,
      metadata: mergeMessageContextMetadata(
        {
          control: {
            origin: 'steer_fallback',
            type: 'steer_fallback',
            source_command_event_id: steering.command_event_id,
            command_event_id: steering.command_event_id
          }
        },
        messageContext
      )
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

function roomFromEnvelope(envelope: ExternalGatewayAgentEnvelope): JsonObject {
  return toJsonObject(envelope.data.room)
}

function actorFromEnvelope(envelope: ExternalGatewayAgentEnvelope): JsonObject {
  const message = envelope.data.message
  const author = message?.author
  return typeof author === 'object' && author !== null && !Array.isArray(author) ? (author as JsonObject) : {}
}

function sentAtFromEnvelope(
  envelope: ExternalGatewayAgentEnvelope,
  event?: ExternalGatewayAgentDelivery['events'][number]
): Date {
  return (
    dateFromString(stringFromMetadata(toJsonObject(envelope.data.message?.metadata ?? {}), ['dateSent'])) ??
    dateFromString(envelope.time) ??
    event?.createdAt ??
    new Date()
  )
}

function dateFromString(value: unknown): Date | undefined {
  if (typeof value !== 'string' || value.length === 0) return undefined
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? undefined : date
}

function routeMetadata(
  context: ExternalGatewayAgentExecutionContext,
  route: { providerRoomId?: string; providerThreadId?: string } = {}
): JsonObject {
  return buildRouteMetadata({
    agentUid: context.agentUid,
    bindingName: context.bindingName,
    providerRealmId: context.providerRealmId,
    providerRoomId: route.providerRoomId,
    providerThreadId: route.providerThreadId
  })
}

function hasOutbound(metadata: JsonObject): boolean {
  const outbound = metadata.outbound
  return isJsonObject(outbound) && typeof outbound.outbound_key === 'string' && outbound.outbound_key.length > 0
}

function assistantLlmTurnFinish(
  message: AssistantMessage,
  providerObservation: JsonObject,
  profile: AiAgentRuntimeProfile
): LlmTurnFinish {
  return {
    status: match(message.stopReason)
      .with('aborted', () => 'cancelled' as const)
      .with('error', () => 'failed' as const)
      .otherwise(() => 'succeeded' as const),
    response: normalizedAssistantResponse(message),
    usage: message.usage as unknown as JsonObject,
    providerMetadata: assistantProviderMetadata(message, providerObservation, profile)
  }
}

function assistantProviderMetadata(
  message: AssistantMessage,
  providerObservation: JsonObject,
  profile: AiAgentRuntimeProfile
): JsonObject {
  return {
    pi_provider: profile.primaryModel.config.piProvider,
    response_id: message.responseId ?? null,
    response_model: message.responseModel ?? null,
    ...providerObservation
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function userFacingAssistantErrorText(message: AssistantMessage): string | undefined {
  if (message.stopReason !== 'error' && message.stopReason !== 'aborted' && !message.errorMessage) return undefined
  if (message.stopReason === 'aborted') return '已停止'
  const raw = message.errorMessage?.trim()
  if (!raw) return '模型服务返回错误，请稍后重试。'
  const classification = classifyLlmError({ message: raw })
  if (classification.kind === 'overflow') {
    return '上下文太长，当前模型装不下这轮请求。请新开会话、压缩历史或减少输入后再试。'
  }
  if (classification.kind === 'rate_limit') return '模型服务暂时限流，请稍后重试。'
  if (classification.kind === 'timeout') return '模型请求超时，请稍后重试。'
  if (classification.kind === 'server') return '模型服务暂时不可用，请稍后重试。'
  if (classification.kind === 'auth') return '模型服务认证失败，请检查模型提供方配置后重试。'
  if (looksLikeRawProviderPayload(raw)) return '模型服务返回错误，请稍后重试。'
  return raw.length <= 240 ? raw : `${raw.slice(0, 237)}...`
}

function looksLikeRawProviderPayload(raw: string): boolean {
  const trimmed = raw.trim()
  return (
    trimmed.startsWith('{') ||
    trimmed.startsWith('[') ||
    trimmed.startsWith('<!DOCTYPE') ||
    trimmed.startsWith('<html') ||
    /request[_ -]?id/i.test(trimmed)
  )
}

function normalizedAssistantResponse(message: AssistantMessage): JsonObject {
  return {
    content: JSON.parse(JSON.stringify(message.content)) as JsonValue,
    stop_reason: message.stopReason,
    error_message: message.errorMessage ?? null,
    response_id: message.responseId ?? null,
    timestamp: typeof message.timestamp === 'number' ? message.timestamp : null
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
