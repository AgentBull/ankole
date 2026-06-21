import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { Computer } from '@agentbull/bullx-computer'
import {
  isContextOverflow,
  type AssistantMessage,
  type ImageContent,
  type TextContent,
  type ToolResultMessage
} from '@/llm'
import { match, ms } from '@pleisto/active-support'
import { and, desc, eq, sql } from 'drizzle-orm'
import { z } from 'zod'
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
import { defaultGenerationStallTimeoutMs, loadAiAgentRuntimeProfile, type AiAgentRuntimeProfile } from './config'
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

// Hard ceiling for inlining an image attachment straight into the model request.
// Bigger images are skipped (left as a saved-file reference) rather than blowing
// up the request size.
const EXTERNAL_IMAGE_INLINE_LIMIT_BYTES = 8 * 1024 * 1024
// Wait window for a message that arrives as media only (image, no text). A touch
// wider than the normal receive batch window so the text part of the same human
// message — which often lands a beat later — can join the same trigger instead
// of starting a second run.
const DEFAULT_ADDRESSED_MEDIA_BATCH_WINDOW_MS = Math.ceil(NORMAL_RECEIVE_BATCH_WINDOW_MS * 1.3)
// Abort reason stamped by the stall watchdog. finishGenerationRun reads it back
// off the AbortController to tell a watchdog-driven stall apart from a user /stop.
const GENERATION_STALLED_ABORT_REASON = 'generation_stalled'
// How often the run beats its lease liveness (and refreshes the reasoning-trace
// stream). Well under the 5-minute lease expiry so a healthy run is never taken
// over for a missed beat.
const DEFAULT_GENERATION_LIVENESS_INTERVAL_MS = ms('60s')
// First transient retry is immediate (a stall already waited out its budget,
// and the provider call-level retry already backed off quick failures); later
// retries pause so a hard outage cannot spin a tight generation loop.
const GENERATION_TRANSIENT_RETRY_DELAY_MS = ms('15s')
// Long-run progress line cadence (the liveness interval checks this clock).
const GENERATION_PROGRESS_LOG_INTERVAL_MS = ms('5m')

/** Constructor overrides for {@link AiAgentRuntime}. Every field defaults to its module singleton; the overrides exist so tests can inject fakes and tune timing. */
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

/**
 * Everything one generation attempt needs to run. The same shape is reused for
 * retries and the chained next-turn (follow-up / steer / overflow) generations:
 * a retry/continuation copies this and overrides `leaseId`, `llmTurnKind`, the
 * attempt counters, and the trigger. `leaseId` present means "resume/continue an
 * existing lease" (crash recovery or a deliberate cutover); absent means "acquire
 * a fresh lease". The `*Attempts` counters carry the retry budget across those
 * chained re-spawns.
 */
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

/** Live, in-process handles for one running attempt, threaded from {@link AiAgentRuntime.runGeneration} into the finish path. */
interface GenerationRunContext {
  abortController: AbortController
  /** Bridge that forwards the parent (caller) abort into this run's controller; unsubscribed on finish. */
  abortFromParent?: () => void
  input: RunGenerationInput
  leaseId: string
  recorder: GenerationTrajectoryRecorder
  reasoningTrace?: PreparedReasoningTrace
  triggerMessageId: string
}

/** A streaming card that successfully delivered the final answer as a live card message; carries the ids needed to record it as already-sent. */
interface StreamedAssistantCard {
  cardId: string
  messageId: string
  outboundKey: string
}

/** A streaming-card delivery that still needs projecting into the visible-output store (the post-commit mirror for the webui / search). */
interface StreamedCardProjection {
  messageId: string
  providerRoomId: string
  providerThreadId: string
  raw: JsonObject
  text: string
}

/**
 * The runtime's view of where in-progress output goes during one attempt: the
 * live streaming card (if any), the weak Redis mirror, and the tool-progress
 * status line. Built once per run by {@link AiAgentRuntime.buildGenerationStreamingSink}.
 */
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

/**
 * Tracks how the latest `todo` tool progress was shown so its follow-up update
 * lands in the same place. `delivery` records whether progress went onto the
 * live streaming card or as a standalone editable message (`outboundKey` is the
 * edit target for the latter).
 */
interface TodoProgressState {
  args: unknown
  delivery: 'streaming-card' | 'message'
  outboundKey?: string
  toolCallId: string
}

/** The hand-off to start the next generation after this one commits or cuts over (follow-up / steer / takeover). The new lease is already minted. */
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

/**
 * The settled result of one generation, returned to the caller. `enqueuedOutput`
 * says whether a visible answer was queued for delivery, so callers (e.g. the
 * programmatic-turn API) can tell "answered the user" from "ran but said nothing".
 * `fenced` means a newer lease took over and this attempt's output was discarded.
 */
interface GenerationResult {
  enqueuedOutput: boolean
  status: GenerationResultStatus
}

/**
 * A turn started by the system rather than a human message — a scheduled task
 * firing or a `check_back_later` waking up. The caller supplies the prompt text
 * and an idempotency `eventId`/`eventSource` so a re-fired schedule does not
 * answer twice. Output routing is decoupled from the conversation room
 * (`outputProviderRoomId`) so a task can run in one conversation but post
 * elsewhere, and may be silenced entirely with `suppressVisibleOutput`.
 */
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

/**
 * What the agent loop produced, classified for the finish path. The split lets
 * {@link AiAgentRuntime.finishGenerationRun} pick exactly one terminal action:
 * - `committed` — an assistant message to persist and deliver.
 * - `overflow_retry` — the provider rejected the request as too long; compress
 *   and rerun (bounded by the overflow budget).
 * - `fenced` — a newer lease owns the conversation now; throw the output away.
 * - `failed` — errored or aborted; `aborted` separates a user /stop from a real
 *   failure so only the latter (and stalls) retry.
 * - `no_assistant` — the provider returned nothing usable.
 */
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

/** The fields written when closing out an `llm_turns` row, derived from the finished assistant message and the recorded provider observations. */
interface LlmTurnFinish {
  providerMetadata?: JsonObject
  response?: JsonObject
  status: AiAgentLlmTurnStatus
  toolResults?: JsonValue[]
  usage?: JsonObject
}

/**
 * Snapshot of the one in-flight LLM call for the progress log — the operator's
 * "wedged or just long?" evidence. `providerResponse: null` means response
 * headers never arrived (connect/accept side); non-null means the provider
 * accepted the request and then went silent, with `headersAfterMs` and the
 * upstream ids needed to chase it.
 */
interface OpenLlmTurnIntrospection {
  llmTurnId: string
  callIndex: number
  runningForMs: number
  providerResponse: {
    status?: number
    generationId?: string
    cfRay?: string
    forwardedRequestId?: string
    headersAfterMs: number
  } | null
}

