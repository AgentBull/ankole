/**
 * Agent loop — worker-driven Responses loop using AIGateway's stateful Responses transport.
 *
 * The loop is simple (plan §4.2):
 *   1. Call the model via a turn-scoped OpenAI Responses adapter.
 *   2. If the response contains function_call items, execute them locally.
 *   3. Record function_call_output results through AIGateway.
 *   4. Continue from the recorded journal anchor until no function_call items are returned.
 *
 * The worker owns loop termination and its local iteration budget. It does NOT
 * own history expansion, compaction, continuation anchors, or durable response
 * state; those remain in AIGateway. The worker executes tools, records their
 * results, and explicitly reports when the whole Agent turn has ended.
 */

import { createHash, randomBytes } from 'node:crypto'
import {
  safeJsonParse as safeJSONParse,
  safeJsonStringify as safeJSONStringify,
  type JsonObject as JSONObject
} from '@pleisto/active-support'
import { withRetry } from '../common/async'
import { errorMessage } from '../common/errors'
import {
  assistantText,
  createModelTurn,
  validateToolArguments,
  type Message,
  type AssistantMessage,
  type ToolResultMessage,
  type UserMessage,
  type ImageContent,
  type ModelTurn,
  type ToolCall
} from './llm'
import { isLocallyRetryableLLMError, isRetryableLLMError } from './llm-error-classifier'
import type { AgentLoopConfig, AgentLoopResult, AgentTool, AgentToolResult } from './types'
import { contentText, imageSummaryBlock, modelImageAdaptation, responseImageUnavailableText } from './vision'

const EMPTY_AFTER_TOOL_NUDGE_TEXT =
  'You just executed tool calls but returned an empty response. Please process the tool results above and continue with the task.'
const MODEL_ITERATION_LIMIT_SYNTHESIS_TEXT =
  "You've reached the maximum number of tool-calling iterations allowed. Please provide a final response summarizing what you've found and accomplished so far, without calling any more tools."
