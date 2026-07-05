/**
 * Agent loop — worker-driven Responses loop using AIGateway's stateful Responses transport.
 *
 * The loop is simple (plan §4.2):
 *   1. Call the model via `callModel()` (one response.create round).
 *   2. If the response contains function_call items, execute them locally.
 *   3. Record function_call_output results through AIGateway.
 *   4. Continue from the recorded journal anchor until no function_call items are returned.
 *
 * The worker does NOT own history expansion, compaction, or continuation
 * anchors, stop strategy, or durable state. Those live in AIGateway
 * (StatefulResponses). The worker just executes tools and records results.
 */

import { createHash, randomBytes } from 'node:crypto'
import { withRetry } from '../common/async'
import { safeJsonStringify } from '../common/json-utils'
import {
  callModel,
  assistantText,
  createResponseWebSocketSession,
  recordToolResults,
  validateToolArguments,
  type Message,
  type AssistantMessage,
  type ToolResultMessage,
  type UserMessage,
  type ImageContent,
  type ToolCall
} from './llm'
import { isLocallyRetryableLlmError, isRetryableLlmError } from './llm-error-classifier'
import type { AgentLoopConfig, AgentTool, AgentToolResult } from './types'
import {
  contentText,
  describeImagesWithFallback,
  imageSummaryBlock,
  modelSupportsImage,
  responseImageUnavailableText
} from './vision'

const DEFAULT_MAX_TOOL_ROUNDS = 64
const EMPTY_AFTER_TOOL_NUDGE_TEXT =
  'You just executed tool calls but returned an empty response. Please process the tool results above and continue with the task.'
const TOOL_ROUND_LIMIT_SYNTHESIS_TEXT =
  'The tool round limit has been reached. Do not call more tools. Synthesize the best final answer from the tool results and conversation state already available. Be explicit about anything left incomplete or unverified.'
const TOOL_ROUND_LIMIT_TOOL_OUTPUT_TEXT =
  'Tool call was not executed because the worker reached the maximum tool-round limit for this turn. Stop calling tools and synthesize a final answer from the information already available.'
const TOOL_ERROR_RECOVERY_HINT = 'Analyze the error above and try a different approach.'
const REPEATED_TOOL_FAILURE_NUDGE =
  'The same tool call has failed repeatedly. Stop retrying the same tool with small variations; choose a different route, re-check the available context, or explain the remaining blocker.'
const VOLATILE_TOOL_ARGUMENT_KEYS = new Set([
  'idempotency_key',
  'nonce',
  'request_id',
  'timestamp',
  'tool_call_id',
  'uuid'
])

/**
 * Runs the model/tool loop until the model returns a final assistant message.
 *
 * Stateful turns keep only the current round's local messages in the worker.
 * Tool outputs are recorded through AIGateway and then continued from the new
 * response id, which avoids replaying local transcripts into a stateful store.
 */
