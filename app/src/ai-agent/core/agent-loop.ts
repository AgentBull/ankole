/**
 * Agent loop that works with AgentMessage throughout.
 * Transforms to Message[] only at the LLM call boundary.
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

const MAX_TURNS_GRACE_PROMPT =
  'You have reached the maximum number of steps for this task. Do not call any more tools. ' +
  'Summarize what you accomplished, mark anything still unfinished or blocked, and give your best final answer now.'

const EMPTY_AFTER_TOOL_NUDGE_TEXT =
  'You just executed tool calls but returned an empty response. ' +
  'Process the tool results above and either continue with the task or give your final answer.'

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
 * Start an agent loop with new prompt messages.
 * The prompts are added to the context and events are emitted for them.
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

export async function runAgentLoopContinue(
  context: AgentContext,
  config: AgentLoopConfig,
  emit: AgentEventSink,
  signal?: AbortSignal
): Promise<AgentMessage[]> {
  if (context.messages.length === 0) {
    throw new Error('Cannot continue: no messages in context')
  }

  if (context.messages[context.messages.length - 1].role === 'assistant') {
    throw new Error('Cannot continue from message role: assistant')
  }

  const newMessages: AgentMessage[] = []
  const currentContext: AgentContext = { ...context }

  await emit({ type: 'agent_start' })
  await emit({ type: 'turn_start' })

  await runLoop(currentContext, newMessages, config, signal, emit)
  return newMessages
}

/**
 * Main loop logic shared by runAgentLoop and runAgentLoopContinue.
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
  // Check for steering messages at start (user may have typed while waiting)
  let pendingMessages: AgentMessage[] = (await config.getSteeringMessages?.()) || []
  // Per-run guards: LLM turn budget, whether the previous turn produced tool
  // results (so an empty reply right after tools can be nudged), and a one-shot
  // latch so that nudge fires at most once per run.
  let turnCount = 0
  let prevTurnHadToolResults = false
  let nudgedAfterEmpty = false
  let retriedPreToolAssistantError = false

  // Outer loop: continues when queued follow-up messages arrive after agent would stop
  while (true) {
    let hasMoreToolCalls = true

    // Inner loop: process tool calls and steering messages
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

      // Stream assistant response
      const contextLengthBeforeAssistant = currentContext.messages.length
      const message = await streamAssistantResponse(currentContext, config, signal, emit)
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

      if (message.stopReason === 'error' || message.stopReason === 'aborted') {
        await emit({ type: 'turn_end', message, toolResults: [] })
        await emit({ type: 'agent_end', messages: newMessages })
        return
      }

      // Check for tool calls
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

      const toolResults: ToolResultMessage[] = []
      hasMoreToolCalls = false
      if (toolCalls.length > 0) {
        const executedToolBatch = await executeToolCalls(currentContext, message, config, signal, emit)
        toolResults.push(...executedToolBatch.messages)
        hasMoreToolCalls = !executedToolBatch.terminate

        for (const result of toolResults) {
          currentContext.messages.push(result)
          newMessages.push(result)
        }
      }
      prevTurnHadToolResults = toolResults.length > 0

      await emit({ type: 'turn_end', message, toolResults })

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
          reasoning:
            nextTurnSnapshot.thinkingLevel === undefined
              ? config.reasoning
              : nextTurnSnapshot.thinkingLevel === 'off'
                ? undefined
                : nextTurnSnapshot.thinkingLevel
        }
      }

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

      pendingMessages = (await config.getSteeringMessages?.()) || []
    }

    // Agent would stop here. Check for follow-up messages.
    const followUpMessages = (await config.getFollowUpMessages?.()) || []
    if (followUpMessages.length > 0) {
      // Set as pending so inner loop processes them
      pendingMessages = followUpMessages
      continue
    }

    // No more messages, exit
    break
  }

  await emit({ type: 'agent_end', messages: newMessages })
}

/** True when the assistant produced at least one non-empty visible text block. */
function assistantHasAnswerText(message: AssistantMessage): boolean {
  return message.content.some(block => block.type === 'text' && block.text.trim().length > 0)
}

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
 * Stream an assistant response from the LLM.
 * This is where AgentMessage[] gets transformed to Message[] for the LLM.
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

  let partialMessage = createBullXAssistantMessage(config.model, 'stop', [])
  let addedPartial = false
  let lastFinishStep:
    | {
        responseId?: string
        responseModel?: string
        usage?: LanguageModelUsage
        finishReason?: string
      }
    | undefined
  const textBlocks = new Map<string, number>()
  const reasoningBlocks = new Map<string, number>()

  const emitStartOnce = async () => {
    if (addedPartial) return
    context.messages.push(partialMessage)
    addedPartial = true
    await emit({ type: 'message_start', message: { ...partialMessage } })
  }

  const emitUpdate = async (assistantMessageEvent: AgentMessageUpdateEvent) => {
    await emitStartOnce()
    context.messages[context.messages.length - 1] = partialMessage
    await emit({
      type: 'message_update',
      assistantMessageEvent,
      message: { ...partialMessage }
    })
  }

  try {
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
          partialMessage = {
            ...partialMessage,
            stopReason: toBullXStopReason(part.finishReason),
            usage: toBullXUsage(part.totalUsage, config.model)
          }
          break
        case 'abort':
          partialMessage = {
            ...partialMessage,
            stopReason: 'aborted',
            errorMessage: part.reason
          }
          break
        case 'error':
          partialMessage = {
            ...partialMessage,
            stopReason: 'error',
            errorMessage: errorMessage(part.error)
          }
          break
      }
    }

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
    partialMessage = {
      ...partialMessage,
      stopReason: signal?.aborted ? 'aborted' : 'error',
      errorMessage: errorMessage(error)
    }
  }

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
 * Execute tool calls from an assistant message.
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

async function executeToolCallsParallel(
  currentContext: AgentContext,
  assistantMessage: AssistantMessage,
  toolCalls: AgentToolCall[],
  config: AgentLoopConfig,
  signal: AbortSignal | undefined,
  emit: AgentEventSink
): Promise<ExecutedToolCallBatch> {
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

function shouldTerminateToolBatch(finalizedCalls: FinalizedToolCallOutcome[]): boolean {
  return finalizedCalls.length > 0 && finalizedCalls.every(finalized => finalized.result.terminate === true)
}

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