const TOOL_ERROR_RECOVERY_HINT = 'Analyze the error above and try a different approach.'
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
export async function runAgentLoop(config: AgentLoopConfig): Promise<AgentLoopResult> {
  let pendingMessages: Message[] = [...config.messages]
  let latestAssistant: AssistantMessage | undefined
  let latestResponseID: string | undefined
  let outcome: AgentLoopResult['outcome'] = 'loop_finished'
  let modelIterations = 0
  let sawToolResults = false
  let nudgedEmptyAfterTools = false
  let clarifyExecuted = false
  const repeatedFailureState: RepeatedToolFailureState = { count: 0 }
  const maxModelIterations = config.maxModelIterations
  const toolByName = config.tools?.length ? agentToolMap(config.tools) : undefined
  const modelTurn = createModelTurn(config.model, {
    stateful: config.stateful,
    abortSignal: config.abortSignal,
    onActivity: config.onActivity,
    onTextDelta: delta => {
      config.onActivity?.('model_text_delta')
      config.onTextDelta?.(delta)
    }
  })

  try {
    while (true) {
      if (modelIterations >= maxModelIterations) {
        const synthesized = await synthesizeAfterModelIterationLimit({
          config,
          maxModelIterations,
          modelTurn
        })
        latestAssistant = synthesized.message
        latestResponseID = requiredResponseID(synthesized.responseID)
        outcome = 'iteration_exhausted'
        break
      }

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
                execute: async (args: unknown, opts: { toolCallID: string }) => {
                  return t.execute(opts.toolCallID, args as never, config.abortSignal)
                }
              }
            ])
          )
        : undefined

      // Call the model.
      modelIterations += 1
      const result = await withRetry(
        async () => {
          config.onActivity?.('model_call_start')
          const result = await modelTurn.call({
            instructions: config.systemPrompt,
            messages: pendingMessages,
            tools: tools as never,
            maxOutputTokens: config.maxTokens,
            temperature: config.temperature
          })
          config.onActivity?.('model_call_done')
          const retryableError = retryableTerminalModelError(result.message)
          if (retryableError) throw retryableError
          return result
        },
        {
          maxAttempts: 2,
          signal: config.abortSignal,
          isRetryable: isLocallyRetryableLLMError
        }
      )

      latestAssistant = result.message
      latestResponseID = requiredResponseID(result.responseID)

      // If no tool calls, the loop is done.
      if (!result.hasToolCalls || !latestAssistant.toolCalls?.length) {
        if (shouldNudgeEmptyAfterTools(latestAssistant, sawToolResults, nudgedEmptyAfterTools, clarifyExecuted)) {
          nudgedEmptyAfterTools = true
          pendingMessages = [{ role: 'user', content: EMPTY_AFTER_TOOL_NUDGE_TEXT }]
          continue
        }

        break
      }

      const toolCalls = latestAssistant.toolCalls
      const executedToolCalls = config.withActivitySuspended
        ? await config.withActivitySuspended('tool_execution', () => executeToolCalls(toolCalls, toolByName, config))
        : await executeToolCalls(toolCalls, toolByName, config)
      clarifyExecuted ||= executedToolCalls.some(result => result.toolName === 'clarify' && !result.failure)
      const toolResults = executedToolCalls.map(result => result.resultMsg)
      const toolFollowUpMessages = [
        ...executedToolCalls.flatMap(result => result.followUpMessages),
        ...repeatedToolFailureNudges(executedToolCalls, repeatedFailureState)
      ]

      const toolJournalMessages: Message[] = [...toolResults, ...toolFollowUpMessages]
      if (toolJournalMessages.length > 0) {
        sawToolResults = true
        nudgedEmptyAfterTools = false
      }
      let nextMessages: Message[] = toolJournalMessages

      // In stateful mode, tool results become a stored AIGateway response. The
      // next model call should anchor to that response id instead of sending the
      // same function_call_output messages again.
      if (toolJournalMessages.length > 0) {
        await withRetry(
          () => {
            config.onActivity?.('tool_results_record_start')
            return modelTurn
              .recordToolResults(toolJournalMessages)
              .finally(() => config.onActivity?.('tool_results_record_done'))
          },
          {
            maxAttempts: 2,
            signal: config.abortSignal,
            isRetryable: isLocallyRetryableLLMError
          }
        )

        nextMessages = []
      }

      const steeringMessages = config.getSteeringMessages ? await config.getSteeringMessages() : []
      pendingMessages = [...nextMessages, ...steeringMessages]
    }
  } finally {
    modelTurn.close()
  }

  if (!latestAssistant || !latestResponseID) {
    throw new Error('agent loop completed without a response-backed assistant message')
  }
  return { message: latestAssistant, responseID: latestResponseID, outcome }
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
 * Decides whether to nudge once after tools produced output but the model
 * returned an empty final answer.
 *
 * This keeps a flaky provider response from silently swallowing useful tool
 * work, while avoiding an infinite "please continue" loop.
 */
export function shouldNudgeEmptyAfterTools(
  message: AssistantMessage,
  sawToolResults: boolean,
  alreadyNudged: boolean,
  clarifyExecuted: boolean
): boolean {
  return (
    sawToolResults &&
    !alreadyNudged &&
    !clarifyExecuted &&
    message.stopReason === 'stop' &&
    assistantText(message).trim().length === 0
  )
}

/**
 * Re-throws retryable terminal model errors into the local retry wrapper.
 */
function retryableTerminalModelError(message: AssistantMessage): Error | undefined {
  if (message.stopReason !== 'error') return undefined
  const error = new Error(message.errorMessage || 'LLM provider returned an error')
  error.name = 'LLMProviderTerminalError'
  return isRetryableLLMError(error) ? error : undefined
}

