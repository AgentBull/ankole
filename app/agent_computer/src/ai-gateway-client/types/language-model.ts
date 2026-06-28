import type {
  LanguageModel as ProviderLanguageModel,
  LanguageModelSource,
  SharedWarning
} from '@/ai-gateway-client/provider'

/**
 * Language model that is used by the AI SDK.
 */
export type LanguageModel = ProviderLanguageModel

/**
 * Reason why a language model finished generating a response.
 *
 * Can be one of the following:
 * - `stop`: model generated stop sequence
 * - `length`: model generated maximum number of tokens
 * - `content-filter`: content filter violation stopped the model
 * - `tool-calls`: model triggered tool calls
 * - `error`: model stopped because of an error
 * - `other`: model stopped for other reasons
 */
export type FinishReason = 'stop' | 'length' | 'content-filter' | 'tool-calls' | 'error' | 'other'

/**
 * Warning from the model provider for this call. The call will proceed, but e.g.
 * some settings might not be supported, which can lead to suboptimal results.
 */
export type CallWarning = SharedWarning

/**
 * A source that has been used as input to generate the response.
 */
export type Source = LanguageModelSource

/**
 * Tool choice for the generation. It supports the following settings:
 *
 * - `auto` (default): the model can choose whether and which tools to call.
 * - `required`: the model must call a tool. It can choose which tool to call.
 * - `none`: the model must not call tools
 * - `{ type: 'tool', toolName: string (typed) }`: the model must call the specified tool
 */
export type ToolChoice<TOOLS extends Record<string, unknown>> =
  | 'auto'
  | 'none'
  | 'required'
  | { type: 'tool'; toolName: Extract<keyof TOOLS, string> }
