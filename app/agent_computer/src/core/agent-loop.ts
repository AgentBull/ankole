/**
 * The reusable agent loop: assemble context → stream one assistant turn from the model → run any tool
 * calls it asked for → feed the results back → repeat until a stop condition. It is provider-agnostic
 * and stateless; the Actor Runtime worker drives it through the hooks on {@link AgentLoopConfig}
 * (steering, follow-ups, per-turn updates, tool gating).
 *
 * Key design choice: the loop carries the richer `AgentMessage[]` (which can include custom/UI-only
 * rows) the whole way through, and converts down to provider `Message[]` only at the wire boundary
 * inside {@link streamAssistantResponse}. That keeps the transcript faithful for recording/compaction
 * while still sending the provider a shape it accepts.
 */

import {
  type AssistantMessage,
  type Context,
  convertBullXMessagesToModelMessages,
  createBullXAssistantMessage,
  createBullXProviderOptions,
  isStepCount,
  type Message,
  resolveBullXReasoning,
  streamText,
  type ToolSet,
  type ToolResultMessage,
  toBullXStopReason,
  toBullXUsage,
  validateToolArguments
} from '@/llm'
import type { LanguageModelUsage } from '@/llm'
import { isPlainObject } from '@pleisto/active-support'
import { withRetry } from '@/common/async'
import { redactJsonValue, redactSensitiveText } from '@/security/redact'
import { isRetryableLlmError } from './llm-error-classifier'
import type {
  AgentContext,
  AgentEvent,
  AgentLoopConfig,
  AgentMessage,
  AgentTool,
  AgentToolCall,
  AgentToolResult
} from './types'

export type AgentEventSink = (event: AgentEvent) => Promise<void> | void

// Injected as the final user turn once `maxTurns` is hit; the grace turn runs tool-free so the model
// is forced to answer instead of calling another tool. See runGraceSummaryTurn.
const MAX_TURNS_GRACE_PROMPT =
  'You have reached the maximum number of steps for this task. Do not call any more tools. ' +
  'Summarize what you accomplished, mark anything still unfinished or blocked, and give your best final answer now.'

// One-shot nudge for the `nudgeOnEmptyAfterTools` path: an empty reply right after tool results is
// usually a model hiccup, so we prod it to actually use those results rather than ending the run.
const EMPTY_AFTER_TOOL_NUDGE_TEXT =
  'You just executed tool calls but returned an empty response. ' +
  'Process the tool results above and either continue with the task or give your final answer.'

// Filler content used only by sanitizeToolPairs at the wire boundary (see below). A stub keeps an
// otherwise-unanswered tool_use valid; the placeholder keeps an empty assistant turn valid.
const ORPHAN_TOOL_RESULT_STUB = '[Tool result unavailable - the matching tool call was removed from the model view.]'
const EMPTY_ASSISTANT_PLACEHOLDER = '(no content)'
/**
 * Repairs the provider-bound message list at the send boundary.
 *
 * Compaction (rendering from a kept-prefix anchor) and session truncation can sever
 * a tool call from its result — or leave a result whose call was dropped — and the
 * empty-after-tools nudge keeps an empty assistant in history. Anthropic / Responses
 * reject all three with a 400. This pass:
 *  - drops tool results whose originating tool call no longer survives,
 *  - injects a stub result for any surviving tool call that lost its result (placed
 *    immediately after its assistant turn so every `tool_use` is answered), and
 *  - backfills empty assistant content with a placeholder.
 *
 * Pure and idempotent: a well-formed transcript passes through unchanged. Applied
 * only here (the live wire), so trajectory reconstruction and compaction token
 * counting keep seeing the faithful, unmodified conversion.
 */
function sanitizeToolPairs(messages: Message[]): Message[] {
  const toolCallIds = new Set<string>()
  const resultIds = new Set<string>()
  for (const message of messages) {
    if (message.role === 'assistant') {
      for (const block of message.content) {
        if (block.type === 'toolCall') toolCallIds.add(block.id)
      }
    } else if (message.role === 'toolResult') {
      resultIds.add(message.toolCallId)
    }
  }

  const sanitized: Message[] = []
  const stubbed = new Set<string>()
  for (const message of messages) {
    if (message.role === 'toolResult') {
      // Drop orphan results whose tool call was compacted away.
      if (toolCallIds.has(message.toolCallId)) sanitized.push(message)
      continue
    }
    if (message.role === 'assistant') {
      sanitized.push(ensureNonEmptyAssistant(message))
      if (message.stopReason === 'error' || message.stopReason === 'aborted') continue
      for (const block of message.content) {
        if (block.type === 'toolCall' && !resultIds.has(block.id) && !stubbed.has(block.id)) {
          stubbed.add(block.id)
          sanitized.push(stubToolResult(block.id, block.name, message.timestamp))
        }
      }
      continue
    }
    sanitized.push(message)
  }
  return sanitized
}

function ensureNonEmptyAssistant(message: AssistantMessage): AssistantMessage {
  const hasToolCall = message.content.some(block => block.type === 'toolCall')
  const hasText = message.content.some(block => block.type === 'text' && block.text.trim().length > 0)
  if (hasToolCall || hasText) return message
  return { ...message, content: [...message.content, { type: 'text' as const, text: EMPTY_ASSISTANT_PLACEHOLDER }] }
}

function stubToolResult(toolCallId: string, toolName: string, timestamp: number): ToolResultMessage {
  return {
    role: 'toolResult',
    toolCallId,
    toolName,
    content: [{ type: 'text' as const, text: ORPHAN_TOOL_RESULT_STUB }],
    isError: false,
    timestamp
  }
}

/**
 * Starts a fresh run from one or more new prompt messages.
 *
 * The prompts are appended to the context and replayed as message events so subscribers record them,
 * then control hands to {@link runLoop}. The returned array is everything this run produced — the
 * prompts plus every assistant/tool-result message — which is what `shouldStopAfterTurn` sees as
 * `newMessages`.
 */