interface ExecutedToolCall {
  toolName: string
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

interface ModelIterationLimitSynthesisInput {
  config: AgentLoopConfig
  maxModelIterations: number
  modelTurn: ModelTurn
}

/**
 * Mirrors Hermes' max-iteration finalizer: once the main model/API iteration
 * budget is spent, make one final no-tools call asking the model to summarize.
 */
async function synthesizeAfterModelIterationLimit(input: ModelIterationLimitSynthesisInput) {
  const pendingMessages: Message[] = [
    {
      role: 'user' as const,
      content: `${MODEL_ITERATION_LIMIT_SYNTHESIS_TEXT}\nmax_model_iterations=${input.maxModelIterations}`
    }
  ]

  const result = await withRetry(
    () => {
      input.config.onActivity?.('model_iteration_limit_synthesis_start')
      return input.modelTurn
        .call({
          instructions: input.config.systemPrompt,
          messages: pendingMessages,
          maxOutputTokens: input.config.maxTokens,
          temperature: input.config.temperature
        })
        .finally(() => input.config.onActivity?.('model_iteration_limit_synthesis_done'))
    },
    {
      maxAttempts: 2,
      signal: input.config.abortSignal,
      isRetryable: isLocallyRetryableLLMError
    }
  )

  return result
}

function requiredResponseID(responseID: string | undefined): string {
  if (!responseID?.startsWith('resp_')) {
    throw new Error('AIGateway model call completed without a valid response id')
  }
  return responseID
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
      toolName: toolCall.name,
      resultMsg: {
        role: 'tool',
        toolCallID: toolCall.id,
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
      toolName: toolCall.name,
      resultMsg: {
        role: 'tool',
        toolCallID: toolCall.id,
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
    config.onActivity?.(`tool:${toolCall.name}:start`)
    toolResult = await tool.execute(toolCall.id, parsedArgs as never, config.abortSignal)
    const processed = await processToolResultForModel(toolResult, config)
    resultText = processed.outputText
    followUpMessages = processed.followUpMessages
  } catch (e) {
    const message = `Error: ${errorMessage(e)}`
    toolResult = {
      content: [{ type: 'text', text: message }],
      details: { error: String(e) }
    }
    resultText = formatToolError(message)
    failure = {
      key: toolCallFailureKey(toolCall, 'runtime_error', parsedArgs),
      toolName: toolCall.name
    }
  } finally {
    config.onActivity?.(`tool:${toolCall.name}:done`)
  }

  return {
    toolName: toolCall.name,
    resultMsg: {
      role: 'tool',
      toolCallID: toolCall.id,
      result: wrapUntrustedToolOutput(resultText || safeJSONStringify(toolResult.details))
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
        content: repeatedToolFailureWarning(result.failure.toolName, state.count)
      })
    }
  }
  return nudges
}

function repeatedToolFailureWarning(toolName: string, count: number): string {
  const common =
    `${toolName} has failed ${count} times this turn. This looks like a loop. ` +
    'Do not switch to text-only replies; keep using tools, but diagnose before retrying. ' +
    'First inspect the latest error/output and verify your assumptions. '

  const recovery =
    toolName === 'command'
      ? 'For terminal failures, run a small diagnostic such as `pwd && ls -la` in the same tool, then try an absolute path, a simpler command, a different working directory, or a different tool such as read_file/patch.'
      : 'Try different arguments, a narrower query/path, an absolute path when relevant, or a different tool that can make progress. If the blocker is external, report the blocker after one diagnostic attempt instead of repeating the same failing path.'

  return `[Tool loop warning: repeated_tool_failure; count=${count}; ${common}${recovery}]`
}

function toolCallFailureKey(toolCall: ToolCall, kind: string, args: unknown): string {
  const stableInput = {
    kind,
    name: toolCall.name,
    arguments: scrubVolatileToolArguments(parseToolArguments(args))
  }
  return createHash('sha256').update(stableJSON(stableInput)).digest('hex').slice(0, 16)
}

function parseToolArguments(args: unknown): unknown {
  if (typeof args !== 'string') return args
  return safeJSONParse(args).match(
    value => value,
    () => args
  )
}

function scrubVolatileToolArguments(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(scrubVolatileToolArguments)
  if (!value || typeof value !== 'object') return value

  return Object.fromEntries(
    Object.entries(value as JSONObject)
      .filter(([key]) => !VOLATILE_TOOL_ARGUMENT_KEYS.has(key))
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => [key, scrubVolatileToolArguments(entry)])
  )
}

function stableJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`
  if (value && typeof value === 'object') {
    return `{${Object.entries(value as JSONObject)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => `${JSON.stringify(key)}:${stableJSON(entry)}`)
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
  const adaptation = await modelImageAdaptation(
    images,
    { input_modalities: config.modelInputModalities },
    {
      visionFallbackModel: config.visionFallbackModel,
      abortSignal: config.abortSignal
    }
  )

  if (adaptation.kind === 'none') return { outputText: text, followUpMessages: [] }

  if (adaptation.kind === 'direct') {
    return {
      outputText: toolImageOutputText(text, adaptation.images.length),
      followUpMessages: [
        { role: 'user', content: [{ type: 'text', text: 'Tool returned image content.' }, ...adaptation.images] }
      ]
    }
  }

  if (adaptation.kind === 'summary') {
    return {
      outputText: toolImageOutputText(text, images.length),
      followUpMessages: [{ role: 'user', content: `${imageSummaryBlock(adaptation.summary, 'tool')}` }]
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