/**
 * Records the durable trajectory of one run: one `llm_turns` row per LLM call,
 * with its request snapshot, provider forensics, and tool results. It bridges
 * the in-memory agent loop and the Postgres audit/replay trail.
 *
 * Two non-obvious responsibilities:
 * - **Call-index continuation.** `callIndex` starts at `startCallIndex`, which
 *   crash recovery / steer cutover seeds with the lease's next free index (see
 *   {@link AiAgentConversationService.nextLlmTurnCallIndex}). Restarting at 0
 *   would collide with the per-lease unique index and silently kill the resumed
 *   run, so the sequence must continue, not reset.
 * - **Stable message refs.** Each persisted message gets a compact reference
 *   (its row id, or a turn-response/tool-result pointer) instead of being
 *   inlined again. The `WeakMap` keyed on the live message object lets later
 *   turns cite earlier ones by ref, keeping the trajectory linkable and small.
 */
class GenerationTrajectoryRecorder {
  private callIndex: number
  private readonly startCallIndex: number
  private openTurnId?: string
  private openTurnCallIndex?: number
  private openTurnStartedAtMs?: number
  // Maps a live agent-message object to the compact ref under which it was
  // already persisted, so a later turn cites it instead of re-inlining its body.
  private readonly messageRefs = new WeakMap<object, JsonValue>()
  // Provider forensics accumulated per open turn id (status, generation id,
  // cf-ray, …) — populated by the onPayload/onResponse observers below.
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
    // Pre-seed the ref map with the rendered context's existing message ids, so
    // the first request cites the already-persisted history rows by ref rather
    // than inlining them.
    rendered.messages.forEach((message, index) => {
      const ref = rendered.inputMessageRefs[index]
      if (ref && typeof message === 'object' && message !== null) this.messageRefs.set(message, ref)
    })
  }

  /**
   * Opens an `llm_turns` row just before each provider call and returns its id
   * to the loop (stamped on the call's metadata). The request snapshot is stored
   * as `requestPatches`: the model-view patches only on the first call, the tool
   * definitions only when they changed since the last call (dedupe — tools rarely
   * move within a run), and the full request body every call.
   */
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

  /** Forensics accumulated for a given turn id (used when finishing the turn). */
  providerObservation(llmTurnId: unknown): JsonObject {
    return typeof llmTurnId === 'string' ? (this.providerObservations.get(llmTurnId) ?? {}) : {}
  }

  /** Folds the outbound request payload's shape into the open turn's observation (key fingerprint only — see {@link observeProviderPayload}). */
  observeProviderPayload(payload: unknown): void {
    if (!this.openTurnId) return
    observeProviderPayload(this.providerObservations.get(this.openTurnId) ?? {}, payload)
  }

  /** Captures HTTP status and the upstream id headers (generation id, cf-ray) the moment response headers arrive — the only point a stalled stream can record them. */
  observeProviderResponse(response: { status: number; headers: Record<string, string> }): void {
    if (!this.openTurnId) return
    observeProviderResponse(this.providerObservations.get(this.openTurnId) ?? {}, response)
  }

  /**
   * Closes the open turn after the loop emits `turn_end`: writes the assistant
   * response, usage, provider metadata, and tool results, then records the
   * compact refs that let later turns cite this one. A turn that ended without an
   * assistant message is settled as failed rather than left open.
   */
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

  /** Settles the open turn (if any) with an explicit terminal status — the error/abort path, when no clean assistant message arrived. No-op when no turn is open. */
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
  openLlmTurn(): OpenLlmTurnIntrospection | undefined {
    if (!this.openTurnId || this.openTurnCallIndex === undefined || this.openTurnStartedAtMs === undefined) {
      return undefined
    }
    return {
      llmTurnId: this.openTurnId,
      callIndex: this.openTurnCallIndex,
      runningForMs: Date.now() - this.openTurnStartedAtMs,
      providerResponse: this.openTurnProviderResponse()
    }
  }

  /**
   * Transport-level forensics for the in-flight call. `null` = the HTTP request
   * is still awaiting response headers (connect/accept problem, bounded by the
   * SDK header timeout). Non-null with a growing silence = the provider accepted
   * the request and then its event stream went mute — a provider/gateway-side
   * wedge; `requestId` is the handle to chase it upstream.
   */
  private openTurnProviderResponse(): OpenLlmTurnIntrospection['providerResponse'] {
    if (!this.openTurnId || this.openTurnStartedAtMs === undefined) return null
    const observation = this.providerObservations.get(this.openTurnId)
    const observedAtMs = typeof observation?.observed_at === 'string' ? Date.parse(observation.observed_at) : Number.NaN
    if (Number.isNaN(observedAtMs)) return null
    return {
      ...(typeof observation?.response_status === 'number' ? { status: observation.response_status } : {}),
      ...(typeof observation?.provider_generation_id === 'string'
        ? { generationId: observation.provider_generation_id }
        : {}),
      ...(typeof observation?.provider_cf_ray === 'string' ? { cfRay: observation.provider_cf_ray } : {}),
      ...(typeof observation?.forwarded_request_id === 'string'
        ? { forwardedRequestId: observation.forwarded_request_id }
        : {}),
      headersAfterMs: observedAtMs - this.openTurnStartedAtMs
    }
  }

  /** Compact reference for a message in a request: its known persisted ref if we have one, otherwise a self-contained inline copy (a message minted mid-run with no row yet). */
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

// Branch id for the trajectory tree: a post-compaction context hangs off its
// summary ("summary:<id>"); an uncompacted one off the conversation root. Lets
// the audit view show compaction as a branch point rather than a flat list.
function branchIdForRendered(conversationId: string, rendered: RenderedAiAgentContext): string {
  return rendered.summaryMessageId ? `summary:${rendered.summaryMessageId}` : `conversation:${conversationId}:root`
}

// Parent of a summary branch is the conversation root it was compacted from; the
// root branch itself has no parent.
function parentBranchIdForRendered(conversationId: string, rendered: RenderedAiAgentContext): string | null {
  return rendered.summaryMessageId ? `conversation:${conversationId}:root` : null
}

// Pulls the persisted message-row ids out of the request refs, for the turn's
// `inputMessageIds` link. Only refs that point at a real `ai_agent_message` row
// qualify; inline copies (no row) are skipped.
function inputMessageIdsFromRefs(refs: JsonValue[]): string[] {
  return refs.flatMap(ref => {
    if (typeof ref !== 'object' || ref === null || Array.isArray(ref)) return []
    if (ref.type !== 'ai_agent_message' || typeof ref.id !== 'string') return []
    return [ref.id]
  })
}

// Stamps a tool result with its owning turn id and a derived idempotency key
// (`llm-turn:<turn>:tool-call:<call>`) before it is persisted. The key lets a
// replayed/recovered run recognize an effect it already applied instead of
// running the side effect twice.
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

// Newest todo-list snapshot in a turn's tool results, scanning back to front so
// the most recent state wins. Used to rehydrate the todo store across runs.
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