export async function runAgentLoop(
  prompts: AgentMessage[],
  context: AgentContext,
  config: AgentLoopConfig,
  emit: AgentEventSink,
  signal?: AbortSignal
): Promise<AgentMessage[]> {
  const newMessages: AgentMessage[] = [...prompts]
  const currentContext: AgentContext = {
    ...context,
    messages: [...context.messages, ...prompts]
  }

  await emit({ type: 'agent_start' })
  await emit({ type: 'turn_start' })
  for (const prompt of prompts) {
    await emit({ type: 'message_start', message: prompt })
    await emit({ type: 'message_end', message: prompt })
  }

  await runLoop(currentContext, newMessages, config, signal, emit)
  return newMessages
}

/**
 * The core turn loop behind the worker-facing `runAgentLoop` entry point.
 *
 * Two nested loops. The inner loop drives turns while the model keeps calling tools or queued
 * steering messages keep arriving; the outer loop exists only to re-enter the inner loop when a
 * follow-up message shows up after the model would otherwise have stopped. A run reaches `agent_end`
 * via one of several stop conditions, in this priority order:
 *   1. the `maxTurns` budget is hit → run one tool-free grace turn, then stop;
 *   2. the assistant turn ends in `error`/`aborted` → stop immediately;
 *   3. `shouldStopAfterTurn` returns true → graceful caller-requested stop;
 *   4. the model emits no tool calls, and there are no steering and no follow-up messages → natural end.
 * `config` and `currentContext` are reassigned mid-run by `prepareNextTurn`, so they are `let`, not const.
 */
async function runLoop(
  initialContext: AgentContext,
  newMessages: AgentMessage[],
  initialConfig: AgentLoopConfig,
  signal: AbortSignal | undefined,
  emit: AgentEventSink
): Promise<void> {
  let currentContext = initialContext
  let config = initialConfig
  let firstTurn = true
  // Opening steering poll: the user may have typed while the previous run was still finishing, so pick
  // those messages up before the first model call. (The Agent wrapper can suppress this one poll via
  // its skip latch when it already drained the queue itself.)
  let pendingMessages: AgentMessage[] = (await config.getSteeringMessages?.()) || []
  // Per-run guards:
  // - turnCount: counts model turns against the maxTurns budget.
  // - prevTurnHadToolResults: gates the empty-after-tools nudge (only an empty reply *following* tools
  //   is suspicious).
  // - nudgedAfterEmpty: one-shot latch so the nudge fires at most once per run.
  // - retriedPreToolAssistantError: one-shot latch for the very-first-turn transient-error retry below.
  let turnCount = 0
  let prevTurnHadToolResults = false
  let nudgedAfterEmpty = false
  let retriedPreToolAssistantError = false

  // Outer loop: one iteration per "the model has stopped" point. Re-runs only when a follow-up message
  // was waiting; otherwise it breaks out below to the final agent_end.
  while (true) {
    let hasMoreToolCalls = true

    // Inner loop: keeps taking turns while the model is still calling tools (hasMoreToolCalls) or there
    // are queued steering/pending messages to inject before the next turn.
    while (hasMoreToolCalls || pendingMessages.length > 0) {
      // Iteration budget: on reaching the cap, run one tool-free grace turn so a
      // runaway tool-calling model still yields a usable summary, then stop.
      if (config.maxTurns !== undefined && turnCount >= config.maxTurns) {
        await emit({ type: 'max_turns_reached', maxTurns: config.maxTurns, turnCount })
        await runGraceSummaryTurn(currentContext, config, signal, emit, newMessages)
        await emit({ type: 'agent_end', messages: newMessages })
        return
      }

      if (!firstTurn) {
        await emit({ type: 'turn_start' })
      } else {
        firstTurn = false
      }

      // Process pending messages (inject before next assistant response)
      if (pendingMessages.length > 0) {
        for (const message of pendingMessages) {
          await emit({ type: 'message_start', message })
          await emit({ type: 'message_end', message })
          currentContext.messages.push(message)
          newMessages.push(message)
        }
        pendingMessages = []
      }

      // Stream one assistant turn. streamAssistantResponse never throws; it returns a message whose
      // stopReason encodes success/error/aborted.
      const contextLengthBeforeAssistant = currentContext.messages.length
      const message = await streamAssistantResponse(currentContext, config, signal, emit)
      // First-turn transient-failure recovery: if the very first turn comes back as a retryable error
      // with nothing usable in it, the run would otherwise die before doing any work. Retry it once.
      // streamAssistantResponse has already pushed the failed (partial) assistant into the context, so
      // splice it back off, re-arm firstTurn (to suppress a spurious extra turn_start), brief backoff,
      // and loop. Limited to turn 0 / no prior tool results so a mid-run blip is left to higher layers.
      if (
        shouldRetryPreToolAssistantError(message, {
          alreadyRetried: retriedPreToolAssistantError,
          prevTurnHadToolResults,
          turnCount
        })
      ) {
        retriedPreToolAssistantError = true
        currentContext.messages.splice(contextLengthBeforeAssistant)
        firstTurn = true
        await sleepBeforePreToolAssistantRetry(config.maxRetryDelayMs, signal)
        continue
      }
      newMessages.push(message)
      turnCount++

      // Stop condition (2): a non-recoverable error or a user abort ends the run now. The failed
      // assistant message is kept in the transcript (so the error is visible) and we do not run tools.
      if (message.stopReason === 'error' || message.stopReason === 'aborted') {
        await emit({ type: 'turn_end', message, toolResults: [] })
        await emit({ type: 'agent_end', messages: newMessages })
        return
      }

      // Tool calls the model wants run this turn. Empty means the model is trying to answer/finish.
      const toolCalls = message.content.filter(c => c.type === 'toolCall')

      // An empty assistant reply right after tool results is almost always a model
      // hiccup, not task completion. Nudge it to continue exactly once instead of
      // ending the run silently. The empty assistant stays in history; `convertToLlm`
      // backfills a placeholder so it remains a valid wire message.
      if (
        config.nudgeOnEmptyAfterTools &&
        !nudgedAfterEmpty &&
        prevTurnHadToolResults &&
        toolCalls.length === 0 &&
        !assistantHasAnswerText(message)
      ) {
        nudgedAfterEmpty = true
        prevTurnHadToolResults = false
        await emit({ type: 'turn_end', message, toolResults: [] })
        pendingMessages = [emptyAfterToolNudgeMessage()]
        continue
      }

      // Default to stopping after this turn; only a tool batch that produced results and did not ask to
      // terminate keeps the inner loop going for another model turn.
      const toolResults: ToolResultMessage[] = []
      hasMoreToolCalls = false
      if (toolCalls.length > 0) {
        const executedToolBatch = await executeToolCalls(currentContext, message, config, signal, emit)
        toolResults.push(...executedToolBatch.messages)
        // `terminate` is set when every result in the batch opted to end (via afterToolCall/tool hint);
        // that short-circuits the next model turn so the run can stop on a tool's say-so.
        hasMoreToolCalls = !executedToolBatch.terminate

        for (const result of toolResults) {
          currentContext.messages.push(result)
          newMessages.push(result)
        }
      }
      prevTurnHadToolResults = toolResults.length > 0

      await emit({ type: 'turn_end', message, toolResults })

      // Let the caller swap the context, model, or thinking level before the next turn (used for
      // mid-run compaction and model/effort changes). Returning undefined keeps everything as-is.
      const nextTurnContext = {
        message,
        toolResults,
        context: currentContext,
        newMessages
      }
      const nextTurnSnapshot = await config.prepareNextTurn?.(nextTurnContext)
      if (nextTurnSnapshot) {
        currentContext = nextTurnSnapshot.context ?? currentContext
        config = {
          ...config,
          model: nextTurnSnapshot.model ?? config.model,
          // 'off' maps to undefined reasoning (the AI SDK's "no reasoning"); undefined here means
          // "leave reasoning unchanged", so the two cases must stay distinct.
          reasoning:
            nextTurnSnapshot.thinkingLevel === undefined
              ? config.reasoning
              : nextTurnSnapshot.thinkingLevel === 'off'
                ? undefined
                : nextTurnSnapshot.thinkingLevel
        }
      }

      // Stop condition (3): caller asks to stop after this turn (e.g. context nearly full). Graceful —
      // the assistant turn and its tool results were already emitted; we just don't start another turn.
      if (
        await config.shouldStopAfterTurn?.({
          message,
          toolResults,
          context: currentContext,
          newMessages
        })
      ) {
        await emit({ type: 'agent_end', messages: newMessages })
        return
      }

      // Re-poll steering between turns so mid-run user input is injected before the next model call.
      pendingMessages = (await config.getSteeringMessages?.()) || []
    }

    // Inner loop exited: the model produced no tool calls and no steering is pending, so the agent
    // would naturally stop. Last chance — drain follow-ups that were deliberately held until now.
    const followUpMessages = (await config.getFollowUpMessages?.()) || []
    if (followUpMessages.length > 0) {
      // Feed them in as pending and re-enter the inner loop for another round of turns.
      pendingMessages = followUpMessages
      continue
    }

    // Stop condition (4): nothing left to do. Leave the outer loop and end the run.
    break
  }

  await emit({ type: 'agent_end', messages: newMessages })
}

