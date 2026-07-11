/**
 * Worker agent types for the AIGateway Responses loop.
 *
 * The worker owns tool execution, environment state, and the loop driver.
 * It owns the local Agent loop budget, but not history expansion, compaction,
 * continuation anchors, or durable response state.
 */

import type { z } from 'zod'
import type { AssistantMessage, Message, ModelConfig, ContentPart, StatefulResponseContext } from './llm'

// Re-export the core LLM types so consumers can import from one place.
export type {
  AssistantMessage,
  Message,
  UserMessage,
  ToolResultMessage,
  ModelConfig,
  ModelUsage,
  StopReason,
  TextContent,
  ImageContent,
  ContentPart,
  ToolCall,
  ToolDefinition,
  ToolSet,
  ModelCallResult,
  CallModelOptions,
  StatefulResponseContext
} from './llm'

/**
 * Configuration for the agent loop. The worker drives the loop:
 * call model → execute tools → feed results → repeat until no tool calls.
 */
export interface AgentLoopConfig {
  /** The model to call through AIGateway. */
  model: ModelConfig

  /** System prompt for this run. */
  systemPrompt?: string

  /** Initial messages (user input). */
  messages: Message[]

  /** AIGateway stateful response context for worker-driven response.create rounds. */
  stateful: StatefulResponseContext

  /** Primary model input modalities supplied by the control-plane model ref. */
  modelInputModalities?: string[]

  /** Optional image-capable fallback model used only for image descriptions. */
  visionFallbackModel?: ModelConfig

  /** Available tools. */
  tools?: AgentTool[]

  /** Max main-loop model/API iterations before a final no-tools summary call. */
  maxModelIterations: number

  /** Max output tokens per model call. */
  maxTokens?: number

  /** Temperature. */
  temperature?: number

  /** Abort signal for the whole loop. */
  abortSignal?: AbortSignal

  /** Returns steering messages to inject mid-run. */
  getSteeringMessages?: () => Promise<Message[]>

  /** Called for each text delta during streaming. */
  onTextDelta?: (delta: string) => void

  /** Called whenever the loop observes model/provider progress for inactivity tracking. */
  onActivity?: (description?: string) => void

  /** Runs work that should not count against model/provider inactivity tracking. */
  withActivitySuspended?: <T>(description: string, fn: () => Promise<T>) => Promise<T>
}

export type AgentLoopOutcome = 'loop_finished' | 'iteration_exhausted'

export type AgentLoopResult = {
  message: AssistantMessage
  responseID: string
  outcome: AgentLoopOutcome
}

/**
 * Extensible interface for custom app messages.
 */
export interface CustomAgentMessages {}

/**
 * AgentMessage: Union of LLM messages + custom messages.
 */
export type AgentMessage = Message | CustomAgentMessages[keyof CustomAgentMessages]

/**
 * Final or partial result produced by a tool.
 */
export interface AgentToolResult<T> {
  content: ContentPart[]
  details: T
}

/**
 * Tool definition used by the agent runtime.
 */
export type AgentToolExecutionMode = 'parallel' | 'sequential'

export interface AgentTool<TParameters extends z.ZodType = z.ZodType, TDetails = any> {
  name: string
  description: string
  schema: TParameters
  executionMode?: AgentToolExecutionMode
  isReadOnly?: boolean
  isDestructive?: boolean
  execute: (
    toolCallID: string,
    params: z.output<TParameters>,
    signal?: AbortSignal
  ) => Promise<AgentToolResult<TDetails>>
}
