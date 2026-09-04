import type { AssistantMessage, CallModelOptions, ContentPart, ModelConfig, UserMessage } from './types'
import { buildResponseCreateParams } from './wire'
import { parseResponse } from './parse'

export { BRAIN_JOB_OPERATIONS, BRAIN_OPERATIONS } from './types'
export type {
  AssistantMessage,
  BrainOperation,
  CallModelOptions,
  ContentPart,
  HostedBrainItemEvent,
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
export {
  MAX_REPAIRABLE_TOOL_ARGUMENT_BYTES,
  MAX_TOOL_ARGUMENT_BYTES,
  repairToolArgumentsJSON,
  zodToJSONSchema
} from './tool-schema'

/** Stateless one-shot Responses call over HTTP. Conversation-anchored turns go through createModelTurn. */
export async function callModel(model: ModelConfig, options: CallModelOptions) {
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