/** True when the assistant produced at least one non-empty visible text block. */
function assistantHasAnswerText(message: AssistantMessage): boolean {
  return message.content.some(block => block.type === 'text' && block.text.trim().length > 0)
}

/**
 * Decides whether to silently retry the opening assistant turn once.
 *
 * Narrow on purpose. Retrying only makes sense when nothing has happened yet and nothing usable came
 * back, so all of these must hold: not already retried; this is turn 0; no tool results exist yet; the
 * stop reason is `error`; the message has no answer text and no tool calls to salvage; and the error
 * is a transient/retryable class. A mid-run failure, or one that carries partial output, is left for
 * the higher runtime to handle so we don't discard work or mask a real fault.
 */
function shouldRetryPreToolAssistantError(
  message: AssistantMessage,
  state: {
    alreadyRetried: boolean
    prevTurnHadToolResults: boolean
    turnCount: number
  }
): boolean {
  if (state.alreadyRetried || state.turnCount !== 0 || state.prevTurnHadToolResults) return false
  if (message.stopReason !== 'error') return false
  if (assistantHasAnswerText(message)) return false
  if (message.content.some(block => block.type === 'toolCall')) return false
  return isRetryableLlmError({ message: message.errorMessage ?? '' })
}

// Short, bounded pause before the one first-turn retry. Capped at 250ms (and clamped to the configured
// max) because this is a fast, in-band retry of the opening turn — heavier backoff belongs to the
// runtime's transient-retry orchestration, not here. Skips sleeping entirely if already aborted.
async function sleepBeforePreToolAssistantRetry(maxRetryDelayMs: number | undefined, signal: AbortSignal | undefined) {
  if (signal?.aborted) return
  const delayMs = Math.max(0, Math.min(maxRetryDelayMs ?? 250, 250))
  if (delayMs === 0) return
  await Bun.sleep(delayMs)
}

function emptyAfterToolNudgeMessage(): AgentMessage {
  return { role: 'user', content: [{ type: 'text', text: EMPTY_AFTER_TOOL_NUDGE_TEXT }], timestamp: Date.now() }
}

/**
 * Runs a single tool-free "grace" turn after the iteration budget is exhausted.
 * Tools are stripped so the model must answer instead of calling more tools,
 * turning a hard cutoff into a usable summary. Emits a balanced turn_start/turn_end
 * pair so downstream trajectory recording stays consistent.
 */