// Every task done or cancelled — the list is finished. Lets the stop heuristic
// treat "marked everything complete, no other tool" as a real end of turn.
function todoResultIsTerminal(result: ToolResultMessage): boolean {
  const todos = todoItemsFromToolDetails(result.details) ?? todoItemsFromToolContent(result.content)
  if (!todos || todos.length === 0) return false
  return todos.every(item => {
    if (!isJsonObject(item)) return false
    return item.status === 'completed' || item.status === 'cancelled'
  })
}

// All tasks merely in-progress — a bookkeeping update, not progress on the work.
// The stop heuristic treats such a turn as "still nothing said", so a plan-only
// turn does not end the run prematurely.
function todoResultIsHousekeeping(result: ToolResultMessage): boolean {
  const todos = todoItemsFromToolDetails(result.details) ?? todoItemsFromToolContent(result.content)
  if (!todos || todos.length === 0) return false
  return todos.every(item => isJsonObject(item) && item.status === 'in_progress')
}

// Tool name from a result, tolerating both the camelCase loop shape and the
// snake_case persisted/execution shape (results reach here from either source).
function toolNameFromToolResult(result: JsonObject): string | undefined {
  if (typeof result.toolName === 'string') return result.toolName
  if (typeof result.tool_name === 'string') return result.tool_name
  const details = isJsonObject(result.details) ? result.details : undefined
  const execution = details && isJsonObject(details.bullx_execution) ? details.bullx_execution : undefined
  return typeof execution?.tool_name === 'string' ? execution.tool_name : undefined
}

// Fallback extractor: when a todo result has no structured `details`, dig the
// items out of a JSON-encoded text content block instead. Non-JSON text is
// ignored so unrelated tool output never throws here.
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

/** Status-line text shown when a `todo` tool call starts (the chat "thinking" line). */
function formatTodoProgressStart(args: unknown): string {
  const todos = todoArgs(args)
  if (!todos) return '📋 todo: "reading task list"'
  const verb = todoMerge(args) ? 'updating' : 'planning'
  return `📋 todo: "${verb} ${todos.length} task(s)"`
}

/** Status-line text shown when a `todo` tool call finishes, summarizing completed/total when the result carries a summary. */
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

// Serializable snapshot of the tool definitions sent on a call (name, schema,
// execution flags), recorded on the turn so the audit trail shows exactly what
// the model was offered. The JSON Schema is what the provider actually sees.
function snapshotTools(tools: AgentTool<any>[] | undefined): JsonValue[] {
  return (tools ?? []).flatMap(tool => {
    const parameters = z.toJSONSchema(tool.schema)
    const snapshot = toJsonValue({
      name: tool.name,
      description: tool.description ?? null,
      parameters,
      execution_mode: tool.executionMode ?? null,
      is_read_only: tool.isReadOnly ?? null,
      is_destructive: tool.isDestructive ?? null
    })
    return snapshot === null ? [] : [snapshot]
  })
}

/**
 * Cheap pre-flight estimate of a request's token size (messages + system prompt
 * + tool definitions), used only to decide whether to compress before calling
 * the provider. System prompt and tools use the rough ~4-chars-per-token rule;
 * messages use the JSON-aware estimator. An estimate is acceptable here because
 * the provider's own context-overflow retry is the real safety net.
 */
function estimateGenerationContextTokens(
  messages: AgentMessage[],
  systemPrompt: string,
  tools: AgentTool<any>[]
): number {
  const messageTokens = estimateContextTokensJsonAware(messages)
  const systemTokens = Math.ceil(systemPrompt.length / 4)
  const toolChars = tools.reduce((sum, tool) => {
    return sum + tool.name.length + tool.description.length + safeJsonStringify(z.toJSONSchema(tool.schema)).length
  }, 0)
  return messageTokens + systemTokens + Math.ceil(toolChars / 4)
}

/**
 * Guards the threshold-compaction pre-flight: returns true only when compressing
 * could actually fit the request. It is over the window AND there is enough
 * reducible history (everything beyond the kept-recent tail) to cover the
 * overage. Without this check a context dominated by recent, un-droppable
 * messages would trigger a compress that cannot help and still overflows — a
 * wasted LLM summary call. Trivially small contexts (≤2 messages) never compact.
 */
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

// Maps the in-memory reasoning-trace ref to its snake_case persisted shape (on
// the conversation generation and the assistant message), dropping absent
// optional fields so the stored JSON stays minimal.
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

// Backfills generation settings with safe defaults so a partial or stale stored
// profile can never produce a zero/negative budget (e.g. a 0 maxTurns that would
// stop every run instantly, or a missing stall timeout). These defaults are the
// floor the runtime relies on downstream.
function normalizeRuntimeProfile(profile: AiAgentRuntimeProfile): AiAgentRuntimeProfile {
  const generation = profile.generation as Partial<AiAgentRuntimeProfile['generation']> | undefined
  return {
    ...profile,
    generation: {
      maxTurns: positiveNumber(generation?.maxTurns) ?? 100,
      stallTimeoutMs: positiveNumber(generation?.stallTimeoutMs) ?? defaultGenerationStallTimeoutMs(),
      streamGapTimeoutMs: positiveNumber(generation?.streamGapTimeoutMs) ?? ms('5m'),
      maxTransientRetries: nonNegativeNumber(generation?.maxTransientRetries) ?? 2
    }
  }
}

function positiveNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : undefined
}

function nonNegativeNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : undefined
}

