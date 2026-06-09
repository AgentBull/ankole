/**
 * Agent loop that works with AgentMessage throughout.
 * Transforms to Message[] only at the LLM call boundary.
 */

import {
  type AssistantMessage,
  type Context,
  EventStream,
  type Message,
  streamSimple,
  type Tool,
  type ToolResultMessage,
  validateToolArguments
} from '@earendil-works/pi-ai'
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
  AgentToolResult,
  StreamFn
} from './types'

export type AgentEventSink = (event: AgentEvent) => Promise<void> | void

const MAX_TURNS_GRACE_PROMPT =
  'You have reached the maximum number of steps for this task. Do not call any more tools. ' +
  'Summarize what you accomplished, note anything still unfinished, and give your best final answer now.'

const EMPTY_AFTER_TOOL_NUDGE_TEXT =
  'You returned an empty response after the tool results above. ' +
  'Process those results and either continue with the task or give your final answer.'

const ORPHAN_TOOL_RESULT_STUB =
  '[Tool result unavailable — the matching tool call was removed during context compaction.]'
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
 * Start an agent loop with a new prompt message.
 * The prompt is added to the context and events are emitted for it.
 */
export function agentLoop(
  prompts: AgentMessage[],
  context: AgentContext,
  config: AgentLoopConfig,
  signal?: AbortSignal,
  streamFn?: StreamFn
): EventStream<AgentEvent, AgentMessage[]> {
  const stream = createAgentStream()

  void runAgentLoop(
    prompts,
    context,
    config,
    async event => {
      stream.push(event)
    },
    signal,
    streamFn
  ).then(messages => {
    stream.end(messages)
  })

  return stream
}

/**
 * Continue an agent loop from the current context without adding a new message.
 * Used for retries - context already has user message or tool results.
 *
 * **Important:** The last message in context must convert to a `user` or `toolResult` message
 * via `convertToLlm`. If it doesn't, the LLM provider will reject the request.
 * This cannot be validated here since `convertToLlm` is only called once per turn.
 */
export function agentLoopContinue(
  context: AgentContext,
  config: AgentLoopConfig,
  signal?: AbortSignal,
  streamFn?: StreamFn
): EventStream<AgentEvent, AgentMessage[]> {
  if (context.messages.length === 0) {
    throw new Error('Cannot continue: no messages in context')
  }

  if (context.messages[context.messages.length - 1].role === 'assistant') {
    throw new Error('Cannot continue from message role: assistant')
  }

  const stream = createAgentStream()

  void runAgentLoopContinue(
    context,
    config,
    async event => {
      stream.push(event)
    },
    signal,
    streamFn
  ).then(messages => {
    stream.end(messages)
  })

  return stream
}

export async function runAgentLoop(
  prompts: AgentMessage[],
  context: AgentContext,
  config: AgentLoopConfig,
  emit: AgentEventSink,
  signal?: AbortSignal,
  streamFn?: StreamFn
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

  await runLoop(currentContext, newMessages, config, signal, emit, streamFn)
  return newMessages
}

export async function runAgentLoopContinue(
  context: AgentContext,
  config: AgentLoopConfig,
  emit: AgentEventSink,
  signal?: AbortSignal,
  streamFn?: StreamFn
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

  await runLoop(currentContext, newMessages, config, signal, emit, streamFn)
  return newMessages
}

function createAgentStream(): EventStream<AgentEvent, AgentMessage[]> {
  return new EventStream<AgentEvent, AgentMessage[]>(
    (event: AgentEvent) => event.type === 'agent_end',
    (event: AgentEvent) => (event.type === 'agent_end' ? event.messages : [])
  )
}

/**
 * Main loop logic shared by agentLoop and agentLoopContinue.
 */
async function runLoop(
  initialContext: AgentContext,
  newMessages: AgentMessage[],
  initialConfig: AgentLoopConfig,
  signal: AbortSignal | undefined,
  emit: AgentEventSink,
  streamFn?: StreamFn
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

  // Outer loop: continues when queued follow-up messages arrive after agent would stop
  while (true) {
    let hasMoreToolCalls = true

    // Inner loop: process tool calls and steering messages
    while (hasMoreToolCalls || pendingMessages.length > 0) {
      // Iteration budget: on reaching the cap, run one tool-free grace turn so a
      // runaway tool-calling model still yields a usable summary, then stop.
      if (config.maxTurns !== undefined && turnCount >= config.maxTurns) {
        await runGraceSummaryTurn(currentContext, config, signal, emit, newMessages, streamFn)
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
      const message = await streamAssistantResponse(currentContext, config, signal, emit, streamFn)
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
  newMessages: AgentMessage[],
  streamFn?: StreamFn
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
  const message = await streamAssistantResponse(toollessContext, config, signal, emit, streamFn)
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
  emit: AgentEventSink,
  streamFn?: StreamFn
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
    tools: context.tools as unknown as Tool[] | undefined
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

  const streamFunction = streamFn || streamSimple

  const response = await withRetry(
    async () => {
      // Resolve API key inside the retry attempt so expiring-token providers can recover.
      const resolvedApiKey =
        (config.getApiKey ? await config.getApiKey(config.model.provider) : undefined) || config.apiKey
      return await streamFunction(config.model, llmContext, {
        ...config,
        apiKey: resolvedApiKey,
        metadata: {
          ...config.metadata,
          ...beforeCall?.metadata
        },
        signal
      })
    },
    {
      maxAttempts: 3,
      maxMs: config.maxRetryDelayMs,
      signal,
      isRetryable: isRetryableLlmError
    }
  )

  let partialMessage: AssistantMessage | null = null
  let addedPartial = false

  for await (const event of response) {
    switch (event.type) {
      case 'start':
        partialMessage = event.partial
        context.messages.push(partialMessage)
        addedPartial = true
        await emit({ type: 'message_start', message: { ...partialMessage } })
        break

      case 'text_start':
      case 'text_delta':
      case 'text_end':
      case 'thinking_start':
      case 'thinking_delta':
      case 'thinking_end':
      case 'toolcall_start':
      case 'toolcall_delta':
      case 'toolcall_end':
        if (partialMessage) {
          partialMessage = event.partial
          context.messages[context.messages.length - 1] = partialMessage
          await emit({
            type: 'message_update',
            assistantMessageEvent: event,
            message: { ...partialMessage }
          })
        }
        break

      case 'done':
      case 'error': {
        const finalMessage = await response.result()
        if (addedPartial) {
          context.messages[context.messages.length - 1] = finalMessage
        } else {
          context.messages.push(finalMessage)
        }
        if (!addedPartial) {
          await emit({ type: 'message_start', message: { ...finalMessage } })
        }
        await emit({ type: 'message_end', message: finalMessage })
        return finalMessage
      }
    }
  }

  const finalMessage = await response.result()
  if (addedPartial) {
    context.messages[context.messages.length - 1] = finalMessage
  } else {
    context.messages.push(finalMessage)
    await emit({ type: 'message_start', message: { ...finalMessage } })
  }
  await emit({ type: 'message_end', message: finalMessage })
  return finalMessage
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
    const validatedArgs = validateToolArguments(tool as unknown as Tool, preparedToolCall)
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