async function runGraceSummaryTurn(
  context: AgentContext,
  config: AgentLoopConfig,
  signal: AbortSignal | undefined,
  emit: AgentEventSink,
  newMessages: AgentMessage[]
): Promise<void> {
  const graceUser: AgentMessage = {
    role: 'user',
    content: [{ type: 'text', text: MAX_TURNS_GRACE_PROMPT }],
    timestamp: Date.now()
  }
  await emit({ type: 'turn_start' })
  await emit({ type: 'message_start', message: graceUser })
  await emit({ type: 'message_end', message: graceUser })
  context.messages.push(graceUser)
  newMessages.push(graceUser)

  // Strip tools for the grace turn so the model summarizes instead of calling more.
  const toollessContext: AgentContext = { ...context, tools: undefined }
  const message = await streamAssistantResponse(toollessContext, config, signal, emit)
  newMessages.push(message)
  await emit({ type: 'turn_end', message, toolResults: [] })
}

/**
 * Streams a single assistant turn and returns it as a fully-formed {@link AssistantMessage}.
 *
 * This is the wire boundary: `AgentMessage[]` → (optional transformContext) → `convertToLlm` →
 * tool-pair sanitization → AI SDK `streamText`. It consumes the SDK's streamed parts, building up one
 * partial assistant message and emitting `message_update` on each delta so the UI can render live, then
 * finalizes stop reason and usage.
 *
 * Crucially it does not throw. Stream-creation failures, mid-stream `error`/`abort` parts, a missing SDK
 * model, and thrown exceptions are all folded into the returned message's `stopReason`
 * (`error`/`aborted`) and `errorMessage`. The caller (runLoop) branches on stopReason, so keeping all
 * failure in-band means the loop never has to wrap this in try/catch.
 */