export async function runAgentLoop(config: AgentLoopConfig): Promise<AssistantMessage> {
  let pendingMessages: Message[] = [...config.messages]
  let stateful = config.stateful
  let latestAssistant: AssistantMessage | undefined
  let toolRounds = 0
  let sawToolResults = false
  let nudgedEmptyAfterTools = false
  const repeatedFailureState: RepeatedToolFailureState = { count: 0 }
  const maxToolRounds = config.maxToolRounds ?? DEFAULT_MAX_TOOL_ROUNDS
  const toolByName = config.tools?.length ? agentToolMap(config.tools) : undefined
  const responseWebSocketSession = config.model.responseWebSocket
    ? createResponseWebSocketSession(config.model)
    : undefined

  try {
    while (true) {
      // Build tool definitions each round so the abort signal and local config
      // stay turn-scoped even though the schema objects are reusable.
      const tools = toolByName
        ? Object.fromEntries(
            Array.from(toolByName.values()).map(t => [
              t.name,
              {
                name: t.name,
                description: t.description,
                parameters: t.schema,
                execute: async (args: unknown, opts: { toolCallId: string }) => {
                  return t.execute(opts.toolCallId, args as never, config.abortSignal)
                }
              }
            ])
          )
        : undefined

      // Call the model.
      const result = await withRetry(
        async () => {
          const result = await callModel(config.model, {
            instructions: config.systemPrompt,
            messages: pendingMessages,
            tools: tools as never,
            maxOutputTokens: config.maxTokens,
            temperature: config.temperature,
            abortSignal: config.abortSignal,
            onTextDelta: config.onTextDelta,
            stateful,
            responseWebSocketSession
          })
          const retryableError = retryableTerminalModelError(result.message)
          if (retryableError) throw retryableError
          return result
        },
        {
          maxAttempts: 2,
          signal: config.abortSignal,
          isRetryable: isLocallyRetryableLlmError
        }
      )

      latestAssistant = result.message
      if (result.responseId) {
        stateful = {
          ...stateful,
          conversationId: undefined,
          previousResponseId: result.responseId
        }
      }

      // If no tool calls, the loop is done.
      if (!result.hasToolCalls || !latestAssistant.toolCalls?.length) {
        if (shouldNudgeEmptyAfterTools(latestAssistant, sawToolResults, nudgedEmptyAfterTools)) {
          nudgedEmptyAfterTools = true
          pendingMessages = [{ role: 'user', content: EMPTY_AFTER_TOOL_NUDGE_TEXT }]
          continue
        }

        break
      }

      toolRounds += 1
      if (toolRounds > maxToolRounds) {
        const synthesized = await synthesizeAfterToolRoundLimit({
          config,
          maxToolRounds,
          responseWebSocketSession,
          stateful,
          toolCalls: latestAssistant.toolCalls
        })
        stateful = synthesized.stateful
        latestAssistant = synthesized.message
        break
      }

      const toolCalls = latestAssistant.toolCalls
      const executedToolCalls = await executeToolCalls(toolCalls, toolByName, config)
      const toolResults = executedToolCalls.map(result => result.resultMsg)
      const toolFollowUpMessages = [
        ...executedToolCalls.flatMap(result => result.followUpMessages),
        ...repeatedToolFailureNudges(executedToolCalls, repeatedFailureState)
      ]

      const toolJournalMessages: Message[] = [...toolResults, ...toolFollowUpMessages]
      if (toolJournalMessages.length > 0) sawToolResults = true
      let nextMessages: Message[] = toolJournalMessages

      // In stateful mode, tool results become a stored AIGateway response. The
      // next model call should anchor to that response id instead of sending the
      // same function_call_output messages again.
      if (toolJournalMessages.length > 0 && stateful.previousResponseId && responseWebSocketSession) {
        const recorded = await withRetry(
          () =>
            recordToolResults(config.model, {
              messages: toolJournalMessages,
              stateful,
              abortSignal: config.abortSignal,
              responseWebSocketSession
            }),
          {
            maxAttempts: 2,
            signal: config.abortSignal,
            isRetryable: isLocallyRetryableLlmError
          }
        )

        stateful = {
          ...stateful,
          conversationId: undefined,
          previousResponseId: recorded.responseId
        }
        nextMessages = []
      }

      const steeringMessages = config.getSteeringMessages ? await config.getSteeringMessages() : []
      pendingMessages = [...nextMessages, ...steeringMessages]
    }
  } finally {
    responseWebSocketSession?.close()
  }

  if (!latestAssistant) {
    throw new Error('agent loop completed without an assistant response')
  }
  return latestAssistant
}

/**
 * Builds a name-indexed tool map and rejects duplicates before model exposure.
 */
function agentToolMap(tools: AgentTool[]): Map<string, AgentTool> {
  const byName = new Map<string, AgentTool>()

  for (const tool of tools) {
    if (byName.has(tool.name)) {
      throw new Error(`duplicate tool name: ${tool.name}`)
    }

    byName.set(tool.name, tool)
  }

  return byName
}

/**
 * Converts unknown thrown values into readable text.
 */
function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * Decides whether to nudge once after tools produced output but the model
 * returned an empty final answer.
 *
 * This keeps a flaky provider response from silently swallowing useful tool
 * work, while avoiding an infinite "please continue" loop.
 */
