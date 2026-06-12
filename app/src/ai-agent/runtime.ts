import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { Computer } from '@agentbull/bullx-computer'
import {
  isContextOverflow,
  streamSimple,
  type AssistantMessage,
  type ImageContent,
  type TextContent,
  type ToolResultMessage
} from '@earendil-works/pi-ai'
import { match, ms } from '@pleisto/active-support'
import { and, desc, eq, sql } from 'drizzle-orm'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import { logger } from '@/common/logger'
import {
  AiAgentConversations,
  AiAgentLlmTurns,
  AiAgentMessages,
  ExternalRooms,
  ExternalGatewayOutbox,
  ScheduledTasks,
  type JsonObject,
  type JsonValue
} from '@/common/db-schema'
import { appConfigService } from '@/config/app-configure'
import { loadSystemTimezone } from '@/config/system'
import { adapterSupportsCapability } from '@/external-gateway/core/capabilities'
import {
  externalGatewayVisibleOutputStream,
  type ExternalGatewayVisibleOutputEventType
} from '@/external-gateway/core/visible-output-stream'
import { agentChannelConfigKey } from '@/external-gateway/config'
import type {
  ExternalGatewayAgentDelivery,
  ExternalGatewayAgentEnvelope,
  ExternalGatewaySlashCommandStub
} from '@/external-gateway/agent-events'
import { NORMAL_RECEIVE_BATCH_WINDOW_MS } from '@/external-gateway/agent-events'
import type { ExternalGatewayAgentExecutionContext } from '@/external-gateway/agent'
import type { ExternalGatewayStreamingCardHandle } from '@/external-gateway/core/events'
import { commandFeedbackIntent } from './commands'
import { loadAiAgentRuntimeProfile, type AiAgentRuntimeProfile } from './config'
import {
  aiAgentConversationService,
  buildRouteMetadata,
  isActiveGeneration,
  isExpiredGeneration,
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
import { GenerationStallWatchdog } from './generation-watchdog'
import { aiAgentClarifyRegistry, type AiAgentClarifyRegistry, type ClarifyEntry } from './clarify-registry'
import { createClarifyTool, type ClarifyRunBinding } from './tools/clarify-tool'
import { createCheckBackLaterTool } from './tools/check-back-later-tool'
import { createChatHistorySearchTool } from './tools/chat-history-search-tool'
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
import { idempotencyKeyFromOutboundKey, projectVisibleOutbound } from '@/external-gateway/outbox'
import { interactiveOutputCardPayload, larkNativeCardPayload } from '@/external-gateway/interactive-output'
import { AdminAuthPublicBaseUrlConfig } from '@/principals/admin-auth/config'
import { createTodoTool, TodoStore, todoItemsFromToolDetails, type TodoToolDetails } from './tools/todo-tool'
import { buildAgentSystemPrompt, type CurrentChannelContext } from './prompts/system-prompt'
import { createSkillTools } from './library/tools'
import { estimateContextTokensJsonAware } from './token-estimate'
import { classifyLlmError, isRetryableLlmError } from './core/llm-error-classifier'
import {
  appendMessageContextHistory,
  buildMessageContextMetadata,
  loadMessageContextHistory,
  mergeMessageContextMetadata,
  type MessageContextHistoryItem
} from './message-context'
import {
  createReasoningTraceToken,
  REASONING_TRACE_TTL_MS,
  ReasoningTraceRecorder,
  type ReasoningTraceRef
} from './reasoning-trace'

const EXTERNAL_IMAGE_INLINE_LIMIT_BYTES = 8 * 1024 * 1024
const DEFAULT_ADDRESSED_MEDIA_BATCH_WINDOW_MS = Math.ceil(NORMAL_RECEIVE_BATCH_WINDOW_MS * 1.3)
const GENERATION_STALLED_ABORT_REASON = 'generation_stalled'
const DEFAULT_GENERATION_LIVENESS_INTERVAL_MS = ms('60s')
// First transient retry is immediate (a stall already waited out its budget,
// and pi-ai's call-level retry already backed off quick failures); later
// retries pause so a hard outage cannot spin a tight generation loop.
const GENERATION_TRANSIENT_RETRY_DELAY_MS = ms('15s')
// Long-run progress line cadence (the liveness interval checks this clock).
const GENERATION_PROGRESS_LOG_INTERVAL_MS = ms('5m')

export interface AiAgentRuntimeOptions {
  addressedMediaBatchWindowMs?: number
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
  generationLivenessIntervalMs?: number
}

export type ComputerFileReader = (agentUid: string, path: string, signal?: AbortSignal) => Promise<Buffer | null>

type RunGenerationInput = {
  abortSignal?: AbortSignal
  ambientIntervention?: boolean
  context: ExternalGatewayAgentExecutionContext
  conversationId: string
  disableInteractiveTools?: boolean
  leaseId?: string
  llmTurnKind?: AiAgentLlmTurnKind
  overflowAttempts?: number
  transientAttempts?: number
  profile: AiAgentRuntimeProfile
  providerRoomId?: string
  providerThreadId?: string
  requesterExternalId?: string | null
  requesterPrincipalUid?: string | null
  suppressVisibleOutput?: boolean
  triggerMessageId?: string
}

interface GenerationRunContext {
  abortController: AbortController
  abortFromParent?: () => void
  input: RunGenerationInput
  leaseId: string
  recorder: GenerationTrajectoryRecorder
  reasoningTrace?: PreparedReasoningTrace
  triggerMessageId: string
}

interface StreamedAssistantCard {
  cardId: string
  messageId: string
  outboundKey: string
}

interface StreamedCardProjection {
  messageId: string
  providerRoomId: string
  providerThreadId: string
  raw: JsonObject
  text: string
}

interface GenerationStreamingSink {
  onStreamingText?: (fullText: string) => void
  updateStatus(statusText: string): boolean
  finalize(assistant: AssistantMessage, text: string): Promise<StreamedAssistantCard | undefined>
  /** Close the live visible-output mirror for a run that did not commit. */
  closeFailed(reason: string): void
}

interface PreparedReasoningTrace {
  recorder: ReasoningTraceRecorder
  ref(): ReasoningTraceRef
  traceUrl?: string
}

interface TodoProgressState {
  args: unknown
  delivery: 'streaming-card' | 'message'
  outboundKey?: string
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
      streamedCardProjection?: StreamedCardProjection
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
  private callIndex: number
  private readonly startCallIndex: number
  private openTurnId?: string
  private openTurnCallIndex?: number
  private openTurnStartedAtMs?: number
  private readonly messageRefs = new WeakMap<object, JsonValue>()
  private readonly providerObservations = new Map<string, JsonObject>()
  private previousToolsSnapshot?: string
  public lastFinishedTurnId?: string

  constructor(
    private readonly input: RunGenerationInput,
    private readonly leaseId: string,
    private readonly triggerMessageId: string,
    private readonly rendered: RenderedAiAgentContext,
    private readonly conversations: AiAgentConversationService,
    startCallIndex = 0
  ) {
    this.callIndex = startCallIndex
    this.startCallIndex = startCallIndex
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
    requestPatches.push({
      type: 'llm_request',
      reason: this.input.llmTurnKind ?? 'generation',
      system_prompt: context.llmContext.systemPrompt ?? null,
      messages: toJsonValue(context.llmMessages)
    })
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
    this.openTurnCallIndex = callIndex
    this.openTurnStartedAtMs = Date.now()
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
    this.openTurnCallIndex = undefined
    this.openTurnStartedAtMs = undefined
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
    this.openTurnCallIndex = undefined
    this.openTurnStartedAtMs = undefined
  }

  /** Calls issued by this run so far (excludes turns inherited via crash recovery). */
  get callsStarted(): number {
    return this.callIndex - this.startCallIndex
  }

  /** The in-flight LLM call, if any — progress-log introspection for "wedged or just long". */
  openLlmTurn(): { llmTurnId: string; callIndex: number; runningForMs: number } | undefined {
    if (!this.openTurnId || this.openTurnCallIndex === undefined || this.openTurnStartedAtMs === undefined) {
      return undefined
    }
    return {
      llmTurnId: this.openTurnId,
      callIndex: this.openTurnCallIndex,
      runningForMs: Date.now() - this.openTurnStartedAtMs
    }
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

function todoResultIsTerminal(result: ToolResultMessage): boolean {
  const todos = todoItemsFromToolDetails(result.details) ?? todoItemsFromToolContent(result.content)
  if (!todos || todos.length === 0) return false
  return todos.every(item => {
    if (!isJsonObject(item)) return false
    return item.status === 'completed' || item.status === 'cancelled'
  })
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

function reasoningTraceStorageRef(ref: ReasoningTraceRef) {
  return {
    binding_name: ref.bindingName,
    expires_at: ref.expiresAt,
    trace_id: ref.traceId,
    ...(ref.providerRoomId ? { provider_room_id: ref.providerRoomId } : {}),
    ...(ref.providerThreadId ? { provider_thread_id: ref.providerThreadId } : {}),
    ...(ref.traceUrl ? { trace_url: ref.traceUrl } : {})
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
  private readonly addressedMediaTimers = new Map<string, ReturnType<typeof setTimeout>>()
  private readonly addressedMediaBatchWindowMs: number
  private readonly tools = new Map<string, AgentTool<any>>()
  private activeToolNames: string[] = []
  private readonly clarify: AiAgentClarifyRegistry
  private readonly clarifyTimeoutMs?: number
  private readonly generationLivenessIntervalMs: number
  private clarifyFactory?: (binding: ClarifyRunBinding) => AgentTool<any>
  private computerFactory?: (binding: ClarifyRunBinding) => AgentTool<any>[]
  private computerDeps?: ComputerToolsDeps
  private computerFileReader?: ComputerFileReader
  private readonly computerSessions = new Map<string, Promise<Computer>>()
  private chatRecallFactory?: (binding: ClarifyRunBinding) => AgentTool<any>

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
    this.generationLivenessIntervalMs = options.generationLivenessIntervalMs ?? DEFAULT_GENERATION_LIVENESS_INTERVAL_MS
    this.addressedMediaBatchWindowMs = options.addressedMediaBatchWindowMs ?? DEFAULT_ADDRESSED_MEDIA_BATCH_WINDOW_MS
  }

  stop(): void {
    for (const timer of this.ambientTimers) clearTimeout(timer)
    this.ambientTimers.clear()
    for (const timer of this.addressedMediaTimers.values()) clearTimeout(timer)
    this.addressedMediaTimers.clear()
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
            registry: this.clarify,
            timeoutMs: this.clarifyTimeoutMs
          })
      : undefined
  }

  /** Enable/disable the run-bound computer tools (terminal/process/read_file/patch). */
  setComputerEnabled(enabled: boolean, deps: ComputerToolsDeps): void {
    this.computerFactory = enabled ? binding => createComputerTools(binding, deps) : undefined
    this.computerDeps = enabled ? deps : undefined
    this.computerFileReader = enabled
      ? (agentUid, path, signal) => this.readComputerFile(agentUid, path, signal)
      : undefined
    if (!enabled) this.computerSessions.clear()
  }

  /** Override computer-backed file reads for tests or embedders that provide their own file transport. */
  setComputerFileReader(reader?: ComputerFileReader): void {
    this.computerFileReader = reader
  }

  private async readComputerFile(agentUid: string, path: string, signal?: AbortSignal): Promise<Buffer | null> {
    const computer = await this.getComputerSession(agentUid, signal)
    return computer.readFileToBuffer({ path }, { signal })
  }

  private async getComputerSession(agentUid: string, signal?: AbortSignal): Promise<Computer> {
    if (!this.computerDeps) throw new Error('computer file reader is not configured')
    let promise = this.computerSessions.get(agentUid)
    if (!promise) {
      promise = Computer.getOrCreate({
        agentUid,
        resolveWorker: (uid, resolveSignal) => this.computerDeps!.resolveWorker(uid, resolveSignal),
        signal
      }).catch(error => {
        this.computerSessions.delete(agentUid)
        throw error
      })
      this.computerSessions.set(agentUid, promise)
    }
    return promise
  }

  /** Enable/disable chat history recall. The tool is only registered when pg_search + pgvector are ready. */
  setChatRecallEnabled(enabled: boolean): void {
    this.chatRecallFactory = enabled ? binding => createChatHistorySearchTool(binding) : undefined
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
    if (this.chatRecallFactory) tools.push(this.chatRecallFactory(binding))
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
    // A clarify ask ends the IM turn: the question is this turn's outbound, the
    // user's reply is the next turn's inbound. Never keep generating past it.
    if (context.toolResults.some(result => !result.isError && result.toolName === 'clarify')) return true
    const text = textFromAgentMessage(context.message).trim()
    if (!text) return false
    if (context.toolResults.length === 0) return true
    return context.toolResults.every(
      result => !result.isError && result.toolName === 'todo' && todoResultIsTerminal(result)
    )
  }

  private async handleTodoProgressEvent(
    input: RunGenerationInput,
    leaseId: string,
    stream: GenerationStreamingSink,
    event: AgentEvent,
    states: Map<string, TodoProgressState>
  ): Promise<void> {
    try {
      if (event.type === 'tool_execution_start' && event.toolName === 'todo') {
        await this.startTodoProgress(input, leaseId, stream, event.toolCallId, event.args, states)
      } else if (event.type === 'tool_execution_end' && event.toolName === 'todo') {
        await this.finishTodoProgress(input, leaseId, stream, event.toolCallId, event.result, event.isError, states)
      }
    } catch (error) {
      logger.debug({ error, conversationId: input.conversationId }, 'Todo tool progress update failed')
    }
  }

  private async startTodoProgress(
    input: RunGenerationInput,
    leaseId: string,
    stream: GenerationStreamingSink,
    toolCallId: string,
    args: unknown,
    states: Map<string, TodoProgressState>
  ): Promise<void> {
    const statusText = formatTodoProgressStart(args)
    if (stream.updateStatus(statusText)) {
      const state: TodoProgressState = { args, delivery: 'streaming-card', toolCallId }
      states.set('todo', state)
      states.set(toolCallId, state)
      return
    }

    if (!this.canShowTodoProgress(input)) return
    if (await this.hasPendingSteering(input.conversationId, leaseId)) return
    const providerRoomId = input.providerRoomId ?? input.providerThreadId
    const providerThreadId = input.providerThreadId ?? providerRoomId
    if (!providerRoomId || !providerThreadId) return

    const existing = states.get('todo')
    if (existing?.delivery === 'message' && existing.outboundKey) {
      const state: TodoProgressState = { args, delivery: 'message', outboundKey: existing.outboundKey, toolCallId }
      states.set('todo', state)
      states.set(toolCallId, state)
      await input.context.outbox.enqueuePending({
        agentUid: input.context.agentUid,
        bindingName: input.context.bindingName,
        intent: {
          operation: 'edit',
          outboundKey: `${existing.outboundKey}:start:${toolCallId}`,
          providerRoomId,
          providerThreadId,
          finalPayload: {
            editFallback: 'post',
            targetOutboundKey: existing.outboundKey,
            text: statusText
          }
        }
      })
      input.context.scheduleOutboxDrain()
      return
    }

    const outboundKey = `ai-agent-tool-progress:${input.conversationId}:todo`
    const state: TodoProgressState = { args, delivery: 'message', outboundKey, toolCallId }
    states.set('todo', state)
    states.set(toolCallId, state)
    await input.context.outbox.enqueuePending({
      agentUid: input.context.agentUid,
      bindingName: input.context.bindingName,
      intent: {
        operation: 'post',
        outboundKey,
        providerRoomId,
        providerThreadId,
        finalPayload: { text: statusText }
      }
    })
    input.context.scheduleOutboxDrain()
  }

  private async finishTodoProgress(
    input: RunGenerationInput,
    leaseId: string,
    stream: GenerationStreamingSink,
    toolCallId: string,
    result: unknown,
    isError: boolean,
    states: Map<string, TodoProgressState>
  ): Promise<void> {
    const state = states.get(toolCallId)
    if (!state) return

    if (state.delivery === 'streaming-card') {
      if (await this.hasPendingSteering(input.conversationId, leaseId)) {
        stream.updateStatus('')
        return
      }
      stream.updateStatus(formatTodoProgressEnd(state.args, result, isError))
      states.set('todo', { ...state, args: result })
      return
    }

    if (!state.outboundKey) return
    const providerRoomId = input.providerRoomId ?? input.providerThreadId
    const providerThreadId = input.providerThreadId ?? providerRoomId
    if (!providerRoomId || !providerThreadId) return

    if (await this.hasPendingSteering(input.conversationId, leaseId)) {
      await input.context.outbox.enqueuePending({
        agentUid: input.context.agentUid,
        bindingName: input.context.bindingName,
        intent: {
          operation: 'delete',
          outboundKey: `${state.outboundKey}:steering-delete`,
          providerRoomId,
          providerThreadId,
          finalPayload: {
            targetOutboundKey: state.outboundKey
          }
        }
      })
      input.context.scheduleOutboxDrain()
      return
    }

    await input.context.outbox.enqueuePending({
      agentUid: input.context.agentUid,
      bindingName: input.context.bindingName,
      intent: {
        operation: 'edit',
        outboundKey: `${state.outboundKey}:done`,
        providerRoomId,
        providerThreadId,
        finalPayload: {
          editFallback: 'post',
          targetOutboundKey: state.outboundKey,
          text: formatTodoProgressEnd(state.args, result, isError)
        }
      }
    })
    states.set('todo', { ...state, args: result })
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
    input: RunGenerationInput,
    leaseId: string,
    _signal?: AbortSignal
  ): Promise<AfterToolCallResult | undefined> {
    // Stop the old tool chain at the next tool boundary when a human steering command
    // is waiting. The runtime will materialize the steering note and start the next
    // generation without committing a visible answer from this interrupted turn.
    if (await this.hasPendingSteering(input.conversationId, leaseId)) return { terminate: true }
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
    logger.debug(
      {
        agentUid: context.agentUid,
        bindingName: context.bindingName,
        deliveryMode: first.deliveryMode,
        providerRoomId: first.providerRoomId,
        events: delivery.events.length
      },
      'AI agent delivery accepted'
    )

    if (first.deliveryMode === 'addressed') {
      await this.acceptAddressed(delivery, context, route, profile)
    } else if (first.deliveryMode === 'ambient') {
      await this.acceptAmbient(delivery, context, route, profile)
    } else if (first.deliveryMode === 'command') {
      await this.acceptCommand(delivery, context, route, profile)
    } else if (first.deliveryMode === 'action') {
      await this.acceptAction(delivery, context, profile)
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
    const timezone = await loadSystemTimezone()
    const messageContext = buildMessageContextMetadata({ sentAt: new Date(), timezone }, history)
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
   * Answer a clarify from an interactive card button. First click wins: it takes
   * the registry entry, locks the card (buttons disabled, choice marked), and
   * materializes the choice as the next turn's inbound user message; later
   * clicks (any member) find no entry and are silently ignored.
   */
  private async acceptAction(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentExecutionContext,
    profile: AiAgentRuntimeProfile
  ): Promise<void> {
    const event = delivery.events[0]
    if (!event) return
    const action = (payloadEnvelope(event).data as { action?: { value?: unknown } } | undefined)?.action
    const answer = parseClarifyAnswerValue(action?.value)
    if (!answer) return

    const entry = this.clarify.take(answer.interactionId)
    if (!entry) return
    logger.info(
      {
        agentUid: context.agentUid,
        conversationId: entry.conversationId,
        choiceIndex: answer.choiceIndex,
        eventId: event.providerEventId
      },
      'AI agent clarify answered via card; starting the next turn'
    )
    await this.enqueueClarifyCardLock(context, event, entry, answer)
    context.scheduleOutboxDrain()
    await this.startClarifyAnswerTurn(context, profile, event, entry, answer)
  }

  /**
   * A card click is an inbound answer: persist it as a user message in the
   * asking conversation and start the next turn with it as the trigger. If a
   * generation is already running (the user also typed something), queue it as
   * a followup like any other concurrent inbound.
   */
  private async startClarifyAnswerTurn(
    context: ExternalGatewayAgentExecutionContext,
    profile: AiAgentRuntimeProfile,
    event: ExternalGatewayAgentDelivery['events'][number],
    entry: ClarifyEntry,
    answer: Pick<ClarifyAnswerValue, 'choiceValue' | 'choiceIndex'>
  ): Promise<void> {
    const [conversation] = await DB.select()
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, entry.conversationId))
      .limit(1)
    if (!conversation || conversation.endedAt) return
    const envelope = payloadEnvelope(event)
    const actor = actorFromEnvelope(envelope)
    const sentAt = sentAtFromEnvelope(envelope, event)
    const providerRoomId = event.providerRoomId || entry.providerRoomId
    const providerThreadId = event.providerThreadId || entry.providerThreadId
    const text = answer.choiceValue
    if (isActiveGeneration(conversation.generation) && !isExpiredGeneration(conversation.generation)) {
      await this.conversations.appendPendingFollowup(conversation.id, {
        actor,
        agent_message: toJsonObject(createUserMessage(text, sentAt.getTime())),
        created_at: new Date().toISOString(),
        event_id: event.providerEventId,
        event_source: envelope.source,
        provider_refs: providerRefs({
          eventId: event.providerEventId,
          providerMessageId: event.providerMessageId,
          providerRoomId,
          providerThreadId
        }),
        room: roomFromEnvelope(envelope),
        sent_at: sentAt.toISOString(),
        text
      })
      return
    }
    const history = await loadMessageContextHistory(conversation.id)
    const timezone = await loadSystemTimezone()
    const messageContext = buildMessageContextMetadata(
      { actor, room: roomFromEnvelope(envelope), sentAt, timezone },
      history
    )
    const row = await this.conversations.appendMessage({
      conversationId: conversation.id,
      role: 'user',
      kind: 'normal',
      content: textContent(text),
      agentMessage: createUserMessage(text, sentAt.getTime()),
      eventSource: envelope.source,
      eventId: event.providerEventId,
      metadata: mergeMessageContextMetadata(
        {
          actor,
          control: { origin: 'clarify_card_answer', clarify_tool_call_id: entry.toolCallId },
          provider_refs: providerRefs({
            eventId: event.providerEventId,
            providerMessageId: event.providerMessageId,
            providerRoomId,
            providerThreadId
          }),
          route: routeMetadata(context, { providerRoomId, providerThreadId })
        },
        messageContext
      )
    })
    this.startGeneration({
      context,
      conversationId: conversation.id,
      profile,
      providerRoomId,
      providerThreadId,
      requesterExternalId: externalIdFromActor(actor),
      triggerMessageId: row.id
    })
  }

  private async enqueueClarifyCardLock(
    context: ExternalGatewayAgentExecutionContext,
    event: ExternalGatewayAgentDelivery['events'][number],
    entry: ClarifyEntry,
    answer: Pick<ClarifyAnswerValue, 'choiceValue' | 'choiceIndex'>
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
    if (rebuiltOutboxRows > 0) {
      logger.info(
        { agentUid: context.agentUid, bindingName: context.bindingName, rebuiltOutboxRows },
        'AI agent crash recovery rebuilt missing assistant outbox rows'
      )
      context.scheduleOutboxDrain()
    }

    const conversations = await this.conversations.findRecoverableGenerations(context.agentUid, context.bindingName)

    for (const conversation of conversations) {
      const leaseId = conversation.generation.lease_id
      const triggerMessageId = conversation.generation.trigger_message_id
      if (!leaseId || !triggerMessageId) continue

      // The dead process left its in-flight calls open; settle them before the
      // rerun so the trajectory shows one honest failure, not phantom progress.
      const abandonedTurns = await this.conversations.failAbandonedLlmTurns(
        conversation.id,
        leaseId,
        'process exited during generation'
      )
      logger.info(
        {
          agentUid: context.agentUid,
          conversationId: conversation.id,
          leaseId,
          triggerMessageId,
          abandonedTurns,
          leaseStartedAt: conversation.generation.started_at,
          leaseHeartbeatAt: conversation.generation.heartbeat_at
        },
        'AI agent crash recovery rerunning interrupted generation'
      )
      // The dead attempt's streaming card will never finish; the rerun opens a
      // fresh one, so delete the orphan instead of leaving it spinning.
      await this.enqueueOrphanStreamingCardCleanup(context, conversation)
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
        requesterExternalId: trigger ? externalIdFromActor(toJsonObject(trigger.metadata.actor ?? {})) : undefined,
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

    // Pending clarify question: this inbound message IS the answer. Lock the
    // question card with the mapped choice, then let the message flow down the
    // normal path — it becomes the next turn's trigger like any other message.
    const pendingClarify = this.clarify.take(conversation.id)
    if (pendingClarify) {
      const lastEvent = delivery.events.at(-1)
      if (lastEvent) {
        const mapped = mapAnswer(messageText(payloadEnvelope(lastEvent)), pendingClarify.choices)
        await this.enqueueClarifyCardLock(context, lastEvent, pendingClarify, {
          choiceValue: mapped.text,
          choiceIndex: mapped.choiceIndex ?? -1
        })
        context.scheduleOutboxDrain()
      }
    }

    if (isActiveGeneration(conversation.generation)) {
      if (!isExpiredGeneration(conversation.generation)) {
        for (const event of delivery.events) {
          const envelope = payloadEnvelope(event)
          const sentAt = sentAtFromEnvelope(envelope, event)
          const userMessage = await createUserMessageFromEnvelope(envelope, sentAt, {
            agentUid: event.agentUid,
            readComputerFile: this.computerFileReader
          })
          await this.conversations.appendPendingFollowup(conversation.id, {
            actor: actorFromEnvelope(envelope),
            agent_message: toJsonObject(userMessage),
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
            sent_at: sentAt.toISOString(),
            text: messageText(envelope)
          })
        }
        return
      }
      // The lease outlived its expiry without a heartbeat: the run is wedged (or
      // its process died and recovery died with it). Take the conversation over
      // instead of queueing behind a lease that will never commit.
      await this.takeoverExpiredGeneration(context, conversation, delivery.events[0]?.providerEventId)
    }

    let triggerMessageId: string | undefined
    let hasImmediateTrigger = false
    const history = await loadMessageContextHistory(conversation.id)
    const timezone = await loadSystemTimezone()
    for (const event of delivery.events) {
      const envelope = payloadEnvelope(event)
      const text = messageText(envelope)
      const actor = actorFromEnvelope(envelope)
      const room = roomFromEnvelope(envelope)
      const sentAt = sentAtFromEnvelope(envelope, event)
      const userMessage = await createUserMessageFromEnvelope(envelope, sentAt, {
        agentUid: event.agentUid,
        readComputerFile: this.computerFileReader
      })
      const messageContext = buildMessageContextMetadata({ actor, room, sentAt, timezone }, history)
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
      if (!isAttachmentOnlyContextMessage(envelope)) hasImmediateTrigger = true
    }

    const anchor = delivery.events.at(-1)
    if (triggerMessageId && anchor) {
      const anchorActor = actorFromEnvelope(payloadEnvelope(anchor))
      const generationInput = {
        context,
        conversationId: conversation.id,
        profile,
        providerRoomId: anchor.providerRoomId,
        providerThreadId: anchor.providerThreadId,
        requesterExternalId: externalIdFromActor(anchorActor),
        triggerMessageId
      } satisfies RunGenerationInput
      if (hasImmediateTrigger) {
        this.cancelAddressedMediaTrigger(conversation.id)
        this.startGeneration(generationInput)
      } else {
        this.scheduleAddressedMediaTrigger(generationInput)
      }
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
    const timezone = await loadSystemTimezone()
    for (const event of delivery.events) {
      const envelope = payloadEnvelope(event)
      const actor = actorFromEnvelope(envelope)
      const room = roomFromEnvelope(envelope)
      const sentAt = sentAtFromEnvelope(envelope, event)
      const messageContext = buildMessageContextMetadata({ actor, room, sentAt, timezone }, history)
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
    this.cancelAddressedMediaTrigger(conversation.id)

    if (command.name === 'new') {
      await this.registry.abortAndWait(conversation.id, 'new_session')
      this.clarify.clear(conversation.id)
      const nextConversation = await this.conversations.rolloverConversation(route, 'new_session', DB, {
        sourceEventId: event.providerEventId
      })
      await this.enqueueFeedback(context, event, 'New conversation')
      const nextText = command.argsText.trim()
      if (nextText) {
        const actor = actorFromEnvelope(envelope)
        const room = roomFromEnvelope(envelope)
        const sentAt = sentAtFromEnvelope(envelope, event)
        const history = await loadMessageContextHistory(nextConversation.id)
        const timezone = await loadSystemTimezone()
        const messageContext = buildMessageContextMetadata({ actor, room, sentAt, timezone }, history)
        const row = await this.conversations.appendMessage({
          conversationId: nextConversation.id,
          role: 'user',
          kind: 'normal',
          content: textContent(nextText),
          agentMessage: createUserMessage(nextText, sentAt.getTime()),
          eventSource: envelope.source,
          eventId: event.providerEventId,
          metadata: mergeMessageContextMetadata(
            {
              actor,
              control: {
                origin: 'new',
                type: 'new_with_message',
                source_command_event_id: event.providerEventId,
                command_event_id: event.providerEventId
              },
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
        this.startGeneration({
          context,
          conversationId: nextConversation.id,
          profile,
          providerRoomId: event.providerRoomId,
          providerThreadId: event.providerThreadId,
          requesterExternalId: externalIdFromActor(actor),
          triggerMessageId: row.id
        })
      }
      return
    }

    if (command.name === 'stop') {
      // Fence first so a delayed provider response cannot commit after the stop.
      const wasActive = isActiveGeneration(conversation.generation)
      await this.conversations.cancelGeneration(conversation.id, 'stop', event.providerEventId)
      await this.registry.abortAndWait(conversation.id, 'stop')
      this.clarify.clear(conversation.id)
      const timezone = await loadSystemTimezone()
      if (wasActive) await this.materializeStop(conversation.id, event, timezone)
      await this.enqueueFeedback(context, event, 'Stopped.')
      // /stop kills the running task, not the questions that queued behind it
      // (often from other people in the room). Materialize them after the
      // cancellation note and answer them in a fresh turn.
      const resume = await this.materializeCancelledGenerationQueues(conversation.id, timezone)
      if (resume) {
        this.startGeneration({
          context,
          conversationId: conversation.id,
          profile,
          providerRoomId: resume.providerRoomId ?? event.providerRoomId,
          providerThreadId: resume.providerThreadId ?? event.providerThreadId,
          triggerMessageId: resume.triggerMessageId
        })
      }
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
        await this.enqueueFeedback(context, event, 'Steering queued')
      } else {
        const row = await this.materializeSteering(conversation.id, steering, await loadSystemTimezone())
        await this.enqueueFeedback(context, event, 'Steering queued')
        this.startGeneration({
          context,
          conversationId: conversation.id,
          profile,
          providerRoomId: event.providerRoomId,
          providerThreadId: event.providerThreadId,
          requesterExternalId: externalIdFromActor(actorFromEnvelope(envelope)),
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
      await this.enqueueFeedback(context, event, finalText)
      return
    }

    if (command.name === 'retry') {
      if (isActiveGeneration(conversation.generation)) {
        await this.enqueueFeedback(context, event, 'Still running')
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
    const settled = this.runGeneration(input).then(
      () => undefined,
      error => {
        logger.error({ error, conversationId: input.conversationId }, 'AI agent generation failed')
      }
    )
    input.context.trackSettled?.(settled)
  }

  private scheduleAddressedMediaTrigger(input: RunGenerationInput): void {
    this.cancelAddressedMediaTrigger(input.conversationId)
    const timer = setTimeout(() => {
      this.addressedMediaTimers.delete(input.conversationId)
      void this.startDelayedAddressedMediaGeneration(input)
    }, this.addressedMediaBatchWindowMs)
    this.addressedMediaTimers.set(input.conversationId, timer)
  }

  private cancelAddressedMediaTrigger(conversationId: string): void {
    const timer = this.addressedMediaTimers.get(conversationId)
    if (!timer) return
    clearTimeout(timer)
    this.addressedMediaTimers.delete(conversationId)
  }

  private async startDelayedAddressedMediaGeneration(input: RunGenerationInput): Promise<void> {
    const [conversation] = await DB.select()
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, input.conversationId))
      .limit(1)
    if (!conversation || conversation.endedAt || isActiveGeneration(conversation.generation)) return
    this.startGeneration(input)
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
    const generationStartedAt = Date.now()
    logger.info(
      {
        agentUid: input.context.agentUid,
        conversationId: input.conversationId,
        leaseId: lease.leaseId,
        triggerMessageId,
        llmTurnKind: input.llmTurnKind ?? 'generation',
        model: input.profile.primaryModel.model.id,
        stallTimeoutMs: input.profile.generation.stallTimeoutMs,
        ...(input.transientAttempts ? { transientAttempt: input.transientAttempts } : {}),
        ...(input.overflowAttempts ? { overflowAttempt: input.overflowAttempts } : {})
      },
      'AI agent generation started'
    )

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
      requesterExternalId: input.requesterExternalId,
      requesterPrincipalUid: input.requesterPrincipalUid,
      triggerMessageId,
      cardCapable: adapterSupportsCapability(input.context.adapter, 'outbound', 'card'),
      outbox: input.context.outbox,
      scheduleOutboxDrain: input.context.scheduleOutboxDrain
    }
    const activeTools = this.buildActiveToolsForRun(binding, todoStore, {
      disableInteractiveTools: input.disableInteractiveTools
    })
    const [conversationStartedAt, currentChannel] = await Promise.all([
      this.conversationStartedAt(input.conversationId),
      this.currentChannelContext(input, triggerMessageId)
    ])
    const systemPrompt = await buildAgentSystemPrompt(input.context.agentUid, DB, {
      chatRecallEnabled: activeTools.some(tool => tool.name === 'chat_history_search'),
      conversationStartedAt,
      currentChannel
    })

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
    const reasoningTrace = await this.prepareReasoningTrace(input, lease.leaseId)
    const stream = this.buildGenerationStreamingSink(input, lease.leaseId, reasoningTrace?.traceUrl)
    // A handed-in lease (crash recovery, steer cutover) may already own recorded
    // turns; continue its call_index sequence instead of colliding with it.
    const startCallIndex = input.leaseId
      ? await this.conversations.nextLlmTurnCallIndex(input.conversationId, lease.leaseId)
      : 0
    const recorder = new GenerationTrajectoryRecorder(
      input,
      lease.leaseId,
      triggerMessageId,
      rendered,
      this.conversations,
      startCallIndex
    )
    const runContext: GenerationRunContext = {
      abortController,
      abortFromParent,
      input,
      leaseId: lease.leaseId,
      recorder,
      reasoningTrace,
      triggerMessageId
    }
    let outcome: RunOutcome
    try {
      const agent = await this.buildGenerationAgent({
        activeTools,
        input,
        leaseId: lease.leaseId,
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
      // Two independent liveness signals:
      // 1. Lease heartbeat = "this process still owns the run" — a wall-clock
      //    interval, deliberately blind to stream progress, because a healthy
      //    long-thinking model may stream nothing for tens of minutes. Lease
      //    expiry therefore always means the owning process died, and the
      //    expired-lease takeover can never kill a healthy silent run.
      // 2. Stall watchdog = "the provider stream/tool is still alive" — agent
      //    events reset it; silence beyond the (reasoning-sized) budget aborts
      //    the run, which finishGenerationRun answers with a transient retry.
      //    The SDK timeout only covers time-to-response-headers, so a stream
      //    wedged on a half-open connection would otherwise hang forever.
      const watchdog = new GenerationStallWatchdog({
        stallTimeoutMs: input.profile.generation.stallTimeoutMs,
        streamGapTimeoutMs: input.profile.generation.streamGapTimeoutMs,
        onStall: (silentForMs, phase) => {
          logger.warn(
            {
              agentUid: input.context.agentUid,
              conversationId: input.conversationId,
              leaseId: lease.leaseId,
              silentForMs,
              phase,
              stallTimeoutMs: input.profile.generation.stallTimeoutMs,
              streamGapTimeoutMs: input.profile.generation.streamGapTimeoutMs
            },
            'AI agent generation made no progress within the stall budget; aborting run'
          )
          abortController.abort(GENERATION_STALLED_ABORT_REASON)
        }
      })
      // The progress line is the operator's "wedged or just long?" answer: small
      // silentForMs = the model/tools are visibly working; silentForMs growing
      // toward stallTimeoutMs = the run is about to be aborted and retried.
      let lastProgressLogAt = Date.now()
      const beatLiveness = () => {
        void this.conversations.touchGenerationLiveness(input.conversationId, lease.leaseId).catch(() => {})
        void reasoningTrace?.recorder.touch().catch(() => {})
        if (Date.now() - lastProgressLogAt < GENERATION_PROGRESS_LOG_INTERVAL_MS) return
        lastProgressLogAt = Date.now()
        logger.info(
          {
            agentUid: input.context.agentUid,
            conversationId: input.conversationId,
            leaseId: lease.leaseId,
            elapsedMs: Date.now() - generationStartedAt,
            silentForMs: watchdog.silentForMs(),
            stallTimeoutMs: input.profile.generation.stallTimeoutMs,
            llmCalls: recorder.callsStarted,
            openLlmTurn: recorder.openLlmTurn() ?? null
          },
          'AI agent generation in progress'
        )
      }
      beatLiveness()
      const livenessTimer = setInterval(beatLiveness, this.generationLivenessIntervalMs)
      livenessTimer.unref?.()
      // Content deltas hold the stream to the tight gap budget; boundary events
      // (call start, turn end, tool activity) fall back to the generous one.
      const unsubscribeWatchdog = agent.subscribe(event => {
        if (event.type === 'message_update') watchdog.touchContent()
        else watchdog.touch()
      })
      const unsubscribeReasoningTrace = reasoningTrace
        ? agent.subscribe(event => {
            void reasoningTrace.recorder.recordAgentEvent(event).catch(error => {
              logger.warn(
                { error, conversationId: input.conversationId, leaseId: lease.leaseId },
                'Reasoning trace event append failed; trace view degraded for this run'
              )
            })
          })
        : undefined
      watchdog.start()
      try {
        outcome = await this.runGenerationAgent({
          abortController,
          agent,
          input,
          leaseId: lease.leaseId,
          stream
        })
      } finally {
        watchdog.stop()
        unsubscribeWatchdog()
        unsubscribeReasoningTrace?.()
        clearInterval(livenessTimer)
      }
    } catch (error) {
      outcome = {
        kind: 'failed',
        aborted: abortController.signal.aborted,
        error
      }
    }
    let finished: GenerationResult | undefined
    try {
      finished = await this.finishGenerationRun(runContext, outcome)
      return finished
    } finally {
      input.abortSignal?.removeEventListener('abort', abortFromParent)
      // The committed path emits stream.finished from finalize; every other
      // terminal outcome closes the live mirror (and any open streaming card),
      // with user aborts reported as cancellations rather than failures.
      if (outcome.kind !== 'committed') {
        stream.closeFailed(outcome.kind === 'failed' && outcome.aborted ? 'cancelled' : outcome.kind)
      }
      await reasoningTrace?.recorder.finish(finished?.status).catch(error => {
        logger.warn(
          { error, conversationId: input.conversationId, leaseId: lease.leaseId },
          'Reasoning trace finish append failed'
        )
      })
      logger.info(
        {
          agentUid: input.context.agentUid,
          conversationId: input.conversationId,
          leaseId: lease.leaseId,
          outcome: outcome.kind,
          status: finished?.status,
          durationMs: Date.now() - generationStartedAt,
          llmCalls: recorder.callsStarted
        },
        'AI agent generation finished'
      )
    }
  }

  private buildGenerationStreamingSink(
    input: RunGenerationInput,
    leaseId: string,
    traceUrl?: string
  ): GenerationStreamingSink {
    // Live streaming-card sink (CardKit). Visible-output runs open the card (with
    // the adapter's thinking placeholder) as soon as the generation starts, so
    // tool-heavy runs give feedback before the first answer token. Ambient
    // interventions stay lazy: they usually end without speaking, and an empty
    // card in a group would be noise.
    const streamingCapable =
      Boolean(input.providerThreadId) &&
      !input.suppressVisibleOutput &&
      adapterSupportsCapability(input.context.adapter, 'outbound', 'streaming') &&
      typeof input.context.adapter.beginStreamingCard === 'function'
    const outboundKey = `ai-agent-stream:${input.conversationId}:${leaseId}`
    let card: ExternalGatewayStreamingCardHandle | undefined
    let cardStart: Promise<void> | undefined
    let cardFailed = false
    let latestText = ''
    let latestStatusText = ''
    const ensureCard = (): void => {
      if (cardFailed || card || cardStart) return
      cardStart = input.context.adapter.beginStreamingCard!({
        threadId: input.providerThreadId!,
        traceUrl,
        // Per-attempt key: crash recovery reruns under the same lease, and reusing
        // the dead attempt's key would dedupe the new card message into the old
        // frozen one, leaving the recovered answer on a card no message shows.
        idempotencyKey: idempotencyKeyFromOutboundKey(`${outboundKey}:${genUUIDv7()}`)
      })
        .then(handle => {
          card = handle
          // Durable ref: if this process dies mid-run, recovery/takeover uses it
          // to delete the orphaned "thinking" card nobody will ever finish.
          if (handle.messageId) {
            void this.conversations
              .recordGenerationStreamingCard(input.conversationId, leaseId, {
                provider_message_id: handle.messageId,
                provider_room_id: input.providerRoomId,
                provider_thread_id: input.providerThreadId
              })
              .catch(() => {})
          }
          if (latestStatusText && handle.updateStatus) void handle.updateStatus(latestStatusText)
          if (latestText) void handle.update(latestText)
          else if (latestStatusText && !handle.updateStatus) void handle.update(latestStatusText)
        })
        .catch(() => {
          cardFailed = true
        })
    }
    const updateStatus = (statusText: string): boolean => {
      if (!streamingCapable || input.ambientIntervention === true) return false
      latestStatusText = statusText
      if (card) {
        if (card.updateStatus) void card.updateStatus(statusText)
        else if (statusText && !latestText) void card.update(statusText)
        return true
      }
      ensureCard()
      return true
    }
    const closeCard = (status: 'cancelled' | 'failed'): void => {
      // Preserve streamed partial text; the adapter substitutes its status
      // fallback when nothing was streamed. Chained on cardStart so an in-flight
      // eager create cannot resolve after the close and leave the card spinning.
      const finish = (): void => {
        if (card) void card.finish(latestText, status).catch(() => {})
      }
      if (cardStart) void cardStart.then(finish)
      else finish()
    }

    // Weak live mirror of in-progress output (Redis stream). The webui live view
    // reads it; Redis failures degrade to a log line and never affect the run.
    const visibleKey = { agentUid: input.context.agentUid, sessionId: input.conversationId, streamId: leaseId }
    let visibleSequence = 0
    let visibleClosed = false
    let visibleBroken = false
    let mirroredLength = 0
    const mirror = (
      type: ExternalGatewayVisibleOutputEventType,
      extra: { delta?: string; metadata?: JsonObject } = {}
    ): void => {
      if (visibleBroken || visibleClosed) return
      if (type === 'stream.finished' || type === 'stream.failed') visibleClosed = true
      void externalGatewayVisibleOutputStream
        .append({ ...visibleKey, sequence: visibleSequence++, type, ...extra })
        .catch(error => {
          visibleBroken = true
          logger.warn(
            { error, conversationId: input.conversationId, leaseId },
            'Visible output stream append failed; live view degraded for this run'
          )
        })
    }
    mirror('stream.started')
    if (streamingCapable && input.ambientIntervention !== true) ensureCard()

    return {
      updateStatus,
      onStreamingText: (fullText: string) => {
        if (!fullText) return
        if (fullText.length > mirroredLength) {
          mirror('stream.delta', { delta: fullText.slice(mirroredLength) })
          mirroredLength = fullText.length
        }
        if (!streamingCapable) return
        latestText = fullText
        if (card) {
          void card.update(fullText)
          return
        }
        ensureCard()
      },
      finalize: async (assistant, text) => {
        mirror('stream.finished')
        if (cardStart) await cardStart.catch(() => {})
        return card ? this.finalizeStreamingCard(card, assistant, text, outboundKey) : undefined
      },
      closeFailed: reason => {
        mirror('stream.failed', { metadata: { reason } })
        closeCard(reason === 'failed' || reason === 'no_assistant' ? 'failed' : 'cancelled')
      }
    }
  }

  private async buildGenerationAgent(input: {
    activeTools: AgentTool<any>[]
    input: RunGenerationInput
    leaseId: string
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
      maxTurns: input.input.profile.generation.maxTurns,
      nudgeOnEmptyAfterTools: true,
      onStreamingText: input.stream.onStreamingText,
      // Context transform hook (AgentHarness 'context' event) — extension point for in-run context shaping.
      transformContext: (messages, signal) => this.transformGenerationContext(messages, input.todoStore, signal),
      shouldStopAfterTurn: context => this.shouldStopAfterGenerationTurn(context),
      // Tool call policy hooks (AgentHarness tool_call / tool_result) — only wired when tools are active.
      beforeToolCall:
        input.activeTools.length > 0 ? (toolContext, signal) => this.beforeToolCall(toolContext, signal) : undefined,
      afterToolCall:
        input.activeTools.length > 0
          ? (toolContext, signal) => this.afterToolCall(toolContext, input.input, input.leaseId, signal)
          : undefined,
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
      if (event.type !== 'turn_end') return
      await input.recorder.finishTurn(event.message, event.toolResults)
      const assistant = event.message.role === 'assistant' ? event.message : undefined
      logger.debug(
        {
          agentUid: input.input.context.agentUid,
          conversationId: input.input.conversationId,
          leaseId: input.leaseId,
          llmTurnId: input.recorder.lastFinishedTurnId,
          stopReason: assistant?.stopReason,
          toolCalls: assistant?.content.filter(block => block.type === 'toolCall').length ?? 0,
          emittedText: assistant?.content.some(block => block.type === 'text' && block.text.trim().length > 0) ?? false
        },
        'AI agent LLM turn completed'
      )
    })
    agent.subscribe(event => {
      if (event.type !== 'max_turns_reached') return
      logger.warn(
        {
          agentUid: input.input.context.agentUid,
          conversationId: input.input.conversationId,
          leaseId: input.leaseId,
          maxTurns: event.maxTurns,
          turnCount: event.turnCount,
          triggerMessageId: input.input.triggerMessageId
        },
        'AI agent generation reached max turn budget'
      )
    })
    const todoProgress = new Map<string, TodoProgressState>()
    agent.subscribe(async event => {
      await this.handleTodoProgressEvent(input.input, input.leaseId, input.stream, event, todoProgress)
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
    let retryDelayMs = 0
    let result: GenerationResult = { status: 'failed', enqueuedOutput: false }
    const stallAborted = run.abortController.signal.reason === GENERATION_STALLED_ABORT_REASON
    const scheduleTransientRetry = (cause: string): boolean => {
      if (run.input.ambientIntervention === true) return false
      const attempts = run.input.transientAttempts ?? 0
      if (attempts >= run.input.profile.generation.maxTransientRetries) {
        logger.error(
          {
            agentUid: run.input.context.agentUid,
            conversationId: run.input.conversationId,
            leaseId: run.leaseId,
            attempts,
            maxTransientRetries: run.input.profile.generation.maxTransientRetries,
            cause
          },
          'AI agent generation failed after exhausting transient retries'
        )
        return false
      }
      nextGenerationInput = {
        ...run.input,
        leaseId: undefined,
        llmTurnKind: 'retry_generation',
        transientAttempts: attempts + 1
      }
      retryDelayMs = attempts === 0 ? 0 : GENERATION_TRANSIENT_RETRY_DELAY_MS
      logger.warn(
        {
          agentUid: run.input.context.agentUid,
          conversationId: run.input.conversationId,
          leaseId: run.leaseId,
          attempt: attempts + 1,
          maxTransientRetries: run.input.profile.generation.maxTransientRetries,
          retryDelayMs,
          cause
        },
        'AI agent generation hit a transient provider failure; retrying'
      )
      return true
    }
    try {
      switch (outcome.kind) {
        case 'no_assistant':
          await run.recorder.failOpenTurn('failed', { error: 'Provider did not return an assistant message' })
          clearLease = true
          if (stallAborted) scheduleTransientRetry('stalled_before_first_event')
          result = { status: 'failed', enqueuedOutput: false }
          break
        case 'failed':
          await run.recorder.failOpenTurn(outcome.aborted ? 'cancelled' : 'failed', {
            error: errorMessage(outcome.error)
          })
          clearLease = true
          if (stallAborted || (!outcome.aborted && isRetryableLlmError(outcome.error))) {
            scheduleTransientRetry(stallAborted ? 'stall_abort' : errorMessage(outcome.error))
          }
          result = { status: outcome.aborted ? 'cancelled' : 'failed', enqueuedOutput: false }
          break
        case 'fenced':
          logger.warn(
            {
              agentUid: run.input.context.agentUid,
              conversationId: run.input.conversationId,
              leaseId: run.leaseId
            },
            'AI agent generation fenced by a newer lease; output discarded'
          )
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
          if (outcome.assistant.content.some(block => block.type === 'toolCall')) {
            const steered = await this.materializePendingSteeringAtToolBoundary({
              conversationId: run.input.conversationId,
              leaseId: run.leaseId,
              providerRoomId: run.input.providerRoomId,
              providerThreadId: run.input.providerThreadId,
              timezone: await loadSystemTimezone()
            })
            if (steered) {
              // The interrupted turn never finalizes: close its live mirror and any
              // open streaming card so the steered generation (new lease, new card)
              // takes over cleanly instead of leaving a card spinning forever.
              outcome.stream.closeFailed('steered')
              nextGenerationInput = {
                ...run.input,
                leaseId: steered.leaseId,
                providerRoomId: steered.providerRoomId,
                providerThreadId: steered.providerThreadId,
                triggerMessageId: steered.triggerMessageId,
                transientAttempts: undefined
              }
              result = { status: 'succeeded', enqueuedOutput: false }
              break
            }
          }
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
            reasoningTrace: run.reasoningTrace?.ref(),
            streamedCard,
            timezone: await loadSystemTimezone()
          })
          if (commit?.enqueuedOutput && !commit.streamedCardProjection) run.input.context.scheduleOutboxDrain()
          if (commit?.streamedCardProjection) {
            await this.projectStreamingCardOutbound(run.input.context, commit.streamedCardProjection)
          }
          if (commit?.nextGeneration) {
            nextGenerationInput = {
              ...run.input,
              leaseId: commit.nextGeneration.leaseId,
              providerRoomId: commit.nextGeneration.providerRoomId,
              providerThreadId: commit.nextGeneration.providerThreadId,
              triggerMessageId: commit.nextGeneration.triggerMessageId,
              transientAttempts: undefined
            }
          } else if (
            (outcome.assistant.stopReason === 'error' || outcome.assistant.stopReason === 'aborted') &&
            (stallAborted ||
              (outcome.assistant.stopReason === 'error' && isRetryableLlmError(outcome.assistant.errorMessage)))
          ) {
            // The attempt died of a stall or a transport failure that survived
            // the loop's own one-shot first-turn retry, and produced no
            // user-visible answer and no follow-up chain (queued followups
            // re-render the whole context and inherently retry the ask).
            // User aborts (/stop, /new) are stopReason 'aborted' without the
            // stall reason and never retry.
            scheduleTransientRetry(stallAborted ? 'stall_abort' : (outcome.assistant.errorMessage ?? 'provider error'))
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
    if (nextGenerationInput) {
      const next = nextGenerationInput
      if (retryDelayMs > 0) {
        const timer = setTimeout(() => this.startGeneration(next), retryDelayMs)
        timer.unref?.()
      } else {
        this.startGeneration(next)
      }
    }
    return result
  }

  private async prepareReasoningTrace(
    input: RunGenerationInput,
    leaseId: string
  ): Promise<PreparedReasoningTrace | undefined> {
    if (!this.shouldCreateReasoningTrace(input)) return undefined

    const traceId = leaseId
    const { token } = createReasoningTraceToken({
      agentUid: input.context.agentUid,
      bindingName: input.context.bindingName,
      conversationId: input.conversationId,
      providerRoomId: input.providerRoomId,
      providerThreadId: input.providerThreadId,
      traceId
    })
    const publicBaseUrl = await appConfigService.get(AdminAuthPublicBaseUrlConfig).catch(() => undefined)
    const traceUrl =
      publicBaseUrl && typeof input.context.adapter.authorizeReasoningTraceView === 'function'
        ? new URL(`/traces/reasoning/${encodeURIComponent(token)}`, publicBaseUrl).toString()
        : undefined
    const ref = (): ReasoningTraceRef => ({
      agentUid: input.context.agentUid,
      bindingName: input.context.bindingName,
      conversationId: input.conversationId,
      expiresAt: new Date(Date.now() + REASONING_TRACE_TTL_MS).toISOString(),
      providerRoomId: input.providerRoomId,
      providerThreadId: input.providerThreadId,
      traceId,
      traceUrl
    })
    const recorder = new ReasoningTraceRecorder({
      agentUid: input.context.agentUid,
      conversationId: input.conversationId,
      traceId
    })

    try {
      await recorder.start({
        binding_name: input.context.bindingName,
        provider_room_id: input.providerRoomId ?? null,
        provider_thread_id: input.providerThreadId ?? null
      })
    } catch (error) {
      logger.warn(
        { error, conversationId: input.conversationId, leaseId },
        'Reasoning trace stream unavailable; generation will continue without trace view'
      )
      return undefined
    }

    await this.conversations
      .recordGenerationReasoningTrace(input.conversationId, leaseId, reasoningTraceStorageRef(ref()))
      .catch(error => {
        logger.warn(
          { error, conversationId: input.conversationId, leaseId },
          'Failed to record active generation reasoning trace ref'
        )
      })

    return { recorder, ref, traceUrl }
  }

  private shouldCreateReasoningTrace(input: RunGenerationInput): boolean {
    return (
      Boolean(input.providerThreadId) &&
      !input.suppressVisibleOutput &&
      input.ambientIntervention !== true &&
      adapterSupportsCapability(input.context.adapter, 'outbound', 'streaming') &&
      typeof input.context.adapter.beginStreamingCard === 'function'
    )
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
      requesterExternalId: externalIdFromActor(actorFromEnvelope(payloadEnvelope(event))),
      triggerMessageId
    })
    await this.enqueueFeedback(context, event, 'Retrying')
  }

  private async conversationStartedAt(conversationId: string): Promise<Date | undefined> {
    const [conversation] = await DB.select({ createdAt: AiAgentConversations.createdAt })
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, conversationId))
      .limit(1)
    return conversation?.createdAt
  }

  private async currentChannelContext(
    input: RunGenerationInput,
    triggerMessageId: string
  ): Promise<CurrentChannelContext | undefined> {
    const [trigger] = await DB.select({ metadata: AiAgentMessages.metadata })
      .from(AiAgentMessages)
      .where(and(eq(AiAgentMessages.id, triggerMessageId), eq(AiAgentMessages.conversationId, input.conversationId)))
      .limit(1)
    const triggerMetadata = trigger?.metadata ?? {}
    const controlType = stringFromMetadata(triggerMetadata, ['control', 'type'])

    if (input.llmTurnKind === 'scheduled_task' || controlType === 'scheduled_task') {
      const taskId = stringFromMetadata(triggerMetadata, ['control', 'task_id'])
      return {
        kind: 'scheduled_task',
        id: taskId,
        name: taskId ? await this.scheduledTaskName(taskId) : undefined
      }
    }

    if (input.llmTurnKind === 'checkback_generation' || controlType === 'check_back_later') {
      return {
        kind: 'checkback',
        id: stringFromMetadata(triggerMetadata, ['control', 'checkback_id'])
      }
    }

    const providerRoomId =
      input.providerRoomId ??
      stringFromMetadata(triggerMetadata, ['provider_refs', 'room_id']) ??
      (await this.conversationProviderRoomId(input.conversationId))
    if (!providerRoomId) return undefined

    const [room] = await DB.select({
      id: ExternalRooms.id,
      isDM: ExternalRooms.isDM,
      name: ExternalRooms.name
    })
      .from(ExternalRooms)
      .where(eq(ExternalRooms.id, providerRoomId))
      .limit(1)
    const providerThreadId =
      input.providerThreadId ?? stringFromMetadata(triggerMetadata, ['provider_refs', 'thread_id']) ?? providerRoomId
    const isDM = room?.isDM ?? input.context.adapter.isDM?.(providerThreadId) ?? false
    const name = trimOptionalString(room?.name) ?? (isDM ? actorDisplayName(triggerMetadata.actor) : undefined)

    return {
      bindingName: input.context.bindingName,
      id: providerRoomId,
      kind: isDM ? 'external_dm' : 'external_group',
      name,
      platform: await this.currentChannelPlatform(input.context)
    }
  }

  private async scheduledTaskName(taskId: string): Promise<string | undefined> {
    const [task] = await DB.select({ name: ScheduledTasks.name })
      .from(ScheduledTasks)
      .where(eq(ScheduledTasks.id, taskId))
      .limit(1)
    return trimOptionalString(task?.name)
  }

  private async conversationProviderRoomId(conversationId: string): Promise<string | undefined> {
    const [conversation] = await DB.select({ metadata: AiAgentConversations.metadata })
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, conversationId))
      .limit(1)
    return stringFromMetadata(conversation?.metadata ?? {}, ['route', 'provider_room_id'])
  }

  private async currentChannelPlatform(context: ExternalGatewayAgentExecutionContext): Promise<string | undefined> {
    const adapter = bindingAdapter(context.agent.agent.metadata, context.bindingName)
    if (adapter === 'lark') {
      const config = await appConfigService
        .getByKey(agentChannelConfigKey(context.agentUid, context.bindingName))
        .catch(() => undefined)
      const domain = stringFromMetadata(toJsonObject(config ?? {}), ['domain'])
      return domain === 'lark' ? 'lark' : 'feishu'
    }
    return adapter
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
        ambientIntervention: true,
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
    const finalText = status === 'completed' ? text : userFacingAssistantErrorText(assistant) || text
    let finalTextConfirmed = false
    try {
      const finishResult = await card.finish(finalText, status)
      finalTextConfirmed = finishResult?.finalTextConfirmed ?? true
    } catch (error) {
      logger.warn({ error, outboundKey }, 'Streaming card finish threw; falling back to normal final output')
    }
    if (status !== 'completed' || text.length === 0 || !card.messageId || !card.cardId || !finalTextConfirmed) {
      if (status === 'completed' && text.length > 0 && card.messageId && card.cardId) {
        logger.warn(
          { outboundKey, cardId: card.cardId, messageId: card.messageId },
          'Streaming card final text was not confirmed; falling back to normal final output'
        )
      }
      return undefined
    }
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
    timezone: string
    triggerMessageId: string
    reasoningTrace?: ReasoningTraceRef
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
      let streamedCardProjection: StreamedCardProjection | undefined
      const messageContextHistory = await loadMessageContextHistory(input.conversationId, tx)

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
          ...(input.reasoningTrace ? { reasoning_trace: reasoningTraceStorageRef(input.reasoningTrace) } : {}),
          ...(isVisibleOutput ? { outbound: { outbound_key: outboundKey } } : {}),
          route: input.routeMetadata
        })
      })

      if (isVisibleOutput) {
        const providerRoomId =
          input.providerRoomId ?? stringFromMetadata(conversation.metadata, ['route', 'provider_room_id']) ?? ''
        const providerThreadId = input.providerThreadId ?? input.providerRoomId ?? providerRoomId
        if (input.streamedCard && providerRoomId && providerThreadId) {
          streamedCardProjection = {
            messageId: input.streamedCard.messageId,
            providerRoomId,
            providerThreadId,
            raw: toJsonObject({
              type: 'card',
              data: { card_id: input.streamedCard.cardId },
              message_id: input.streamedCard.messageId
            }),
            text: input.text
          }
        }
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
        nextTriggerMessageId = await this.insertSteeringMarkerRow(tx, {
          agentUid: conversation.agentUid,
          conversationId: input.conversationId,
          messageContextHistory,
          steering,
          timezone: input.timezone
        })
      }

      for (const followup of pendingFollowups) {
        const messageId = genUUIDv7()
        const sentAt = dateFromString(followup.sent_at) ?? new Date(followup.created_at)
        const messageContext = buildMessageContextMetadata(
          {
            actor: followup.actor ?? {},
            room: followup.room,
            sentAt,
            timezone: input.timezone
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
          agentMessage: jsonbParam(
            followup.agent_message ?? toJsonObject(createUserMessage(followup.text, sentAt.getTime()))
          ),
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
        streamedCardProjection,
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

  private async projectStreamingCardOutbound(
    context: ExternalGatewayAgentExecutionContext,
    projection: StreamedCardProjection
  ): Promise<void> {
    try {
      await projectVisibleOutbound({
        adapter: context.adapter,
        agent: context.agent,
        messageId: projection.messageId,
        projection: context.projection,
        raw: projection.raw,
        room: {
          id: projection.providerRoomId,
          isDM: context.adapter.isDM?.(projection.providerThreadId) ?? false,
          roomVisibility: context.adapter.getChannelVisibility?.(projection.providerThreadId) ?? 'unknown'
        },
        text: projection.text,
        threadId: projection.providerThreadId
      })
    } catch (error) {
      logger.error(
        {
          error,
          agentUid: context.agentUid,
          bindingName: context.bindingName,
          messageId: projection.messageId,
          providerRoomId: projection.providerRoomId,
          providerThreadId: projection.providerThreadId
        },
        'AIAgent failed to project streaming card outbound message'
      )
    }
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

  private async hasPendingSteering(conversationId: string, leaseId: string): Promise<boolean> {
    const [conversation] = await DB.select({ generation: AiAgentConversations.generation })
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, conversationId))
      .limit(1)
    if (!conversation || conversation.generation.lease_id !== leaseId || conversation.generation.cancelled_at) {
      return false
    }
    return normalizePendingArray<PendingSteering>(conversation.generation.pending_steering).length > 0
  }

  private async materializePendingSteeringAtToolBoundary(input: {
    conversationId: string
    leaseId: string
    providerRoomId?: string
    providerThreadId?: string
    timezone: string
  }): Promise<NextGeneration | undefined> {
    return DB.transaction(async tx => {
      const [conversation] = await tx
        .select()
        .from(AiAgentConversations)
        .where(eq(AiAgentConversations.id, input.conversationId))
        .for('update')
        .limit(1)
      if (!conversation) return undefined
      if (
        conversation.endedAt ||
        conversation.generation.lease_id !== input.leaseId ||
        conversation.generation.cancelled_at
      ) {
        return undefined
      }

      const pendingSteering = normalizePendingArray<PendingSteering>(conversation.generation.pending_steering)
      if (pendingSteering.length === 0) return undefined

      const messageContextHistory = await loadMessageContextHistory(input.conversationId, tx)

      let nextTriggerMessageId: string | undefined
      for (const steering of pendingSteering) {
        nextTriggerMessageId = await this.insertSteeringMarkerRow(tx, {
          agentUid: conversation.agentUid,
          conversationId: input.conversationId,
          messageContextHistory,
          steering,
          timezone: input.timezone
        })
      }

      if (!nextTriggerMessageId) return undefined
      const nextLeaseId = genUUIDv7()
      await tx
        .update(AiAgentConversations)
        .set({
          generation: jsonbParam(newGenerationLease(nextLeaseId, nextTriggerMessageId)),
          updatedAt: sql`now()`
        })
        .where(eq(AiAgentConversations.id, input.conversationId))

      return {
        leaseId: nextLeaseId,
        providerRoomId: input.providerRoomId,
        providerThreadId: input.providerThreadId,
        triggerMessageId: nextTriggerMessageId
      }
    })
  }

  /** Insert one steering-marker introspection row inside the caller's transaction. */
  private async insertSteeringMarkerRow(
    tx: QueryExecutor,
    input: {
      agentUid: string
      conversationId: string
      messageContextHistory: MessageContextHistoryItem[]
      steering: PendingSteering
      timezone: string
    }
  ): Promise<string> {
    const messageId = genUUIDv7()
    const marker = steeringMarker(input.steering)
    const sentAt = dateFromString(input.steering.created_at) ?? new Date()
    const messageContext = buildMessageContextMetadata(
      { sentAt, timezone: input.timezone },
      input.messageContextHistory
    )
    const metadata = mergeMessageContextMetadata(
      {
        control: {
          origin: 'steering',
          type: 'steering',
          source_command_event_id: input.steering.command_event_id,
          command_event_id: input.steering.command_event_id
        }
      },
      messageContext
    )
    await tx.insert(AiAgentMessages).values({
      id: messageId,
      agentUid: input.agentUid,
      conversationId: input.conversationId,
      role: 'user',
      kind: 'introspection',
      status: 'complete',
      content: jsonbParam(textContent(marker)),
      agentMessage: jsonbParam(toJsonObject(createUserMessage(marker, sentAt.getTime()))),
      eventSource: 'ai-agent.command.steer',
      eventId: input.steering.command_event_id,
      metadata: jsonbParam(metadata)
    })
    appendMessageContextHistory(input.messageContextHistory, metadata)
    return messageId
  }

  private async materializeSteering(conversationId: string, steering: PendingSteering, timezone: string) {
    const sentAt = dateFromString(steering.created_at) ?? new Date()
    const history = await loadMessageContextHistory(conversationId)
    const messageContext = buildMessageContextMetadata({ sentAt, timezone }, history)
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

  /**
   * Best-effort removal of a dead attempt's streaming card — the orphaned
   * "thinking" bubble left when a process died or wedged mid-run. The new
   * attempt opens its own card (per-attempt idempotency key), so the stale one
   * would otherwise spin in the chat forever.
   */
  private async enqueueOrphanStreamingCardCleanup(
    context: ExternalGatewayAgentExecutionContext,
    conversation: typeof AiAgentConversations.$inferSelect
  ): Promise<void> {
    const generation = conversation.generation
    const targetMessageId = generation.streaming_card?.provider_message_id
    if (!targetMessageId || !generation.lease_id) return
    if (!adapterSupportsCapability(context.adapter, 'outbound', 'delete_message')) return
    const providerRoomId =
      generation.streaming_card?.provider_room_id ??
      stringFromMetadata(conversation.metadata, ['route', 'provider_room_id']) ??
      ''
    logger.info(
      {
        agentUid: context.agentUid,
        conversationId: conversation.id,
        leaseId: generation.lease_id,
        targetMessageId
      },
      'AI agent deleting orphaned streaming card from a dead run'
    )
    await context.outbox.enqueuePending({
      agentUid: context.agentUid,
      bindingName: context.bindingName,
      intent: {
        operation: 'delete',
        outboundKey: `ai-agent-stream-cleanup:${conversation.id}:${generation.lease_id}`,
        providerRoomId,
        providerThreadId: generation.streaming_card?.provider_thread_id ?? providerRoomId,
        finalPayload: { targetMessageId }
      }
    })
    context.scheduleOutboxDrain()
  }

  /**
   * Recover a conversation whose generation lease expired without a heartbeat.
   *
   * The lease is cancelled first (scoped to its id, so a just-committed newer
   * lease is left alone), which fences any zombie run out of committing; the
   * in-process run — if one is still wedged on a dead provider call or tool —
   * is then aborted. Queued followups/steering are materialized as transcript
   * rows so the takeover generation sees them; the caller proceeds down the
   * normal trigger path as if no run were active.
   */
  private async takeoverExpiredGeneration(
    context: ExternalGatewayAgentExecutionContext,
    conversation: typeof AiAgentConversations.$inferSelect,
    eventId: string | undefined
  ): Promise<void> {
    const generation = conversation.generation
    logger.warn(
      {
        agentUid: conversation.agentUid,
        conversationId: conversation.id,
        leaseId: generation.lease_id,
        startedAt: generation.started_at,
        heartbeatAt: generation.heartbeat_at,
        expiresAt: generation.expires_at,
        pendingFollowups: normalizePendingArray(generation.pending_followups).length,
        pendingSteering: normalizePendingArray(generation.pending_steering).length
      },
      'AI agent generation lease expired without heartbeat; taking over conversation'
    )
    if (generation.lease_id) {
      await this.conversations.cancelGeneration(conversation.id, 'lease_expired', eventId, generation.lease_id)
    }
    await this.registry.abortAndWait(conversation.id, 'lease_expired')
    this.clarify.clear(conversation.id)
    if (generation.lease_id) {
      await this.conversations.failAbandonedLlmTurns(conversation.id, generation.lease_id, 'generation lease expired')
    }
    await this.enqueueOrphanStreamingCardCleanup(context, conversation)
    await this.materializeCancelledGenerationQueues(conversation.id, await loadSystemTimezone())
  }

  /**
   * Drain a cancelled lease's pending queues into transcript rows. The committed
   * path normally materializes them, but a taken-over lease never commits, and
   * the next `acquireGenerationLease` replaces the generation envelope wholesale
   * — without this step the queued user input would be silently dropped. Row
   * inserts and the queue clear share one transaction; the inbound-event unique
   * index turns a replayed drain into a no-op.
   */
  private async materializeCancelledGenerationQueues(
    conversationId: string,
    timezone: string
  ): Promise<{ triggerMessageId: string; providerRoomId?: string; providerThreadId?: string } | undefined> {
    return DB.transaction(async tx => {
      const [conversation] = await tx
        .select()
        .from(AiAgentConversations)
        .where(eq(AiAgentConversations.id, conversationId))
        .for('update')
        .limit(1)
      if (!conversation || conversation.endedAt) return undefined
      const generation = conversation.generation
      if (!generation.lease_id || !generation.cancelled_at) return undefined
      const pendingSteering = normalizePendingArray<PendingSteering>(generation.pending_steering)
      const pendingFollowups = normalizePendingArray<PendingFollowup>(generation.pending_followups)
      if (pendingSteering.length === 0 && pendingFollowups.length === 0) return undefined
      logger.info(
        {
          agentUid: conversation.agentUid,
          conversationId,
          leaseId: generation.lease_id,
          followups: pendingFollowups.length,
          steering: pendingSteering.length
        },
        'AI agent materializing queued input from a cancelled lease'
      )
      const messageContextHistory = await loadMessageContextHistory(conversationId, tx)
      for (const steering of pendingSteering) {
        await this.insertSteeringMarkerRow(tx, {
          agentUid: conversation.agentUid,
          conversationId,
          messageContextHistory,
          steering,
          timezone
        })
      }
      let resumeTrigger: { triggerMessageId: string; providerRoomId?: string; providerThreadId?: string } | undefined
      for (const followup of pendingFollowups) {
        const sentAt = dateFromString(followup.sent_at) ?? new Date(followup.created_at)
        const messageContext = buildMessageContextMetadata(
          { actor: followup.actor ?? {}, room: followup.room, sentAt, timezone },
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
        const followupMessageId = genUUIDv7()
        await tx
          .insert(AiAgentMessages)
          .values({
            id: followupMessageId,
            agentUid: conversation.agentUid,
            conversationId,
            role: 'user',
            kind: 'normal',
            status: 'complete',
            content: jsonbParam(textContent(followup.text)),
            agentMessage: jsonbParam(
              followup.agent_message ?? toJsonObject(createUserMessage(followup.text, sentAt.getTime()))
            ),
            eventSource: followup.event_source,
            eventId: followup.event_id,
            metadata: jsonbParam(metadata)
          })
          .onConflictDoNothing()
        appendMessageContextHistory(messageContextHistory, metadata)
        resumeTrigger = {
          triggerMessageId: followupMessageId,
          providerRoomId: stringFromMetadata(followup.provider_refs, ['room_id']),
          providerThreadId: stringFromMetadata(followup.provider_refs, ['thread_id'])
        }
      }
      await tx
        .update(AiAgentConversations)
        .set({
          generation: sql`${AiAgentConversations.generation} || ${jsonbParam({
            pending_followups: [],
            pending_steering: []
          })}`,
          updatedAt: sql`now()`
        })
        .where(eq(AiAgentConversations.id, conversationId))
      return resumeTrigger
    })
  }

  private async materializeStop(
    conversationId: string,
    event: ExternalGatewayAgentDelivery['events'][number],
    timezone: string
  ) {
    const envelope = payloadEnvelope(event)
    const sentAt = sentAtFromEnvelope(envelope, event)
    const note = [
      '<task_cancellation>',
      'The user stopped the active generation.',
      'Treat the interrupted task as cancelled.',
      'Do not continue or resume that stopped task in later turns unless the user explicitly asks again.',
      '</task_cancellation>'
    ].join('\n')
    const history = await loadMessageContextHistory(conversationId)
    const messageContext = buildMessageContextMetadata({ sentAt, timezone }, history)
    return this.conversations.appendMessage({
      conversationId,
      role: 'user',
      kind: 'introspection',
      content: textContent(note),
      agentMessage: createUserMessage(note, sentAt.getTime()),
      eventSource: 'ai-agent.command.stop',
      eventId: event.providerEventId,
      metadata: mergeMessageContextMetadata(
        {
          control: {
            origin: 'stop',
            type: 'stop',
            source_command_event_id: event.providerEventId,
            command_event_id: event.providerEventId
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

function isAttachmentOnlyContextMessage(envelope: ExternalGatewayAgentEnvelope): boolean {
  const attachments = envelope.data.message?.attachments
  if (!Array.isArray(attachments) || attachments.length === 0) return false
  return stripAttachmentContextText(messageText(envelope)).length === 0
}

function stripAttachmentContextText(text: string): string {
  return text
    .replace(/<file\b[^>]*\/>/gi, '')
    .replace(/!\[[^\]]*]\([^)]*\)/g, '')
    .replace(/\[\s*(?:document|image)\b[^\]]*?\bsaved at:\s*[^\]]+]/gi, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

async function createUserMessageFromEnvelope(
  envelope: ExternalGatewayAgentEnvelope,
  sentAt: Date,
  options: { agentUid: string; readComputerFile?: ComputerFileReader }
): Promise<AgentMessage> {
  const text = messageText(envelope)
  const imageBlocks = await imageContentBlocksFromEnvelope(envelope, options)
  if (imageBlocks.length === 0) return createUserMessage(text, sentAt.getTime())

  const content: Array<TextContent | ImageContent> = [
    { type: 'text', text: modelTextForInlineImages(text, imageBlocks.length) },
    ...imageBlocks
  ]
  return createUserMessage(content, sentAt.getTime())
}

function modelTextForInlineImages(text: string, imageCount: number): string {
  const cleaned = text
    .replace(/!\[[^\]]*]\([^)]*\)/g, '')
    .replace(/\[\s*image\b[^\]]*?\bsaved at:\s*[^\]]+]/gi, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim()

  if (cleaned) return cleaned
  return imageCount === 1 ? '[Image attached]' : `[${imageCount} images attached]`
}

async function imageContentBlocksFromEnvelope(
  envelope: ExternalGatewayAgentEnvelope,
  options: { agentUid: string; readComputerFile?: ComputerFileReader }
): Promise<ImageContent[]> {
  const attachments = envelope.data.message?.attachments
  if (!Array.isArray(attachments)) return []

  const blocks: ImageContent[] = []
  for (const attachment of attachments) {
    const materialized = isJsonObject(attachment) ? attachment.materialized : undefined
    if (!isJsonObject(materialized)) continue
    if (materialized.status !== 'saved' || materialized.kind !== 'image') continue

    const computerPath = typeof materialized.computerPath === 'string' ? materialized.computerPath : undefined
    const mimeType = typeof materialized.mimeType === 'string' ? materialized.mimeType : undefined
    const size = typeof materialized.size === 'number' ? materialized.size : undefined
    if (!computerPath || !options.readComputerFile || !mimeType?.startsWith('image/')) continue
    if (size !== undefined && size > EXTERNAL_IMAGE_INLINE_LIMIT_BYTES) continue

    const data = await options.readComputerFile(options.agentUid, computerPath)
    if (!data) continue
    if (data.byteLength > EXTERNAL_IMAGE_INLINE_LIMIT_BYTES) continue
    blocks.push({
      type: 'image',
      data: data.toString('base64'),
      mimeType
    })
  }

  return blocks
}

function bindingAdapter(metadata: JsonObject, bindingName: string): string | undefined {
  const external = toJsonObject(metadata.external)
  const adapters = external.adapters
  if (!Array.isArray(adapters)) return undefined
  for (const value of adapters) {
    const binding = toJsonObject(value)
    if (binding.name === bindingName && typeof binding.adapter === 'string') return binding.adapter
  }
  return undefined
}

function actorDisplayName(actorValue: unknown): string | undefined {
  const actor = toJsonObject(actorValue)
  return (
    trimOptionalString(stringFromMetadata(actor, ['fullName'])) ??
    trimOptionalString(stringFromMetadata(actor, ['userName'])) ??
    trimOptionalString(stringFromMetadata(actor, ['display_name'])) ??
    trimOptionalString(stringFromMetadata(actor, ['name']))
  )
}

function trimOptionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}

function roomFromEnvelope(envelope: ExternalGatewayAgentEnvelope): JsonObject {
  return toJsonObject(envelope.data.room)
}

function actorFromEnvelope(envelope: ExternalGatewayAgentEnvelope): JsonObject {
  const message = envelope.data.message
  const author = message?.author
  return typeof author === 'object' && author !== null && !Array.isArray(author) ? (author as JsonObject) : {}
}

function externalIdFromActor(actor: JsonObject): string | undefined {
  return (
    stringFromMetadata(actor, ['userId']) ??
    stringFromMetadata(actor, ['id']) ??
    stringFromMetadata(actor, ['user_id']) ??
    stringFromMetadata(actor, ['openId']) ??
    stringFromMetadata(actor, ['open_id'])
  )
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
  if (looksLikeInternalRuntimeError(raw)) return '内部运行错误：数据库写入失败。详细错误已记录，请查看服务日志。'
  if (looksLikeRawProviderPayload(raw)) return '模型服务返回错误，请稍后重试。'
  return raw.length <= 240 ? raw : `${raw.slice(0, 237)}...`
}

function looksLikeInternalRuntimeError(raw: string): boolean {
  return (
    /\bFailed query:/i.test(raw) ||
    /\bDrizzleQueryError\b/i.test(raw) ||
    /\bPostgresError\b/i.test(raw) ||
    /\bERR_POSTGRES/i.test(raw) ||
    /\bviolates .*constraint\b/i.test(raw)
  )
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
  return [
    `<human_steering_note command_event_id="${escapeXmlAttribute(steering.command_event_id)}" effect="override_current_incomplete_task">`,
    'The user changed direction while the previous generation was in progress.',
    'Apply the instruction below as the current highest-priority user instruction for the unfinished task.',
    'Do not continue pre-steering tool plans, searches, commands, or long-form deliverables unless this instruction explicitly asks for them.',
    `<instruction>${escapeXmlText(steering.text)}</instruction>`,
    '</human_steering_note>'
  ].join('\n')
}

function escapeXmlText(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}

function escapeXmlAttribute(value: string): string {
  return escapeXmlText(value).replaceAll('"', '&quot;')
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
