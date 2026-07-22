/**
 * Worker agent types for the AIGateway Responses loop.
 *
 * The worker owns tool execution, environment state, and the loop driver.
 * It owns the local Agent loop budget, but not history expansion, compaction,
 * continuation anchors, or durable response state.
 */

import type { z } from 'zod'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type {
  AssistantMessage,
  CallModelOptions,
  Message,
  ModelConfig,
  ContentPart,
  HostedTool,
  StatefulResponseContext,
  UserMessage
} from './llm'

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

  /** AIGateway-hosted tools declared by the control plane for this turn. */
  hostedTools?: HostedTool[]

  /** Max main-loop model/API iterations before a final no-tools summary call. */
  maxModelIterations: number

  /** Max output tokens per model call. */
  maxTokens?: number

  /** Temperature. */
  temperature?: number

  /** Optional Responses structured-output contract for the final model text. */
  text?: CallModelOptions['text']

  /**
   * Requests at most one same-conversation correction when a terminal model
   * response violates a caller-owned protocol. Returning undefined accepts the
   * response; semantic rejection must not be converted into a format repair.
   */
  repairFinalResponse?: (message: AssistantMessage) => UserMessage | undefined

  /** Abort signal for the whole loop. */
  abortSignal?: AbortSignal

  /** Returns steering messages to inject mid-run. */
  getSteeringMessages?: () => Promise<Message[]>

  /** Called for each text delta during streaming. */
  onTextDelta?: (delta: string) => void

  /** Called whenever the loop observes model/provider progress for inactivity tracking. */
  onActivity?: (description?: string) => void

  /**
   * Emits renderer-safe semantic progress for the visible reply surface.
   * Raw tool names, arguments, outputs, and provider frames do not belong here.
   */
  onPresentationEvent?: (event: ReplyPresentationEvent) => void | Promise<void>

  /** Runs work that should not count against model/provider inactivity tracking. */
  withActivitySuspended?: <T>(description: string, fn: () => Promise<T>) => Promise<T>
}

export type AgentLoopOutcome = 'loop_finished' | 'iteration_exhausted'

export type AgentLoopResult = {
  message: AssistantMessage
  responseID: string
  outcome: AgentLoopOutcome
}

export type ReplyPresentationEventKind =
  | 'turn.phase'
  | 'plan.snapshot'
  | 'tool.activity'
  | 'memory.lookup'
  | 'memory.mutation_receipt'
  | 'effect.receipt'
  | 'result.table'
  | 'result.chart'
  | 'result.image'
  | 'result.metrics'
  | 'artifact.available'
  | 'interaction.request'

/**
 * Provider-neutral live reply projection emitted by Agent Computer.
 *
 * The control plane supplies the turn fence through RuntimeFabric and assigns
 * no authority to these fields. Every payload is normalized again before a
 * provider renderer can consume it.
 */
export interface ReplyPresentationEvent {
  kind: ReplyPresentationEventKind
  payload: JSONObject
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
  presentation?: ReplyPresentationEvent[]
  /** Lifecycle ActorEvents to complete with this tool result journal entry. */
  completeActorEventIDs?: string[]
  /** Finish the current Agent turn after this result is durably recorded. */
  terminate?: boolean
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
  /** Builds one bounded user-facing activity label from schema-validated parameters. */
  describeActivity: (params: z.output<TParameters>) => string | null
  /** Optionally replaces the activity label with a bounded summary of the completed result. */
  describeCompletedActivity?: (params: z.output<TParameters>, details: TDetails) => string | null
  execute: (
    toolCallID: string,
    params: z.output<TParameters>,
    signal?: AbortSignal
  ) => Promise<AgentToolResult<TDetails>>
}