async function streamAssistantResponse(
  context: AgentContext,
  config: AgentLoopConfig,
  signal: AbortSignal | undefined,
  emit: AgentEventSink
): Promise<AssistantMessage> {
  // Apply context transform if configured (AgentMessage[] → AgentMessage[])
  let messages = context.messages
  if (config.transformContext) {
    messages = await config.transformContext(messages, signal)
  }

  // Convert to LLM-compatible messages (AgentMessage[] → Message[]), then repair
  // tool-call/result pairing and empty assistant content at the wire boundary so the
  // provider never sees an orphaned tool_use/result or an empty assistant turn.
  const llmMessages = sanitizeToolPairs(await config.convertToLlm(messages))

  // Build LLM context
  const llmContext: Context = {
    systemPrompt: context.systemPrompt,
    messages: llmMessages,
    tools: context.tools
  }

  // Last hook before the request: the only point with the exact model-visible shape in hand. May return
  // per-request metadata (e.g. trace ids) that is merged into the SDK call below.
  const beforeCall = await config.beforeLlmCall?.(
    {
      context,
      messages,
      llmContext,
      llmMessages,
      model: config.model
    },
    signal
  )

  // A model row without a bound SDK instance can't be called. Surface it as a normal error turn (with
  // message_start/end) rather than throwing, so it flows through the same path as any other failure.
  const sdkModel = config.model.sdkModel
  if (!sdkModel) {
    const message = createBullXAssistantMessage(config.model, 'error', [], {
      errorMessage: `LLM model ${config.model.provider}/${config.model.id} is missing an AI SDK model instance`
    })
    context.messages.push(message)
    await emit({ type: 'message_start', message: { ...message } })
    await emit({ type: 'message_end', message })
    return message
  }

  const sdkMessages = convertBullXMessagesToModelMessages(llmMessages)
  const sdkTools = createAiSdkTools(context.tools)

  // The message is rebuilt immutably (new object on every delta) rather than mutated, so each emitted
  // event carries an independent snapshot a subscriber can hold without it changing underneath.
  let partialMessage = createBullXAssistantMessage(config.model, 'stop', [])
  let addedPartial = false
  // The SDK reports usage/response id per finish-step; we keep the last one and apply it after the
  // stream drains, because a single turn can contain multiple steps and the last is authoritative.
  let lastFinishStep:
    | {
        responseId?: string
        responseModel?: string
        usage?: LanguageModelUsage
        finishReason?: string
      }
    | undefined
  // Map an SDK block id → its index in partialMessage.content, so deltas for the same id append to the
  // right block even when text and reasoning blocks are interleaved.
  const textBlocks = new Map<string, number>()
  const reasoningBlocks = new Map<string, number>()

  // Push the partial into the live context and fire message_start exactly once, lazily on the first
  // event. Deferring until the first part means a turn that errors before producing anything never
  // emits a phantom started message.
  const emitStartOnce = async () => {
    if (addedPartial) return
    context.messages.push(partialMessage)
    addedPartial = true
    await emit({ type: 'message_start', message: { ...partialMessage } })
  }

  const emitUpdate = async (assistantMessageEvent: AgentMessageUpdateEvent) => {
    await emitStartOnce()
    // Keep the context's tail pointing at the latest immutable rebuild, since partialMessage was
    // replaced by a new object.
    context.messages[context.messages.length - 1] = partialMessage
    await emit({
      type: 'message_update',
      assistantMessageEvent,
      message: { ...partialMessage }
    })
  }

  try {
    // Retry wraps only stream *creation* (the initial request/connection), not the streamed body. A
    // retryable failure here — rate limit, 5xx, transport reset before any byte — is safe to re-issue
    // wholesale; a failure that arrives mid-stream is handled as an `error` part below instead, since
    // by then partial content may already have been emitted.
    const result = await withRetry(
      async () => {
        const metadata = {
          ...config.metadata,
          ...beforeCall?.metadata
        }
        const requestOptions = {
          ...config,
          metadata
        }
        return streamText({
          model: sdkModel,
          system: context.systemPrompt,
          messages: sdkMessages,
          tools: sdkTools,
          // Stop the SDK after a single step. This loop — not the SDK's own multi-step agent — owns the
          // tool-call/result cycle, so the SDK must hand control back after each assistant turn.
          stopWhen: isStepCount(1),
          maxOutputTokens: typeof config.maxTokens === 'number' && config.maxTokens > 0 ? config.maxTokens : undefined,
          temperature: config.temperature,
          reasoning: resolveBullXReasoning(config.model, requestOptions),
          maxRetries: config.maxRetries,
          timeout: config.timeoutMs,
          headers: config.headers,
          abortSignal: signal,
          providerOptions: createBullXProviderOptions(config.model, requestOptions),
          onLanguageModelCallStart: async event => {
            await config.onPayload?.({ ...event, metadata }, config.model)
          }
        })
      },
      {
        maxAttempts: 3,
        maxMs: config.maxRetryDelayMs,
        signal,
        isRetryable: isRetryableLlmError
      }
    )

    // Drain the SDK's streamed parts, folding each into partialMessage. text/reasoning parts come as
    // start→delta→end triples (one block per id); tool-call, finish, abort, and error are terminal-ish
    // signals. Every branch ends with an emitUpdate so the UI sees incremental progress.
    for await (const part of result.stream) {
      switch (part.type) {
        case 'start':
          await emitStartOnce()
          break
        case 'text-start': {
          const index = partialMessage.content.length
          partialMessage = {
            ...partialMessage,
            content: [...partialMessage.content, { type: 'text' as const, text: '' }]
          }
          textBlocks.set(part.id, index)
          await emitUpdate({ type: 'text_start', contentIndex: index, partial: partialMessage })
          break
        }
        case 'text-delta': {
          const index = ensureTextBlock(part.id, textBlocks, partialMessage)
          const block = partialMessage.content[index]
          if (block?.type === 'text') {
            const content = [...partialMessage.content]
            content[index] = { ...block, text: block.text + part.text }
            partialMessage = { ...partialMessage, content }
          }
          await emitUpdate({ type: 'text_delta', contentIndex: index, delta: part.text, partial: partialMessage })
          break
        }
        case 'text-end': {
          const index = textBlocks.get(part.id) ?? -1
          const block = partialMessage.content[index]
          await emitUpdate({
            type: 'text_end',
            contentIndex: index,
            content: block?.type === 'text' ? block.text : '',
            partial: partialMessage
          })
          break
        }
        case 'reasoning-start': {
          const index = partialMessage.content.length
          partialMessage = {
            ...partialMessage,
            content: [...partialMessage.content, { type: 'thinking' as const, thinking: '' }]
          }
          reasoningBlocks.set(part.id, index)
          await emitUpdate({ type: 'thinking_start', contentIndex: index, partial: partialMessage })
          break
        }
        case 'reasoning-delta': {
          const index = ensureThinkingBlock(part.id, reasoningBlocks, partialMessage)
          const block = partialMessage.content[index]
          if (block?.type === 'thinking') {
            const content = [...partialMessage.content]
            content[index] = { ...block, thinking: block.thinking + part.text }
            partialMessage = { ...partialMessage, content }
          }
          await emitUpdate({ type: 'thinking_delta', contentIndex: index, delta: part.text, partial: partialMessage })
          break
        }
        case 'reasoning-end': {
          const index = reasoningBlocks.get(part.id) ?? -1
          const block = partialMessage.content[index]
          await emitUpdate({
            type: 'thinking_end',
            contentIndex: index,
            content: block?.type === 'thinking' ? block.thinking : '',
            partial: partialMessage
          })
          break
        }
        case 'tool-call': {
          // The SDK delivers the fully assembled tool call here (arguments already parsed from the
          // streamed JSON). Guard against a non-object `input` by falling back to {} so a malformed
          // arguments payload still yields a structurally valid tool call for the executor to validate.
          const toolCall = {
            type: 'toolCall' as const,
            id: part.toolCallId,
            name: part.toolName,
            arguments: isPlainObject(part.input) ? part.input : {}
          }
          const index = partialMessage.content.length
          partialMessage = {
            ...partialMessage,
            content: [...partialMessage.content, toolCall]
          }
          await emitUpdate({ type: 'toolcall_end', contentIndex: index, toolCall, partial: partialMessage })
          break
        }
        case 'finish-step':
          // Per-step bookkeeping (response id, model, usage, finish reason). Stashed, not applied yet —
          // see the post-stream block. Response headers, when present, drive observability.
          lastFinishStep = {
            responseId: part.response.id,
            responseModel: part.response.modelId,
            usage: part.usage,
            finishReason: part.finishReason
          }
          if (part.response.headers) {
            await config.onResponse?.({ status: 200, headers: part.response.headers }, config.model)
          }
          break
        case 'finish':
          // End of the whole stream: record the final stop reason and aggregate usage.
          partialMessage = {
            ...partialMessage,
            stopReason: toBullXStopReason(part.finishReason),
            usage: toBullXUsage(part.totalUsage, config.model)
          }
          break
        case 'abort':
          // The SDK observed the abort signal mid-stream. Mark aborted; runLoop treats this as a stop.
          partialMessage = {
            ...partialMessage,
            stopReason: 'aborted',
            errorMessage: part.reason
          }
          break
        case 'error':
          // A provider/transport error arriving inside the stream (after creation succeeded). Captured
          // in-band as an error turn rather than thrown, since partial content may already be emitted.
          partialMessage = {
            ...partialMessage,
            stopReason: 'error',
            errorMessage: errorMessage(part.error)
          }
          break
      }
    }

    // Apply the last finish-step's metadata now that the stream is fully drained (response id, model,
    // usage). Its finishReason overrides the current stopReason only when present; otherwise the
    // stopReason set during streaming is kept.
    if (lastFinishStep) {
      partialMessage = {
        ...partialMessage,
        responseId: lastFinishStep.responseId,
        responseModel: lastFinishStep.responseModel,
        usage: toBullXUsage(lastFinishStep.usage, config.model),
        stopReason: lastFinishStep.finishReason
          ? toBullXStopReason(lastFinishStep.finishReason)
          : partialMessage.stopReason
      }
    }
  } catch (error) {
    // Reached when stream creation exhausted its retries (or a non-stream throw occurred). Distinguish a
    // user abort from a genuine error so the loop and UI report the right thing.
    partialMessage = {
      ...partialMessage,
      stopReason: signal?.aborted ? 'aborted' : 'error',
      errorMessage: errorMessage(error)
    }
  }

  // Reconcile the final message with the context tail. If anything streamed, replace the tail with the
  // finished message; if the turn produced nothing at all (e.g. immediate stream-creation failure,
  // emitStartOnce never fired), push it now and emit the start that was deferred — so every returned
  // message still has a matching message_start/message_end pair.
  if (addedPartial) {
    context.messages[context.messages.length - 1] = partialMessage
  } else {
    context.messages.push(partialMessage)
    await emit({ type: 'message_start', message: { ...partialMessage } })
  }
  await emit({ type: 'message_end', message: partialMessage })
  return partialMessage
}

