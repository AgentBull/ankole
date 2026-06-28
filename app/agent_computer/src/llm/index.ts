// Public entry point for the src/llm/ module. It flattens two layers into one import surface:
// the vendored Vercel AI SDK core/provider utilities and the directory exports below, plus
// Ankole's first-party runtime LLM layer (ankole*, catalog, testing). Consumers import from '@/llm'
// and shouldn't need to know which half a symbol came from.

// Side-effect import: installs AI SDK global shims; must run before anything else here.
import './global'

// re-exports:
export {
  asSchema,
  createIdGenerator,
  dynamicTool,
  generateId,
  jsonSchema,
  parseJsonEventStream,
  tool,
  zodSchema,
  type FlexibleSchema,
  type IdGenerator,
  type InferSchema,
  type InferToolInput,
  type InferToolOutput,
  type Schema,
  type Tool,
  type ToolApprovalRequest,
  type ToolApprovalResponse,
  type ToolExecuteFunction,
  type ToolExecutionOptions,
  type ToolSet
} from '@/llm/provider-utils'

// directory exports
export * from './agent'
export * from './embed'
export * from './error'
export * from './generate-image'
export * from './generate-object'
export * from './generate-text'
export * from './logger'
export * from './middleware'
export * from './prompt'
export * from './registry'
export * from './rerank'
export * from './telemetry'
export * from './text-stream'
export * from './transcribe'
export * from './types'
export * from './upload-file'
export * from './upload-skill'
export * from './util'
// --- Ankole's first-party runtime LLM layer (everything above this line is the vendored AI SDK) ---
export {
  ZERO_USAGE,
  calculateCost,
  isContextOverflow,
  parseJsonWithRepair,
  validateToolArguments,
  type Api,
  type AssistantMessage,
  type AssistantMessageEvent,
  type AnkoleTool,
  type CacheRetention,
  type Context,
  type ImageContent,
  type Message,
  type Model,
  type ModelThinkingLevel,
  type ProviderResponse,
  type ReasoningEffort,
  type SimpleStreamOptions,
  type StopReason,
  type StreamOptions,
  type TextContent,
  type ThinkingContent,
  type ThinkingLevel,
  type ThinkingLevelMap,
  type ToolCall,
  type ToolResultMessage,
  type Usage,
  type UserMessage
} from './ankole'
export * from './ankole-ai-sdk'
export * from './catalog'
export * from './testing'