function shouldNudgeEmptyAfterTools(
  message: AssistantMessage,
  sawToolResults: boolean,
  alreadyNudged: boolean
): boolean {
  return sawToolResults && !alreadyNudged && message.stopReason === 'stop' && assistantText(message).trim().length === 0
}

/**
 * Re-throws retryable terminal model errors into the local retry wrapper.
 */
function retryableTerminalModelError(message: AssistantMessage): Error | undefined {
  if (message.stopReason !== 'error') return undefined
  const error = new Error(message.errorMessage || 'LLM provider returned an error')
  error.name = 'LLMProviderTerminalError'
  return isRetryableLlmError(error) ? error : undefined
}

interface ExecutedToolCall {
  resultMsg: ToolResultMessage
  followUpMessages: UserMessage[]
  failure?: {
    key: string
    toolName: string
  }
}

interface RepeatedToolFailureState {
  key?: string
  count: number
}

interface ToolLimitSynthesisInput {
  config: AgentLoopConfig
  maxToolRounds: number
  responseWebSocketSession: ReturnType<typeof createResponseWebSocketSession> | undefined
  stateful: AgentLoopConfig['stateful']
  toolCalls: ToolCall[]
}

/**
 * Converts a runaway tool request into one no-tools synthesis turn.
 *
 * In stateful Responses mode the model has just emitted function calls. Before
 * asking it to summarize, the worker records synthetic function_call_output
 * items for those calls so the provider-side transcript is structurally closed.
 */
async function synthesizeAfterToolRoundLimit(input: ToolLimitSynthesisInput): Promise<{
  message: AssistantMessage
  stateful: AgentLoopConfig['stateful']
}> {
  let stateful = input.stateful
  let pendingMessages: Message[] = [
    ...input.toolCalls.map(toolCall => toolRoundLimitResult(toolCall, input.maxToolRounds)),
    { role: 'user' as const, content: TOOL_ROUND_LIMIT_SYNTHESIS_TEXT }
  ]

  if (input.toolCalls.length > 0 && stateful.previousResponseId && input.responseWebSocketSession) {
    const recorded = await withRetry(
      () =>
        recordToolResults(input.config.model, {
          messages: pendingMessages,
          stateful,
          abortSignal: input.config.abortSignal,
          responseWebSocketSession: input.responseWebSocketSession
        }),
      {
        maxAttempts: 2,
        signal: input.config.abortSignal,
        isRetryable: isLocallyRetryableLlmError
      }
    )

    stateful = {
      ...stateful,
      conversationId: undefined,
      previousResponseId: recorded.responseId
    }
    pendingMessages = []
  }

  const result = await withRetry(
    () =>
      callModel(input.config.model, {
        instructions: input.config.systemPrompt,
        messages: pendingMessages,
        maxOutputTokens: input.config.maxTokens,
        temperature: input.config.temperature,
        abortSignal: input.config.abortSignal,
        onTextDelta: input.config.onTextDelta,
        stateful,
        responseWebSocketSession: input.responseWebSocketSession
      }),
    {
      maxAttempts: 2,
      signal: input.config.abortSignal,
      isRetryable: isLocallyRetryableLlmError
    }
  )

  if (result.responseId) {
    stateful = {
      ...stateful,
      conversationId: undefined,
      previousResponseId: result.responseId
    }
  }

  return {
    // There is no public "interrupted" stop reason in the worker type. Marking
    // this as length preserves that the answer came from a bounded partial run.
    message: result.message.stopReason === 'stop' ? { ...result.message, stopReason: 'length' } : result.message,
    stateful
  }
}

function toolRoundLimitResult(toolCall: ToolCall, maxToolRounds: number): ToolResultMessage {
  return {
    role: 'tool',
    toolCallId: toolCall.id,
    result: wrapUntrustedToolOutput(
      `${TOOL_ROUND_LIMIT_TOOL_OUTPUT_TEXT}\nmax_tool_rounds=${maxToolRounds}\ntool=${toolCall.name}`
    )
  }
}

/**
 * Executes the model's requested tool calls in the safest available order.
 *
 * Mixed or side-effecting batches stay sequential so user-visible state changes
 * happen in model order.
 */