type AgentMessageUpdateEvent = Extract<AgentEvent, { type: 'message_update' }>['assistantMessageEvent']

// Projects AgentTools into the SDK's ToolSet shape, exposing only name/description/schema. The
// `execute` function is deliberately omitted: tools are run by this loop (so the BullX hooks, redaction,
// and permission gate apply), not by the SDK, which only needs the schema to advertise them to the model.
function createAiSdkTools(tools: AgentTool<any>[] | undefined): ToolSet | undefined {
  if (!tools?.length) return undefined
  return Object.fromEntries(
    tools.map(agentTool => [
      agentTool.name,
      {
        description: agentTool.description,
        inputSchema: agentTool.schema
      }
    ])
  ) as ToolSet
}

function ensureTextBlock(id: string, blocks: Map<string, number>, message: AssistantMessage): number {
  const existing = blocks.get(id)
  if (existing !== undefined) return existing
  const index = message.content.length
  message.content.push({ type: 'text', text: '' })
  blocks.set(id, index)
  return index
}

function ensureThinkingBlock(id: string, blocks: Map<string, number>, message: AssistantMessage): number {
  const existing = blocks.get(id)
  if (existing !== undefined) return existing
  const index = message.content.length
  message.content.push({ type: 'thinking', thinking: '' })
  blocks.set(id, index)
  return index
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  return String(error)
}

/**
 * Runs all tool calls in one assistant turn and returns the batch of result messages.
 *
 * Picks sequential vs parallel execution. Parallel is the default, but the whole batch falls back to
 * sequential if the run is configured sequential OR if *any* single requested tool declares
 * `executionMode: 'sequential'` — a tool that must not run concurrently (e.g. one that mutates shared
 * state) forces serialization of the entire batch, since the others might race it.
 */
async function executeToolCalls(
  currentContext: AgentContext,
  assistantMessage: AssistantMessage,
  config: AgentLoopConfig,
  signal: AbortSignal | undefined,
  emit: AgentEventSink
): Promise<ExecutedToolCallBatch> {
  const toolCalls = assistantMessage.content.filter(c => c.type === 'toolCall')
  const hasSequentialToolCall = toolCalls.some(
    tc => currentContext.tools?.find(t => t.name === tc.name)?.executionMode === 'sequential'
  )
  if (config.toolExecution === 'sequential' || hasSequentialToolCall) {
    return executeToolCallsSequential(currentContext, assistantMessage, toolCalls, config, signal, emit)
  }
  return executeToolCallsParallel(currentContext, assistantMessage, toolCalls, config, signal, emit)
}

type ExecutedToolCallBatch = {
  messages: ToolResultMessage[]
  terminate: boolean
}

/**
 * Sequential strategy: prepare, execute, finalize, and emit each tool call fully before the next.
 *
 * Events come out in strict source order (start → end → tool-result message per call). A `prepared`
 * call that resolved to an `immediate` outcome (tool missing, blocked, or invalid args) skips execution
 * and is just finalized. After each call, an honored abort breaks the loop so no further tools run.
 */
async function executeToolCallsSequential(
  currentContext: AgentContext,
  assistantMessage: AssistantMessage,
  toolCalls: AgentToolCall[],
  config: AgentLoopConfig,
  signal: AbortSignal | undefined,
  emit: AgentEventSink
): Promise<ExecutedToolCallBatch> {
  const finalizedCalls: FinalizedToolCallOutcome[] = []
  const messages: ToolResultMessage[] = []

  for (const toolCall of toolCalls) {
    await emit({
      type: 'tool_execution_start',
      toolCallId: toolCall.id,
      toolName: toolCall.name,
      args: toolCall.arguments
    })

    const preparation = await prepareToolCall(currentContext, assistantMessage, toolCall, config, signal)
    let finalized: FinalizedToolCallOutcome
    if (preparation.kind === 'immediate') {
      finalized = {
        args: toolCall.arguments,
        toolCall,
        result: preparation.result,
        isError: preparation.isError
      }
    } else {
      const executed = await executePreparedToolCall(preparation, signal, emit)
      finalized = await finalizeExecutedToolCall(
        currentContext,
        assistantMessage,
        preparation,
        executed,
        config,
        signal
      )
    }

    await emitToolExecutionEnd(finalized, emit)
    const toolResultMessage = createToolResultMessage(finalized)
    await emitToolResultMessage(toolResultMessage, emit)
    finalizedCalls.push(finalized)
    messages.push(toolResultMessage)

    if (signal?.aborted) {
      break
    }
  }

  return {
    messages,
    terminate: shouldTerminateToolBatch(finalizedCalls)
  }
}

