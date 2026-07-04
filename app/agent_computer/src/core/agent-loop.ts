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

const DEFAULT_MAX_TOOL_ROUNDS = 16
const EMPTY_AFTER_TOOL_NUDGE_TEXT =
  'You just executed tool calls but returned an empty response. Please process the tool results above and continue with the task.'

/**
 * Runs the agent loop: model call → tool execution → repeat.
 *
 * Returns the final assistant message (the one without tool calls).
 */
export async function runAgentLoop(config: AgentLoopConfig): Promise<AssistantMessage> {
  let pendingMessages: Message[] = [...config.messages]
  let stateful = config.stateful
  let latestAssistant: AssistantMessage | undefined
  let toolRounds = 0
  let sawToolResults = false
  let nudgedEmptyAfterTools = false
  const maxToolRounds = config.maxToolRounds ?? DEFAULT_MAX_TOOL_ROUNDS
  const toolByName = config.tools?.length ? agentToolMap(config.tools) : undefined
  const responseWebSocketSession = config.model.responseWebSocket
    ? createResponseWebSocketSession(config.model)
    : undefined

  try {
    while (true) {
      // Build the tool definitions for this round.
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
        throw new Error(`agent loop exceeded max tool rounds (${maxToolRounds})`)
      }

      const toolCalls = latestAssistant.toolCalls
      const executedToolCalls = await executeToolCalls(toolCalls, toolByName, config)
      const toolResults = executedToolCalls.map(result => result.resultMsg)
      const toolFollowUpMessages = executedToolCalls.flatMap(result => result.followUpMessages)

      const toolJournalMessages: Message[] = [...toolResults, ...toolFollowUpMessages]
      if (toolJournalMessages.length > 0) sawToolResults = true
      let nextMessages: Message[] = toolJournalMessages

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

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function shouldNudgeEmptyAfterTools(
  message: AssistantMessage,
  sawToolResults: boolean,
  alreadyNudged: boolean
): boolean {
  return sawToolResults && !alreadyNudged && message.stopReason === 'stop' && assistantText(message).trim().length === 0
}

function retryableTerminalModelError(message: AssistantMessage): Error | undefined {
  if (message.stopReason !== 'error') return undefined
  const error = new Error(message.errorMessage || 'LLM provider returned an error')
  error.name = 'LLMProviderTerminalError'
  return isRetryableLlmError(error) ? error : undefined
}

interface ExecutedToolCall {
  resultMsg: ToolResultMessage
  followUpMessages: UserMessage[]
}

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

function canExecuteToolCallsInParallel(toolCalls: ToolCall[], toolByName: Map<string, AgentTool> | undefined): boolean {
  return toolCalls.length > 1 && toolCalls.every(toolCall => canExecuteToolCallInParallel(toolCall, toolByName))
}

function canExecuteToolCallInParallel(toolCall: ToolCall, toolByName: Map<string, AgentTool> | undefined): boolean {
  const tool = toolByName?.get(toolCall.name)
  return tool?.executionMode === 'parallel' && tool.isReadOnly === true && tool.isDestructive !== true
}

async function executeToolCall(
  toolCall: ToolCall,
  toolByName: Map<string, AgentTool> | undefined,
  config: AgentLoopConfig
): Promise<ExecutedToolCall> {
  const tool = toolByName?.get(toolCall.name)
  if (!tool) {
    return {
      resultMsg: {
        role: 'tool',
        toolCallId: toolCall.id,
        result: JSON.stringify({ error: `Unknown tool: ${toolCall.name}` })
      },
      followUpMessages: []
    }
  }

  let parsedArgs: unknown
  try {
    parsedArgs = validateToolArguments(toolCall.arguments, tool.schema)
  } catch (error) {
    return {
      resultMsg: {
        role: 'tool',
        toolCallId: toolCall.id,
        result: JSON.stringify({ error: `Invalid arguments for tool ${toolCall.name}: ${errorMessage(error)}` })
      },
      followUpMessages: []
    }
  }

  let toolResult: AgentToolResult<unknown>
  let resultText = ''
  let followUpMessages: UserMessage[] = []

  try {
    toolResult = await tool.execute(toolCall.id, parsedArgs as never, config.abortSignal)
    const processed = await processToolResultForModel(toolResult, config)
    resultText = processed.outputText
    followUpMessages = processed.followUpMessages
  } catch (e) {
    toolResult = {
      content: [{ type: 'text', text: `Error: ${e instanceof Error ? e.message : String(e)}` }],
      details: { error: String(e) }
    }
    resultText = contentText(toolResult.content)
  }

  return {
    resultMsg: {
      role: 'tool',
      toolCallId: toolCall.id,
      result: resultText || safeJsonStringify(toolResult.details)
    },
    followUpMessages
  }
}

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

function toolImageOutputText(text: string, imageCount: number): string {
  return [text, `[${imageCount} image result${imageCount === 1 ? '' : 's'} attached as follow-up user input]`]
    .filter(Boolean)
    .join('\n')
}

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