async function executeToolCalls(
  toolCalls: ToolCall[],
  toolByName: Map<string, AgentTool> | undefined,
  config: AgentLoopConfig
): Promise<ExecutedToolCall[]> {
  const executeOne = (toolCall: ToolCall) => executeToolCall(toolCall, toolByName, config)
  if (canExecuteToolCallsInParallel(toolCalls, toolByName)) {
    return Promise.all(toolCalls.map(executeOne))
  }

  const results: ExecutedToolCall[] = []
  for (const toolCall of toolCalls) {
    results.push(await executeOne(toolCall))
  }
  return results
}

/**
 * Allows parallel execution only when every requested tool explicitly declares
 * itself read-only and parallel-safe.
 */
function canExecuteToolCallsInParallel(toolCalls: ToolCall[], toolByName: Map<string, AgentTool> | undefined): boolean {
  return toolCalls.length > 1 && toolCalls.every(toolCall => canExecuteToolCallInParallel(toolCall, toolByName))
}

/**
 * Checks the execution policy for one model-requested tool call.
 */
function canExecuteToolCallInParallel(toolCall: ToolCall, toolByName: Map<string, AgentTool> | undefined): boolean {
  const tool = toolByName?.get(toolCall.name)
  return tool?.executionMode === 'parallel' && tool.isReadOnly === true && tool.isDestructive !== true
}

/**
 * Executes one tool call and always returns a function_call_output message.
 *
 * Tool lookup, JSON parsing, schema validation, and runtime failures are sent
 * back to the model as tool output because the model must see why its requested
 * action did not happen.
 */
async function executeToolCall(
  toolCall: ToolCall,
  toolByName: Map<string, AgentTool> | undefined,
  config: AgentLoopConfig
): Promise<ExecutedToolCall> {
  const tool = toolByName?.get(toolCall.name)
  if (!tool) {
    const message = `Unknown tool: ${toolCall.name}`
    return {
      resultMsg: {
        role: 'tool',
        toolCallId: toolCall.id,
        result: wrapUntrustedToolOutput(formatToolError(message))
      },
      followUpMessages: [],
      failure: {
        key: toolCallFailureKey(toolCall, 'unknown_tool', toolCall.arguments),
        toolName: toolCall.name
      }
    }
  }

  let parsedArgs: unknown
  try {
    parsedArgs = validateToolArguments(toolCall.arguments, tool.schema)
  } catch (error) {
    const message = `Invalid arguments for tool ${toolCall.name}: ${errorMessage(error)}`
    return {
      resultMsg: {
        role: 'tool',
        toolCallId: toolCall.id,
        result: wrapUntrustedToolOutput(formatToolError(message))
      },
      followUpMessages: [],
      failure: {
        key: toolCallFailureKey(toolCall, 'invalid_arguments', toolCall.arguments),
        toolName: toolCall.name
      }
    }
  }

  let toolResult: AgentToolResult<unknown>
  let resultText = ''
  let followUpMessages: UserMessage[] = []
  let failure: ExecutedToolCall['failure']

  try {
    toolResult = await tool.execute(toolCall.id, parsedArgs as never, config.abortSignal)
    const processed = await processToolResultForModel(toolResult, config)
    resultText = processed.outputText
    followUpMessages = processed.followUpMessages
  } catch (e) {
    const message = `Error: ${e instanceof Error ? e.message : String(e)}`
    toolResult = {
      content: [{ type: 'text', text: message }],
      details: { error: String(e) }
    }
    resultText = formatToolError(message)
    failure = {
      key: toolCallFailureKey(toolCall, 'runtime_error', parsedArgs),
      toolName: toolCall.name
    }
  }

  return {
    resultMsg: {
      role: 'tool',
      toolCallId: toolCall.id,
      result: wrapUntrustedToolOutput(resultText || safeJsonStringify(toolResult.details))
    },
    followUpMessages,
    failure
  }
}

function formatToolError(message: string): string {
  return `${message}\n${TOOL_ERROR_RECOVERY_HINT}`
}