/**
 * Owns the full lifecycle of an agent run.
 *
 * Inbound external-gateway deliveries (a human message, a slash command, a card
 * click, a lifecycle event) and system triggers (scheduled tasks, check-backs)
 * all funnel through here. The runtime persists the inbound as a conversation
 * message, then drives one or more *generations*: build the rendered context,
 * acquire a lease, call the LLM in a loop, stream output, execute tools, record
 * the trajectory, commit the assistant answer, and chain the next turn when
 * follow-ups or steering are queued. It also owns crash recovery and expired-
 * lease takeover.
 *
 * Two invariants run through almost every method and are the source of most of
 * the apparent complexity:
 *
 * 1. **The lease is the ownership token, not the row.** After any `await`, the
 *    process that started a run may no longer own it: a peer worker can take the
 *    conversation over after a crash, or the user can /stop it. So every commit
 *    and every queue mutation re-checks `generation.lease_id` (and `cancelled_at`)
 *    under a row lock, and discards its work if the fence moved. This is what
 *    stops a "zombie" worker from writing after takeover.
 *
 * 2. **Queued input must survive turn boundaries, fenced by that same lease.**
 *    Follow-up messages and `/steer` instructions that arrive mid-run are parked
 *    on the live lease and materialized into transcript rows at a safe boundary
 *    (commit, tool boundary, or takeover). A `false` from an append means the
 *    lease is gone, and the caller must fall through to start a fresh trigger so
 *    the input is never silently dropped onto a dead generation envelope.
 *
 * State held on the instance is process-local scheduling only (ambient/media
 * timers, the in-process run registry, live computer sessions). The durable
 * truth lives in Postgres.
 */
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

  /** Every collaborator defaults to its module singleton; the options exist so tests can inject fakes (the singleton {@link aiAgentRuntime} is built with no options). */
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

  /** Cancels the process-local scheduling timers (ambient drains, deferred media triggers) on shutdown. In-flight runs are not aborted here — lease fencing handles a hard stop. */
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

  /** Loads the agent's runtime profile and runs it through {@link normalizeRuntimeProfile} so every caller sees defaulted, sane generation budgets. */
  private async loadRuntimeProfile(agentUid: string): Promise<AiAgentRuntimeProfile> {
    return normalizeRuntimeProfile(await this.loadProfile(agentUid))
  }

  /**
   * Replaces the registered tool set. When `activeToolNames` is omitted the prior
   * active selection is preserved minus any names the new set dropped, so swapping
   * the registry never leaves an active name pointing at a tool that no longer
   * exists. Both registry and active subset are validated before anything mutates.
   */
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

  /** The registered tools currently marked active, in active-list order. */
  getActiveTools(): AgentTool<any>[] {
    return this.activeToolNames.flatMap(name => {
      const tool = this.tools.get(name)
      return tool ? [tool] : []
    })
  }

  /** Sets the active subset by name; rejects unknown or duplicate names up front so a bad selection cannot reach a run. */
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

  /** Reads a file from the agent's computer worker, used to inline image attachments into a model request. */
  private async readComputerFile(agentUid: string, path: string, signal?: AbortSignal): Promise<Buffer | null> {
    const computer = await this.getComputerSession(agentUid, signal)
    return computer.readFileToBuffer({ path }, { signal })
  }

  /**
   * One shared computer session per agent, cached as a Promise so concurrent
   * callers reuse the single in-flight connect instead of opening several. A
   * failed connect is evicted from the cache (the `.catch`) so the next call
   * retries with a clean slate rather than re-awaiting a rejected promise forever.
   */
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

  /**
   * Per-turn context hook: appends a fresh snapshot of the active todo list to
   * the model-bound messages so the model always sees the current plan, even
   * after compaction dropped the original todo tool results. Not persisted — it
   * is re-derived each turn from the live store.
   */
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

  /**
   * Rebuilds the todo store from the trajectory at the start of a run: scans
   * succeeded generation turns newest-first and hydrates from the first that
   * carries a todo snapshot. Lets a plan made in earlier turns survive process
   * restarts and compaction. Returns an empty store when none is found.
   */
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

  /**
   * Decides whether the agent loop should stop after this turn instead of
   * continuing to the next LLM call.
   *
   * The intent is "the model has said its piece to the user and is not still
   * working a tool chain". So: stop after a clarify (the run pauses for the
   * human's answer); otherwise only stop when there was visible answer text AND
   * either no tools ran, or the only tool was a `todo` bookkeeping/terminal
   * update (a plan tidy-up is not real ongoing work). A turn that produced text
   * alongside a substantive tool call keeps going, because the model is mid-task.
   */
  private shouldStopAfterGenerationTurn(context: ShouldStopAfterTurnContext): boolean {
    // A clarify ask ends the IM turn: the question is this turn's outbound, the
    // user's reply is the next turn's inbound. Never keep generating past it.
    if (context.toolResults.some(result => !result.isError && result.toolName === 'clarify')) return true
    const text = textFromAgentMessage(context.message).trim()
    if (!text) return false
    if (context.toolResults.length === 0) return true
    return context.toolResults.every(
      result =>
        !result.isError &&
        result.toolName === 'todo' &&
        (todoResultIsTerminal(result) || todoResultIsHousekeeping(result))
    )
  }

  /** Bridges `todo` tool start/end events to the live progress line. Failures are swallowed at debug level — progress display is decorative and must never break a run. */
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

  /**
   * Shows that a `todo` call started. Prefers the live streaming card's status
   * line; when no card is available it falls back to a standalone editable
   * message (reusing the prior progress message's key so updates edit in place
   * rather than spamming new posts). Suppressed when a /steer is already queued,
   * since the run is about to be interrupted and a progress note would be noise.
   */
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

  /**
   * Closes out a `todo` call's progress display, matched to how it was shown.
   * If a /steer queued mid-call, the progress is withdrawn instead of finished
   * (cleared status line, or a delete of the standalone message), so the
   * interrupted plan does not leave a stale "done" note in the chat.
   */
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

  /** Pre-tool-call gate. Reserved extension point; currently always allows. */
  private async beforeToolCall(
    _context: BeforeToolCallContext,
    _signal?: AbortSignal
  ): Promise<BeforeToolCallResult | undefined> {
    // Tool gate extension point (AgentHarness tool_call hook). No global gate today;
    // per-tool execution policy lives in the tools themselves (e.g. clarify).
    return undefined
  }

  /**
   * Post-tool-call hook used to honor a `/steer` that arrived mid-run: when one is
   * queued it returns `terminate`, so the loop stops at this clean tool boundary.
   * The finish path then materializes the steering note and starts a fresh
   * generation, rather than letting the now-misdirected turn finish its answer.
   */
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

  /**
   * Main inbound entry point. Routes one external-gateway delivery to the handler
   * for its delivery mode (a human message addressed to the agent, an ambient
   * room observation, a slash command, a card-button action, or a message-recall
   * lifecycle event). Always reports `accepted` — durability is the outbox/lease
   * machinery's job, so the gateway is acknowledged regardless of downstream
   * outcome. The mode is read from the first event; a batch is assumed uniform.
   */
  async acceptExternalGatewayDelivery(
    delivery: ExternalGatewayAgentDelivery,
    context: ExternalGatewayAgentExecutionContext
  ): Promise<{ status: 'accepted' }> {
    const first = delivery.events[0]
    if (!first) return { status: 'accepted' }
    const profile = await this.loadRuntimeProfile(context.agentUid)
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

  /**
   * Runs a system-initiated turn (scheduled task or check-back) to completion and
   * returns its result synchronously, unlike the fire-and-forget IM path. The
   * inbound is persisted as a user message keyed by `eventId`; if an assistant
   * answer already exists for that trigger, the prior result is returned without
   * re-running — so a re-fired schedule is idempotent and never answers twice.
   */
  async runProgrammaticTurn(
    context: ExternalGatewayAgentExecutionContext,
    input: AiAgentProgrammaticTurnInput
  ): Promise<AiAgentProgrammaticTurnResult> {
    const profile = await this.loadRuntimeProfile(context.agentUid)
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

  /** The assistant answer already produced for a trigger message, if any — the idempotency lookup that lets {@link runProgrammaticTurn} skip a re-run. */
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
      const queued = await this.conversations.appendPendingFollowup(conversation.id, {
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
      // The run committed/cancelled before the answer attached: fall through to
      // start a fresh turn so the clarify answer is never silently dropped.
      if (queued) return
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

  /** Re-renders the clarify card in its locked, answered state (buttons disabled, picked choice marked) so it cannot be answered twice once a choice is in. */
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

  /**
   * Crash-recovery entry point, run when a binding (re)starts. Three jobs, in
   * order: re-enqueue any committed assistant answers whose outbox row was lost
   * before dispatch (so a persisted answer is still delivered); rerun each
   * generation whose lease was still active when the previous process died,
   * continuing under the same lease (call-index continuation) and cleaning up its
   * orphaned streaming card; then drain any ambient work that came due while down.
   * Reruns are safe because the lease is unchanged and every write re-checks it.
   */
  async recoverExternalGatewayBinding(context: ExternalGatewayAgentExecutionContext): Promise<void> {
    const profile = await this.loadRuntimeProfile(context.agentUid)
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

  /**
   * Re-enqueues delivery for committed assistant answers that have an outbound
   * key but no matching outbox row — the gap left when a process died after
   * persisting the message but before (or during) writing its outbox row. The
   * `not exists` join finds exactly those, and the outbox idempotency key makes a
   * re-enqueue a no-op if one slips through, so this never double-posts. Returns
   * how many rows were rebuilt.
   */
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

  /**
   * Handles a message addressed to the agent — the main human-conversation path.
   *
   * Decides between three states of the conversation:
   * - A run is live and healthy → queue these messages as follow-ups on its
   *   lease (the committing run drains them). If the queue append reports the
   *   lease gone (committed/cancelled in the race window), fall through.
   * - A run's lease has expired without a heartbeat → take the conversation over
   *   (the old run is wedged or its process and recovery both died).
   * - Otherwise → persist the messages and start a fresh generation.
   *
   * A media-only message (image, no text) does not trigger immediately; it is
   * deferred via {@link scheduleAddressedMediaTrigger} so the text part of the
   * same human message can join the same turn. A pending clarify on the room is
   * answered first by locking its card, then the message flows down the normal
   * path as the next trigger.
   */
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
        let allQueued = true
        for (const event of delivery.events) {
          const envelope = payloadEnvelope(event)
          const sentAt = sentAtFromEnvelope(envelope, event)
          const userMessage = await createUserMessageFromEnvelope(envelope, sentAt, {
            agentUid: event.agentUid,
            readComputerFile: this.computerFileReader
          })
          const queued = await this.conversations.appendPendingFollowup(conversation.id, {
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
          if (!queued) {
            allQueued = false
            break
          }
        }
        if (allQueued) return
        // The run committed/cancelled between our snapshot and the append, so the
        // follow-up did not attach to a live lease. Fall through to the normal
        // trigger path so the message is not orphaned; appendMessage is idempotent
        // on event_id, so any event the committing run already drained is deduped.
      } else {
        // The lease outlived its expiry without a heartbeat: the run is wedged (or
        // its process died and recovery died with it). Take the conversation over
        // instead of queueing behind a lease that will never commit.
        await this.takeoverExpiredGeneration(context, conversation, delivery.events[0]?.providerEventId)
      }
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

  /**
   * Handles room chatter the agent was NOT addressed in. Each message is recorded
   * as an `im_ambient` row (scene context, not a turn trigger) and handed to the
   * ambient batcher, which decides later whether the room warrants an unprompted
   * intervention. Batched on a short window so a burst of messages is judged
   * together rather than one at a time.
   */
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

  /**
   * Dispatches a slash command: `/new` (roll the conversation over, optionally
   * with a first message), `/stop` (cancel and answer the queued questions),
   * `/steer` (inject a course correction into the running turn), `/compress`
   * (summarize history), `/retry` (redo the last exchange).
   *
   * The mutating commands fence before they abort — cancelling the lease first,
   * then aborting the in-process run — so a provider response in flight cannot
   * commit after the user already asked to stop or redirect. `/steer` and `/stop`
   * both rescue the questions queued behind the run instead of dropping them.
   */
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
      if (
        isActiveGeneration(conversation.generation) &&
        (await this.conversations.appendPendingSteering(conversation.id, steering))
      ) {
        await this.enqueueFeedback(context, event, 'Steering queued')
      } else {
        // No live lease to attach to (idle, or the run committed/cancelled before
        // the steer attached): materialize it and start a fresh generation so the
        // instruction is not orphaned on a dead generation envelope.
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

  /**
   * Handles a message-recall / message-delete lifecycle event from the provider:
   * when a user unsends a message the agent quoted or replied to, the lifecycle
   * service decides what to retract, and any resulting delete intents are
   * enqueued so the agent's downstream messages disappear too.
   */
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

  /**
   * Fire-and-forget launch of a generation (the IM path does not await it).
   * Failures are logged, never thrown; the settled promise is handed to
   * `trackSettled` so a graceful shutdown can wait for in-flight runs.
   */
  private startGeneration(input: RunGenerationInput): void {
    const settled = this.runGeneration(input).then(
      () => undefined,
      error => {
        logger.error({ error, conversationId: input.conversationId }, 'AI agent generation failed')
      }
    )
    input.context.trackSettled?.(settled)
  }

  /** Arms (or re-arms) the deferred trigger for a media-only message, giving the matching text part a short window to arrive and merge into the same turn. */
  private scheduleAddressedMediaTrigger(input: RunGenerationInput): void {
    this.cancelAddressedMediaTrigger(input.conversationId)
    const timer = setTimeout(() => {
      this.addressedMediaTimers.delete(input.conversationId)
      void this.startDelayedAddressedMediaGeneration(input)
    }, this.addressedMediaBatchWindowMs)
    this.addressedMediaTimers.set(input.conversationId, timer)
  }

  /** Cancels a pending media trigger — called when a real text trigger lands first and supersedes it. */
  private cancelAddressedMediaTrigger(conversationId: string): void {
    const timer = this.addressedMediaTimers.get(conversationId)
    if (!timer) return
    clearTimeout(timer)
    this.addressedMediaTimers.delete(conversationId)
  }

  /** Fires the deferred media trigger, but only if no run started in the meantime — a text message that arrived in the window already covers this media. */
  private async startDelayedAddressedMediaGeneration(input: RunGenerationInput): Promise<void> {
    const [conversation] = await DB.select()
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, input.conversationId))
      .limit(1)
    if (!conversation || conversation.endedAt || isActiveGeneration(conversation.generation)) return
    this.startGeneration(input)
  }

  /**
   * Runs one generation attempt end to end. The long body is a single linear
   * pipeline:
   *
   * 1. Resolve the trigger and the lease. A handed-in `leaseId` resumes an
   *    existing lease (crash recovery / cutover); otherwise a fresh lease is
   *    acquired, and failing to acquire means another worker owns the run, so we
   *    return `fenced` rather than racing it.
   * 2. Shrink context if needed: the cheap microcompact pass at render time, then
   *    a threshold-compaction summary pre-flight so a doomed over-window call is
   *    avoided up front (the provider overflow retry remains the backstop).
   * 3. Build the {@link Agent}, register it, and arm two independent liveness
   *    signals — the lease heartbeat (process alive) and the stall watchdog (the
   *    in-flight LLM call alive). Their roles are kept strictly separate; see the
   *    inline notes where each is wired.
   * 4. Drive the loop, classify the outcome, and hand it to
   *    {@link finishGenerationRun}, which performs the single terminal action
   *    (commit / retry / fence / fail) and may chain the next turn.
   *
   * Everything in steps 3–4 runs under try/finally so the watchdog, timers, and
   * subscriptions are always torn down and the reasoning trace is always closed.
   */
  private async runGeneration(input: RunGenerationInput): Promise<GenerationResult> {
    const triggerMessageId = input.triggerMessageId ?? (await this.latestTriggerMessageId(input.conversationId))
    if (!triggerMessageId) return { status: 'failed', enqueuedOutput: false }
    // A handed-in lease means "continue this existing lease" (recovery / cutover);
    // otherwise acquire a fresh one. acquire returns nothing when another worker
    // already holds the conversation — that is a fence, not an error.
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
    // This run owns its own controller (the watchdog and /stop abort through it),
    // bridged from the caller's signal so a parent cancellation propagates in.
    // The bridge is unsubscribed in the finish path to avoid leaking listeners.
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
      // 2. Stall watchdog = "the in-flight LLM API call is still alive" — armed
      //    only while a provider stream is open (message_start..message_end);
      //    silence beyond the budget aborts the run, which finishGenerationRun
      //    answers with a transient retry. The SDK timeout only covers
      //    time-to-response-headers, so a stream wedged on a half-open
      //    connection would otherwise hang forever. Tool execution is NOT a
      //    stall: the watchdog disarms for it, leaving each tool to its own
      //    timeout/transport, so a long or hung tool never aborts the run here.
      const watchdog = new GenerationStallWatchdog({
        stallTimeoutMs: input.profile.generation.stallTimeoutMs,
        streamGapTimeoutMs: input.profile.generation.streamGapTimeoutMs,
        onStall: (silentForMs, phase) => {
          // openLlmTurn.providerResponse separates the wedge modes: null =
          // response headers never arrived; non-null = the provider accepted the
          // request (status/requestId/headersAfterMs) and its stream then went
          // mute — chase the requestId on the provider/gateway side.
          logger.warn(
            {
              agentUid: input.context.agentUid,
              conversationId: input.conversationId,
              leaseId: lease.leaseId,
              silentForMs,
              phase,
              stallTimeoutMs: input.profile.generation.stallTimeoutMs,
              streamGapTimeoutMs: input.profile.generation.streamGapTimeoutMs,
              openLlmTurn: recorder.openLlmTurn() ?? null
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
            // silentForMs is 0 while a tool runs (watchdog disarmed): pair it
            // with watchingLlmStream to read "stalled LLM" vs "long-running tool".
            silentForMs: watchdog.silentForMs(),
            watchingLlmStream: watchdog.isWatchingLlmStream(),
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
      // Scope the watchdog to the LLM API call: arm when the call begins
      // (turn_start, before the request — so a pre-headers wedge is caught too),
      // hold it to the tight gap budget while content flows, and disarm when the
      // stream ends so the tool execution that follows is never counted as a
      // stall. tool_execution_* events are intentionally not observed here.
      const unsubscribeWatchdog = agent.subscribe(event => {
        if (event.type === 'turn_start') watchdog.arm()
        else if (event.type === 'message_update') watchdog.touchContent()
        else if (event.type === 'message_end') watchdog.disarm()
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

  /**
   * Builds the per-run output sink: the live streaming card (provider-facing) and
   * the weak Redis mirror (webui live view). Both are best-effort — a card or
   * mirror failure degrades to a log line and never affects the run or the final
   * committed answer. The closure captures the latest streamed text/status so a
   * card that opens lazily can immediately catch up. See the inline notes for the
   * per-attempt idempotency key (so a recovered rerun does not dedupe into the
   * dead attempt's frozen card) and the durable card ref used for orphan cleanup.
   */
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

  /**
   * Wires up the {@link Agent} for one run: seeds it with the rendered context,
   * system prompt, and model, and connects every runtime hook — trajectory
   * recording (before each call / on each turn end), the stop heuristic, the
   * steering tool gate, provider observability, the streaming-text mirror, and
   * the todo progress line. The returned agent is started by
   * {@link runGenerationAgent}; the watchdog/liveness subscriptions are attached
   * separately in {@link runGeneration} so they can be torn down independently.
   */
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
      // Pass the harness `convertToLlm` so compaction-summary messages reach the model
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
      requestOptions: {
        ...profileOptions,
        metadata: {
          ...profileOptions.metadata,
          conversation_id: input.input.conversationId
        }
      },
      onPayload: async payload => {
        input.recorder.observeProviderPayload(payload)
        return undefined
      },
      onResponse: async response => {
        input.recorder.observeProviderResponse(response)
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

  /**
   * Drives the agent loop to completion and classifies the result into a
   * {@link RunOutcome}. Runs the loop, takes the last assistant message, then
   * re-checks the lease before declaring the result committable — the loop ran
   * across many `await`s during which the conversation may have been taken over,
   * so a stale worker must not commit. Context-overflow errors become an
   * `overflow_retry` until the budget is spent; everything else commits.
   */
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

    // Fence re-check: the whole loop above ran under the lease, but a peer worker
    // could have taken the conversation over (or the user could have /stopped) in
    // that time. If the lease is no longer ours, drop the output instead of
    // committing a zombie answer.
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

  /**
   * The terminal state machine for a run: takes the classified {@link RunOutcome}
   * and performs exactly one ending, then optionally chains the next turn.
   *
   * Per outcome it decides three things: whether to clear the lease (so the
   * conversation is free for the next trigger), whether to schedule a follow-on
   * generation (a transient retry, an overflow-compaction retry, or the queued
   * follow-up/steer turn from a successful commit), and what status to report.
   *
   * Key rules encoded here: only stalls and genuinely retryable transport errors
   * retry — a user /stop (`aborted` without the stall reason) never does; the
   * retry budget is carried in `transientAttempts` and the first retry is
   * immediate while later ones back off; a successful commit that queued
   * follow-ups/steering hands the new lease straight to the next generation; and
   * the lease clear + registry delete happen in `finally` so they run on every
   * path, including a thrown commit.
   */
  private async finishGenerationRun(run: GenerationRunContext, outcome: RunOutcome): Promise<GenerationResult> {
    let clearLease = false
    let nextGenerationInput: RunGenerationInput | undefined
    let retryDelayMs = 0
    let result: GenerationResult = { status: 'failed', enqueuedOutput: false }
    // The watchdog stamps this reason on abort; reading it back is how a stall is
    // told apart from a user /stop, which must not retry.
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

  /**
   * Sets up the per-run reasoning-trace recorder and its shareable view URL, when
   * the run is visible and the adapter supports it. The trace id is the lease id,
   * so a recovered rerun continues the same trace. Trace setup is best-effort: if
   * the trace stream is unavailable the run proceeds without it (returns
   * undefined) rather than failing the generation.
   */
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

  /** True for visible, non-ambient runs on a streaming-capable adapter — the same gate as the streaming card, since the trace view rides alongside it. */
  private shouldCreateReasoningTrace(input: RunGenerationInput): boolean {
    return (
      Boolean(input.providerThreadId) &&
      !input.suppressVisibleOutput &&
      input.ambientIntervention !== true &&
      adapterSupportsCapability(input.context.adapter, 'outbound', 'streaming') &&
      typeof input.context.adapter.beginStreamingCard === 'function'
    )
  }

  /**
   * Implements `/retry`: redoes the most recent exchange. The trigger that
   * produced the last answer is found, every transcript row after it is marked
   * `superseded` (so the rebuilt context excludes the old answer and anything
   * that followed), the previous answer's delivered message is deleted from the
   * chat, and a fresh generation is started from that same trigger.
   */
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

  /**
   * Describes "where am I and why am I running" for the system prompt. A
   * scheduled-task or check-back trigger reports that origin (with its id/name);
   * otherwise it resolves the chat channel — DM vs group, display name, platform —
   * from the room row, falling back to the trigger metadata and adapter hints.
   * Returns undefined when no room can be determined.
   */
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

  /** Platform label for the prompt. The Lark adapter serves both Feishu and Lark, so the configured domain disambiguates which one this binding is on. */
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

  /** Starts a generation for each ambient conversation the batcher has decided is now due to intervene, then re-arms the next drain. Runs marked `ambientIntervention` (no retries, lazy card). */
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

  /** Arms a one-shot timer to drain due ambient work after `delayMs`. The timer is tracked so {@link stop} can cancel it, and self-removes when it fires. */
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

  /** Re-arms the drain for whenever the batcher says the next conversation comes due; no timer when nothing is pending. The small slack avoids firing a hair early. */
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

  /** Newest still-live trigger message (user or ambient, not superseded) for a conversation — the fallback trigger when a generation is started without an explicit one (e.g. crash recovery with a missing trigger). */
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

  /**
   * Seals the live streaming card with the final answer. Returns the card's ids
   * only when the card is the authoritative delivery — completed, non-empty, and
   * the adapter confirmed the final text landed. Any shortfall (error/abort
   * status, empty text, missing ids, or unconfirmed final text) returns
   * undefined, which tells the commit path to fall back to a normal posted
   * message so the answer is never lost to a half-finished card.
   */
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

  /**
   * Atomically commits a finished assistant turn: persists the assistant message,
   * enqueues its delivery (or records the streaming card as already sent),
   * materializes any follow-up/steer queued on the lease into transcript rows,
   * and hands off the next lease when there is more to do.
   *
   * This is the single linearization point for "the run finished". Returning
   * undefined means the lease was lost (taken over / cancelled) and nothing was
   * written. A non-undefined result carries `nextGeneration` when queued input
   * was drained, so the caller chains straight into the next turn under the new
   * lease. The streaming-card branch records the outbox row as `sent` so the
   * drain never re-posts a card the user already saw live.
   */
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
    // The whole commit runs in one transaction under a `FOR UPDATE` lock on the
    // conversation. That lock is the serialization point against
    // appendPendingFollowup / appendPendingSteering: either a concurrent inbound
    // append lands on the lease before we read it (and we drain it here) or it
    // sees the lease replaced and reports it gone. The first three guards are the
    // fence — bail unless this lease still owns an active, uncancelled, unended
    // conversation, so a fenced-out worker writes nothing.
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

      // Drain queued input into transcript rows so the next turn sees it. Steering
      // markers go in first, then follow-up messages; the LAST row inserted
      // becomes the next trigger. Each followup also carries its own room/thread,
      // so a follow-up from a different room re-targets the next turn's output.
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

      // Hand the conversation to the next turn or release it: mint a fresh lease
      // in the same transaction when there is drained input to answer, otherwise
      // clear the generation envelope to {} so the conversation goes idle. Doing
      // this atomically with the drain is what makes "commit + chain next turn"
      // a single fenced step that a concurrent inbound cannot interleave with.
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

  /**
   * Mirrors a delivered streaming-card answer into the visible-output store (the
   * post-commit projection the webui and search read). Best-effort: a failure is
   * logged and swallowed, because the answer is already in the chat and in the
   * trajectory — the projection is a secondary view, not the source of truth.
   */
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

  /** Posts a short control-notice back to the user (the "Stopped.", "Retrying", "Steering queued" acks) for a slash command. */
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

  /** Whether a /steer is queued on this exact lease right now. Lease-scoped (returns false if the lease changed or was cancelled) so a stale check never interrupts the wrong run. Polled at tool boundaries and in the todo-progress path. */
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

  /**
   * Mid-run steering cutover: when a tool boundary terminated the loop because a
   * /steer was queued, this drains that steering into transcript rows and mints a
   * fresh lease for the redirected turn — all under a `FOR UPDATE` lock and fenced
   * to the current lease. Returns the next-generation hand-off, or undefined if
   * the lease moved or nothing was actually queued (so the caller commits the
   * turn normally instead).
   */
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

  /**
   * Inserts one steering-marker introspection row inside the caller's transaction.
   * This is the *mid-run* form: the text is wrapped in a `<human_steering_note>`
   * (see {@link steeringMarker}) telling the model to drop the in-flight plan and
   * follow the new instruction — contrast {@link materializeSteering}, the idle
   * fallback that lands the steer as a plain user message.
   */
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

  /**
   * Idle fallback for `/steer`: when there was no live lease to queue the steer
   * on, lands it as an ordinary user message that starts its own turn. No
   * steering-marker wrapper here — there is no in-flight plan to override, so the
   * instruction is just the next thing the user said.
   */
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

  /**
   * Writes a `<task_cancellation>` introspection note after a /stop, so later
   * turns know the interrupted task was abandoned on purpose and must not be
   * silently resumed. Only added when a run was actually interrupted.
   */
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

/** Process-wide runtime singleton, wired to the default service collaborators. */
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

// True when a message carries attachments but no real prose once the
// attachment-reference scaffolding is stripped — i.e. "an image, nothing typed".
// This is what makes acceptAddressed defer the trigger so the text part can join.
function isAttachmentOnlyContextMessage(envelope: ExternalGatewayAgentEnvelope): boolean {
  const attachments = envelope.data.message?.attachments
  if (!Array.isArray(attachments) || attachments.length === 0) return false
  return stripAttachmentContextText(messageText(envelope)).length === 0
}

// Removes the machine-inserted attachment references (file tags, markdown image
// links, "[image saved at: …]" notes) so what remains is only what the human
// actually typed. Used to judge whether a message is media-only.
function stripAttachmentContextText(text: string): string {
  return text
    .replace(/<file\b[^>]*\/>/gi, '')
    .replace(/!\[[^\]]*]\([^)]*\)/g, '')
    .replace(/\[\s*(?:document|image)\b[^\]]*?\bsaved at:\s*[^\]]+]/gi, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

/** Builds the user message for the model from an inbound envelope, inlining any saved image attachments as image blocks (text-only message when there are none). */
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

// Text that accompanies inlined image blocks: strip the now-redundant saved-image
// references, and if nothing prose is left, substitute a short "[Image attached]"
// placeholder so the model is never handed an image with an empty text part.
function modelTextForInlineImages(text: string, imageCount: number): string {
  const cleaned = text
    .replace(/!\[[^\]]*]\([^)]*\)/g, '')
    .replace(/\[\s*image\b[^\]]*?\bsaved at:\s*[^\]]+]/gi, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim()

  if (cleaned) return cleaned
  return imageCount === 1 ? '[Image attached]' : `[${imageCount} images attached]`
}

/**
 * Reads the message's saved image attachments off the agent's computer worker
 * and returns them as base64 image blocks. Skips anything not a saved image, not
 * actually an image MIME type, or over the inline byte limit (twice — by reported
 * size and by actual bytes, since the reported size can be wrong or absent).
 */
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

// Looks up which adapter (lark, …) a named binding uses, from the agent's
// external-adapters metadata. Drives the platform label in the system prompt.
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

// The sender's external user id, tolerating the several casings/shapes different
// providers use (userId / id / user_id / openId / open_id). Used to attribute a
// turn to its requester and to scope clarify bindings.
function externalIdFromActor(actor: JsonObject): string | undefined {
  return (
    stringFromMetadata(actor, ['userId']) ??
    stringFromMetadata(actor, ['id']) ??
    stringFromMetadata(actor, ['user_id']) ??
    stringFromMetadata(actor, ['openId']) ??
    stringFromMetadata(actor, ['open_id'])
  )
}

// Best available send time, in falling order of trust: the provider's own
// per-message timestamp, then the envelope time, then when the gateway saw the
// event, and finally now. Keeps transcript ordering sane even when upstream
// omits a timestamp.
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

/** Maps a finished assistant message to the turn's terminal fields (status, normalized response, usage, provider metadata) for the `llm_turns` row. */
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

/** Combines the configured provider info with the message's response ids and the captured transport observations into the turn's provider-metadata blob. */
function assistantProviderMetadata(
  message: AssistantMessage,
  providerObservation: JsonObject,
  profile: AiAgentRuntimeProfile
): JsonObject {
  return {
    llm_provider: profile.primaryModel.config.llmProvider,
    response_id: message.responseId ?? null,
    response_model: message.responseModel ?? null,
    ...providerObservation
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * Turns a failed/aborted assistant message into safe, plain Chinese text for the
 * end user. Known failure classes (overflow, rate limit, timeout, server, auth)
 * get a specific, actionable line; an internal DB error is reported as such
 * without leaking the query; a raw JSON/HTML provider body is hidden behind a
 * generic message. Only an already-human-readable error is passed through, capped
 * in length. Returns undefined when the message did not actually fail.
 */
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

// Plain JSON snapshot of the assistant message for the turn's `response` column.
// The stringify/parse round-trip strips any non-JSON-safe values from content.
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

/**
 * Wraps a /steer instruction in the `<human_steering_note>` prompt block injected
 * mid-run. The wording tells the model to treat the instruction as the new
 * highest-priority directive and abandon the pre-steer plan. The user text and
 * the event id are XML-escaped before interpolation so steer content (which may
 * be multi-line and may contain `<`/`>`/`&`) cannot break out of or forge the
 * surrounding tags.
 */
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
  // OpenRouter's own request id (req-…) and upstream id (chatcmpl-…) live only
  // in the GET /api/v1/generation body, never in response headers — so a stalled
  // stream cannot capture them inline. The only OpenRouter handle present in the
  // headers is X-Generation-Id (gen-…), allocated up front and sent before any
  // token (and before the ": OPENROUTER PROCESSING" keepalive comments), so even
  // a stream that never emits a token still records it. It is the query key for
  // /api/v1/generation, which then yields request_id / upstream_id / latency /
  // generation_time / cancelled / finish_reason.
  const generationId = headerValue(headers, 'x-generation-id')
  if (generationId) observation.provider_generation_id = generationId
  // Cloudflare-fronted providers (OpenRouter): cf-ray is the handle CF support
  // needs to trace a request that died after response headers.
  const cfRay = headerValue(headers, 'cf-ray')
  if (cfRay) observation.provider_cf_ray = cfRay
  // x-request-id, when present, is injected by an intermediate hop
  // (cross-walker-proxy / ingress / CF) — it is NOT OpenRouter's request id, so
  // it is named for what it is and kept only as a cross-hop correlation breadcrumb.
  const forwardedRequestId = headerValue(headers, 'x-request-id') ?? headerValue(headers, 'request-id')
  if (forwardedRequestId) observation.forwarded_request_id = forwardedRequestId
  observation.observed_at = new Date().toISOString()
}

// Reads one header by name, accepting either a `Headers` instance or a plain
// object map (the SDK surfaces response headers in both forms depending on path).
function headerValue(headers: unknown, key: string): string | undefined {
  if (!headers) return undefined
  if (typeof Headers !== 'undefined' && headers instanceof Headers) return headers.get(key) ?? undefined
  if (typeof headers === 'object') {
    const value = (headers as Record<string, unknown>)[key]
    return typeof value === 'string' ? value : undefined
  }
  return undefined
}

/** Throws if any name repeats. The single guard behind both tool-registry and active-subset validation, so duplicate names fail loudly at configuration time. */
function validateUniqueNames(names: string[], message: string): void {
  const seen = new Set<string>()
  const duplicates = new Set<string>()
  for (const name of names) {
    if (seen.has(name)) duplicates.add(name)
    seen.add(name)
  }
  if (duplicates.size > 0) throw new AiAgentRuntimeError(`${message}: ${[...duplicates].join(', ')}`)
}

/** Validates an active-tool selection: no duplicates, and every name resolves to a registered tool. */
function validateToolNames(names: string[], tools: Map<string, AgentTool<any>>): void {
  validateUniqueNames(names, 'Duplicate active tool name(s)')
  const missing = names.filter(name => !tools.has(name))
  if (missing.length > 0) throw new AiAgentRuntimeError(`Unknown tool(s): ${missing.join(', ')}`)
}

/** Error type for runtime misconfiguration (bad tool registry / active selection). */
export class AiAgentRuntimeError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AiAgentRuntimeError'
  }
}

// Reinterprets a raw delivery event's payload as the typed agent envelope. The
// cast is unchecked — the gateway guarantees the shape upstream, so this is the
// single place that trust is asserted instead of repeating the cast everywhere.
function payloadEnvelope(event: ExternalGatewayAgentDelivery['events'][number]): ExternalGatewayAgentEnvelope {
  return event.payload as unknown as ExternalGatewayAgentEnvelope
}
