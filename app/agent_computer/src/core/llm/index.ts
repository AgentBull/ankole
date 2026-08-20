import type { AssistantMessage, CallModelOptions, ContentPart, ModelConfig, UserMessage } from './types'
import { buildResponseCreateParams } from './wire'
import { parseResponse } from './parse'
import { createModelTurn } from './session'

export type {
  AssistantMessage,
  CallModelOptions,
  ContentPart,
  ImageContent,
  Message,
  ModelCallResult,
  ModelConfig,
  ModelTurn,
  ModelTurnCallOptions,
  ModelTurnOptions,
  ModelUsage,
  HostedTool,
  StatefulResponseContext,
  StopReason,
  TextContent,
  ToolCall,
  ToolCaller,
  ToolDefinition,
  ToolResultMessage,
  ToolSet,
  UserMessage
} from './types'
export { createModel } from './model'
export { createModelTurn } from './session'
export { describeTruncatedToolCalls, readTruncatedToolCall, type TruncatedToolCall } from './partial-tool-input'
export {
  MAX_REPAIRABLE_TOOL_ARGUMENT_BYTES,
  MAX_TOOL_ARGUMENT_BYTES,
  repairToolArgumentsJSON,
  zodToJSONSchema
} from './tool-schema'

export async function callModel(model: ModelConfig, options: CallModelOptions) {
  if (options.stateful) {
    const turn = createModelTurn(model, {
      stateful: options.stateful,
      abortSignal: options.abortSignal,
      onActivity: options.onActivity,
      onTextDelta: options.onTextDelta
    })

    try {
      const {
        stateful: _stateful,
        abortSignal: _abortSignal,
        onActivity: _onActivity,
        onTextDelta: _onTextDelta,
        ...callOptions
      } = options
      return await turn.call(callOptions)
    } finally {
      turn.close()
    }
  }

  const params = buildResponseCreateParams(model, options)
  await options.beforeCall?.(params)
  const requestOptions = options.abortSignal ? { signal: options.abortSignal } : undefined
  const response = await model.client.responses.create(params as never, requestOptions)
  return parseResponse(response, model.name)
}

export function userMessage(content: string | ContentPart[]): UserMessage {
  return { role: 'user', content }
}

export function assistantText(message: AssistantMessage | undefined): string {
  if (!message) return ''
  return message.content
    .map(block => block.text)
    .join('\n')
    .trim()
}