/**
 * Adds a nonce-bearing trust boundary around tool text before it is stored back
 * into the model transcript. A malicious page/file/command output can include a
 * fake closing delimiter, but it cannot predict the per-call nonce.
 */
function wrapUntrustedToolOutput(text: string): string {
  const nonce = randomBytes(8).toString('hex')
  return `<ankole_untrusted_tool_output nonce="${nonce}">\n${text}\n</ankole_untrusted_tool_output nonce="${nonce}">`
}

function repeatedToolFailureNudges(results: ExecutedToolCall[], state: RepeatedToolFailureState): UserMessage[] {
  const nudges: UserMessage[] = []
  for (const result of results) {
    if (!result.failure) {
      state.key = undefined
      state.count = 0
      continue
    }

    if (state.key === result.failure.key) {
      state.count += 1
    } else {
      state.key = result.failure.key
      state.count = 1
    }

    if (state.count === 2) {
      nudges.push({
        role: 'user',
        content: `${REPEATED_TOOL_FAILURE_NUDGE}\nfailed_tool=${result.failure.toolName}`
      })
    }
  }
  return nudges
}

function toolCallFailureKey(toolCall: ToolCall, kind: string, args: unknown): string {
  const stableInput = {
    kind,
    name: toolCall.name,
    arguments: scrubVolatileToolArguments(parseToolArguments(args))
  }
  return createHash('sha256').update(stableJson(stableInput)).digest('hex').slice(0, 16)
}

function parseToolArguments(args: unknown): unknown {
  if (typeof args !== 'string') return args
  try {
    return JSON.parse(args)
  } catch {
    return args
  }
}

function scrubVolatileToolArguments(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(scrubVolatileToolArguments)
  if (!value || typeof value !== 'object') return value

  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .filter(([key]) => !VOLATILE_TOOL_ARGUMENT_KEYS.has(key))
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => [key, scrubVolatileToolArguments(entry)])
  )
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`
  if (value && typeof value === 'object') {
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => `${JSON.stringify(key)}:${stableJson(entry)}`)
      .join(',')}}`
  }
  return JSON.stringify(value) ?? 'null'
}

/**
 * Converts a tool result into model-visible text and optional follow-up input.
 *
 * Image outputs are special: vision-capable models receive the images directly,
 * text-only models get a fallback summary when configured, and otherwise the
 * model is told that image content was unavailable.
 */
async function processToolResultForModel(
  toolResult: AgentToolResult<unknown>,
  config: AgentLoopConfig
): Promise<{ outputText: string; followUpMessages: UserMessage[] }> {
  const text = contentText(toolResult.content)
  const images = toolResult.content.filter((part): part is ImageContent => part.type === 'image')
  if (images.length === 0) return { outputText: text, followUpMessages: [] }

  if (modelSupportsImage({ input_modalities: config.modelInputModalities })) {
    return {
      outputText: toolImageOutputText(text, images.length),
      followUpMessages: [{ role: 'user', content: [{ type: 'text', text: 'Tool returned image content.' }, ...images] }]
    }
  }

  const summary = await toolImageSummary(config, images)
  if (summary) {
    return {
      outputText: toolImageOutputText(text, images.length),
      followUpMessages: [{ role: 'user', content: `${imageSummaryBlock(summary)}` }]
    }
  }

  return {
    outputText: [text, responseImageUnavailableText()].filter(Boolean).join('\n'),
    followUpMessages: []
  }
}

/**
 * Adds a short marker so the function_call_output records that image content
 * exists even when the binary image travels as a follow-up user message.
 */
function toolImageOutputText(text: string, imageCount: number): string {
  return [text, `[${imageCount} image result${imageCount === 1 ? '' : 's'} attached as follow-up user input]`]
    .filter(Boolean)
    .join('\n')
}

/**
 * Summarizes tool images through the configured vision fallback model.
 */
async function toolImageSummary(config: AgentLoopConfig, images: ImageContent[]): Promise<string | undefined> {
  if (!config.visionFallbackModel) return undefined

  try {
    return await describeImagesWithFallback(config.visionFallbackModel, images, {
      abortSignal: config.abortSignal
    })
  } catch {
    return undefined
  }
}