/**
 * Parallel strategy. Three distinct phases, and the ordering between them is the whole point:
 *
 * 1. Preflight, in source order: for each call, emit `tool_execution_start` and prepare it (arg
 *    validation + beforeToolCall). Immediate outcomes (missing/blocked/invalid) are finalized right
 *    here; real executions are captured as thunks, not yet run.
 * 2. Run the thunks concurrently via `Promise.all`. Each thunk does the actual `execute`, finalizes,
 *    and emits its own `tool_execution_end` — so those ends interleave in *completion* order.
 * 3. After all settle, emit the tool-result `message_start`/`message_end` by walking the results in the
 *    original *source* order, so the recorded transcript matches the order the model issued the calls.
 *
 * The split (ends in completion order, messages in source order) is the documented contract on
 * {@link ToolExecutionMode}; it lets live UI react as each tool finishes while keeping history stable.
 */
async function executeToolCallsParallel(
  currentContext: AgentContext,
  assistantMessage: AssistantMessage,
  toolCalls: AgentToolCall[],
  config: AgentLoopConfig,
  signal: AbortSignal | undefined,
  emit: AgentEventSink
): Promise<ExecutedToolCallBatch> {
  // Holds finalized immediate outcomes inline and deferred executions as thunks; Promise.all below runs
  // the thunks and leaves the immediates as-is, preserving each entry's source-order slot.
  const finalizedCalls: FinalizedToolCallEntry[] = []

  for (const toolCall of toolCalls) {
    await emit({
      type: 'tool_execution_start',
      toolCallId: toolCall.id,
      toolName: toolCall.name,
      args: toolCall.arguments
    })

    const preparation = await prepareToolCall(currentContext, assistantMessage, toolCall, config, signal)
    if (preparation.kind === 'immediate') {
      const finalized = {
        args: toolCall.arguments,
        toolCall,
        result: preparation.result,
        isError: preparation.isError
      } satisfies FinalizedToolCallOutcome
      await emitToolExecutionEnd(finalized, emit)
      finalizedCalls.push(finalized)
      if (signal?.aborted) {
        break
      }
      continue
    }

    finalizedCalls.push(async () => {
      const executed = await executePreparedToolCall(preparation, signal, emit)
      const finalized = await finalizeExecutedToolCall(
        currentContext,
        assistantMessage,
        preparation,
        executed,
        config,
        signal
      )
      await emitToolExecutionEnd(finalized, emit)
      return finalized
    })
    if (signal?.aborted) {
      break
    }
  }

  // Run deferred executions concurrently; immediates are already-resolved entries. Promise.all keeps
  // the array in source order regardless of which tool finished first, so the result messages below are
  // emitted and collected in the order the model requested the calls.
  const orderedFinalizedCalls = await Promise.all(
    finalizedCalls.map(entry => (typeof entry === 'function' ? entry() : Promise.resolve(entry)))
  )
  const messages: ToolResultMessage[] = []
  for (const finalized of orderedFinalizedCalls) {
    const toolResultMessage = createToolResultMessage(finalized)
    await emitToolResultMessage(toolResultMessage, emit)
    messages.push(toolResultMessage)
  }

  return {
    messages,
    terminate: shouldTerminateToolBatch(orderedFinalizedCalls)
  }
}

type PreparedToolCall = {
  kind: 'prepared'
  toolCall: AgentToolCall
  tool: AgentTool<any>
  args: unknown
}

type ImmediateToolCallOutcome = {
  kind: 'immediate'
  result: AgentToolResult<any>
  isError: boolean
}

type ExecutedToolCallOutcome = {
  result: AgentToolResult<any>
  isError: boolean
}

type FinalizedToolCallOutcome = {
  args: unknown
  toolCall: AgentToolCall
  result: AgentToolResult<any>
  isError: boolean
}

type FinalizedToolCallEntry = FinalizedToolCallOutcome | (() => Promise<FinalizedToolCallOutcome>)

// The batch terminates the run only if *every* result asked to terminate. One tool cannot unilaterally
// end the run while its siblings still have work to report — all-or-nothing avoids dropping the others'
// results. (Empty batch never terminates.)
function shouldTerminateToolBatch(finalizedCalls: FinalizedToolCallOutcome[]): boolean {
  return finalizedCalls.length > 0 && finalizedCalls.every(finalized => finalized.result.terminate === true)
}

// Optional per-tool shim to coerce raw model arguments before schema validation (e.g. accept a legacy
// arg name). Returns the original toolCall untouched when there is no shim or it returned the same
// object, to avoid an allocation on the common path.
function prepareToolCallArguments(tool: AgentTool<any>, toolCall: AgentToolCall): AgentToolCall {
  if (!tool.prepareArguments) {
    return toolCall
  }
  const preparedArguments = tool.prepareArguments(toolCall.arguments)
  if (preparedArguments === toolCall.arguments) {
    return toolCall
  }
  return {
    ...toolCall,
    arguments: preparedArguments as Record<string, any>
  }
}

/**
 * Validates and gates one tool call before it can run.
 *
 * Returns `prepared` (ready to execute with validated args) or `immediate` (a ready-made error result,
 * no execution). The model can hallucinate a tool name or malformed arguments, so every failure here is
 * turned into an error tool result the model can read and recover from — never a thrown exception that
 * would abort the whole batch. Resolves to immediate-error when: the named tool does not exist; arg
 * preparation/`validateToolArguments` throws; the `beforeToolCall` gate blocks it; or the run is
 * aborted (checked both right after the gate and again before returning prepared).
 */
async function prepareToolCall(
  currentContext: AgentContext,
  assistantMessage: AssistantMessage,
  toolCall: AgentToolCall,
  config: AgentLoopConfig,
  signal: AbortSignal | undefined
): Promise<PreparedToolCall | ImmediateToolCallOutcome> {
  const tool = currentContext.tools?.find(t => t.name === toolCall.name)
  if (!tool) {
    return {
      kind: 'immediate',
      result: createErrorToolResult(`Tool ${toolCall.name} not found`),
      isError: true
    }
  }

  try {
    const preparedToolCall = prepareToolCallArguments(tool, toolCall)
    const validatedArgs = validateToolArguments(tool, preparedToolCall)
    if (config.beforeToolCall) {
      const beforeResult = await config.beforeToolCall(
        {
          assistantMessage,
          toolCall,
          args: validatedArgs,
          context: currentContext
        },
        signal
      )
      if (signal?.aborted) {
        return {
          kind: 'immediate',
          result: createErrorToolResult('Operation aborted'),
          isError: true
        }
      }
      if (beforeResult?.block) {
        return {
          kind: 'immediate',
          result: createErrorToolResult(beforeResult.reason || 'Tool execution was blocked'),
          isError: true
        }
      }
    }
    if (signal?.aborted) {
      return {
        kind: 'immediate',
        result: createErrorToolResult('Operation aborted'),
        isError: true
      }
    }
    return {
      kind: 'prepared',
      toolCall,
      tool,
      args: validatedArgs
    }
  } catch (error) {
    return {
      kind: 'immediate',
      result: createErrorToolResult(error instanceof Error ? error.message : String(error)),
      isError: true
    }
  }
}

// Runs the tool's `execute`, bridging its streamed `onUpdate` callbacks into `tool_execution_update`
// events. The emits are buffered into `updateEvents` and awaited after execute settles (on both success
// and failure) so all progress events are flushed before the result is finalized, and a slow listener
// can't be left dangling. A thrown error becomes an error outcome here — the tool contract is to throw,
// and this is where the throw is caught and translated.
async function executePreparedToolCall(
  prepared: PreparedToolCall,
  signal: AbortSignal | undefined,
  emit: AgentEventSink
): Promise<ExecutedToolCallOutcome> {
  const updateEvents: Promise<void>[] = []

  try {
    const result = await prepared.tool.execute(prepared.toolCall.id, prepared.args as never, signal, partialResult => {
      updateEvents.push(
        Promise.resolve(
          emit({
            type: 'tool_execution_update',
            toolCallId: prepared.toolCall.id,
            toolName: prepared.toolCall.name,
            args: prepared.args,
            partialResult
          })
        )
      )
    })
    await Promise.all(updateEvents)
    return { result, isError: false }
  } catch (error) {
    await Promise.all(updateEvents)
    return {
      result: createErrorToolResult(error instanceof Error ? error.message : String(error)),
      isError: true
    }
  }
}

/**
 * Applies the `afterToolCall` hook (if any) and redacts the result before it becomes a message.
 *
 * The hook can override `content`/`details`/`isError`/`terminate` field-by-field — each provided field
 * replaces the original wholesale (no deep merge), omitted fields pass through. A hook that itself
 * throws is converted into an error result rather than failing the batch. Redaction runs last so even
 * hook-substituted content is scrubbed before reaching logs/UI/the model.
 */
async function finalizeExecutedToolCall(
  currentContext: AgentContext,
  assistantMessage: AssistantMessage,
  prepared: PreparedToolCall,
  executed: ExecutedToolCallOutcome,
  config: AgentLoopConfig,
  signal: AbortSignal | undefined
): Promise<FinalizedToolCallOutcome> {
  let result = executed.result
  let isError = executed.isError

  if (config.afterToolCall) {
    try {
      const afterResult = await config.afterToolCall(
        {
          assistantMessage,
          toolCall: prepared.toolCall,
          args: prepared.args,
          result,
          isError,
          context: currentContext
        },
        signal
      )
      if (afterResult) {
        result = {
          content: afterResult.content ?? result.content,
          details: afterResult.details ?? result.details,
          terminate: afterResult.terminate ?? result.terminate
        }
        isError = afterResult.isError ?? isError
      }
    } catch (error) {
      result = createErrorToolResult(error instanceof Error ? error.message : String(error))
      isError = true
    }
  }

  result = redactToolResult(result)
  return {
    args: prepared.args,
    toolCall: prepared.toolCall,
    result,
    isError
  }
}

function redactToolResult(result: AgentToolResult<any>): AgentToolResult<any> {
  return {
    ...result,
    content: result.content.map(block =>
      block.type === 'text' ? { ...block, text: redactSensitiveText(block.text) } : block
    ),
    details: redactJsonValue(result.details)
  }
}

function createErrorToolResult(message: string): AgentToolResult<any> {
  return {
    content: [{ type: 'text', text: message }],
    details: {}
  }
}

async function emitToolExecutionEnd(finalized: FinalizedToolCallOutcome, emit: AgentEventSink): Promise<void> {
  await emit({
    type: 'tool_execution_end',
    toolCallId: finalized.toolCall.id,
    toolName: finalized.toolCall.name,
    args: finalized.args,
    result: finalized.result,
    isError: finalized.isError
  })
}

function createToolResultMessage(finalized: FinalizedToolCallOutcome): ToolResultMessage {
  return {
    role: 'toolResult',
    toolCallId: finalized.toolCall.id,
    toolName: finalized.toolCall.name,
    content: finalized.result.content,
    details: withToolExecutionDetails(finalized.result.details, finalized),
    isError: finalized.isError,
    timestamp: Date.now()
  }
}

// Attaches a BullX-only `bullx_execution` provenance envelope to the result details so the recorder can
// see what actually ran: the call id/name, the validated `arguments`, and the model's `raw_arguments`
// before any prepareArguments/validation. Non-object details are nested under `value` so the envelope
// can still be added as a sibling key without clobbering the tool's own payload.
function withToolExecutionDetails(details: unknown, finalized: FinalizedToolCallOutcome): unknown {
  const execution = {
    tool_call_id: finalized.toolCall.id,
    tool_name: finalized.toolCall.name,
    arguments: finalized.args,
    raw_arguments: finalized.toolCall.arguments
  }
  if (isPlainObject(details)) return { ...details, bullx_execution: execution }
  if (details === undefined || details === null) return { bullx_execution: execution }
  return { value: details, bullx_execution: execution }
}

async function emitToolResultMessage(toolResultMessage: ToolResultMessage, emit: AgentEventSink): Promise<void> {
  await emit({ type: 'message_start', message: toolResultMessage })
  await emit({ type: 'message_end', message: toolResultMessage })
}
