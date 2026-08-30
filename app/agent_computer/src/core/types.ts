/**
 * Worker agent types for the AIGateway Responses loop.
 *
 * The worker owns tool execution, environment state, and the loop driver.
 * It owns the local Agent loop budget, but not history expansion, compaction,
 * continuation anchors, or durable response state.
 */

import type { z } from 'zod'
import type { TSchema } from 'typebox'
import type {
  AgentTool as PiAgentTool,
  AgentToolResult as PiAgentToolResult,
  AgentToolUpdateCallback
} from '@earendil-works/pi-agent-core'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import type { CustomToolInputFormat } from 'openai/resources/shared'
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
import type { WorkerTurnTrace } from '../observability/turn-tracing'

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
  ToolCaller,
  StatefulResponseContext
} from './llm'

export type AgentLoopLogger = {
  info(event: string, message: string, fields?: JSONObject): void
  warning(event: string, message: string, fields?: JSONObject): void
}

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

  /** Explicit remote parent for turn-local worker spans. */
  turnTrace?: WorkerTurnTrace

  /** Primary model input modalities supplied by the control-plane model ref. */
  modelInputModalities?: string[]

  /** Optional image-capable fallback model used only for image descriptions. */
  visionFallbackModel?: ModelConfig

  /** Available tools. */
  tools?: WorkerAgentTool[]

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

  /** Local tools exposed only during the one protocol-repair round. */
  repairTools?: WorkerAgentTool[]

  /** Hosted tools exposed only during the one protocol-repair round. */
  repairHostedTools?: HostedTool[]

  /** Set false when the caller's protocol repair owns empty responses. */
  nudgeEmptyAfterTools?: boolean

  /** Abort signal for the whole loop. */
  abortSignal?: AbortSignal

  /** Returns steering messages to inject mid-run. */
  getSteeringMessages?: () => Promise<Message[]>

  /** Called for each text delta during streaming. */
  onTextDelta?: (delta: string) => void

  /** Called whenever the loop observes model/provider progress for inactivity tracking. */
  onActivity?: (description?: string) => void

  /** Emits bounded operational diagnostics without prompts, tool data, or provider bodies. */
  logger?: AgentLoopLogger

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
 * Final or partial result produced by a tool.
 *
 * Extends pi-agent-core's own `AgentToolResult` (`content`/`details`/`usage`/
 * `addedToolNames`/`terminate` are its native fields, used as-is) with the two
 * AIGateway-side concerns it has no concept of. pi passes this object through
 * untouched — `presentation`/`completeActorEventIDs` survive on `afterToolCall`'s
 * `result` and on the `tool_execution_end` event, there is no separate side
 * channel to maintain. `content` is overridden to our own `ContentPart` shape
 * (pi's `ImageContent` requires an eager base64 `data` string; ours keeps the
 * lazy `string | URL | Uint8Array | BufferSource` union the rest of the image
 * pipeline — `vision.ts`, `wire.ts` — already relies on) and translated to pi's
 * shape at the `tools.ts` boundary, not at the tool-author boundary.
 */
export interface AgentToolResult<T> extends Omit<PiAgentToolResult<T>, 'content'> {
  content: ContentPart[]
  /** Renderer-safe presentation events emitted alongside this result. */
  presentation?: ReplyPresentationEvent[]
  /** Lifecycle ActorEvents to complete with this tool result journal entry. */
  completeActorEventIDs?: string[]
}

/**
 * Tool definition used by the agent runtime.
 *
 * Extends pi-agent-core's own `AgentTool` (typebox is its first-class schema
 * representation) with the AIGateway wire-protocol fields pi has no concept of
 * (`namespace`, `inputFormat`, Tool Search deferral, programmatic-caller
 * gating) and with a zod-authored `schema`. `schema` is the authoritative
 * definition — `wire.ts` derives the model-visible tool spec from it forever,
 * independent of loop implementation; `parameters` (typebox, inherited from
 * pi's `AgentTool`) is consumed only by pi's own pre-`execute()` gate and is
 * always-passing by construction — the loop's zod gate in `agent-loop.ts`
 * owns argument validation (see `worker-tool.ts`). Construct instances
 * with `defineWorkerTool` (`worker-tool.ts`), not this interface directly.
 */
export interface WorkerAgentTool<TZod extends z.ZodType = z.ZodType, TDetails = any> extends Omit<
  PiAgentTool<TSchema, TDetails>,
  'execute'
> {
  /** zod v4 schema — see the interface doc comment for why this coexists with `parameters`. */
  schema: TZod
  /** Declares a Responses custom tool whose model input is raw text. */
  inputFormat?: CustomToolInputFormat
  /** Optional raw JSON Schema used when a tool comes from an external catalog. */
  jsonSchema?: Record<string, unknown>
  /** Optional result schema from the tool owner. */
  outputSchema?: Record<string, unknown>
  /** Enables provider-side strict validation for this function tool. */
  strict?: boolean
  /** Groups this tool under one Responses namespace. */
  namespace?: string
  namespaceDescription?: string
  /** Hides the schema until Tool Search loads this tool. */
  deferLoading?: boolean
  /** Search corpus supplied by the owning external catalog. */
  toolSearchText?: string
  /** Responses callers that may invoke this tool. */
  allowedCallers?: Array<'direct' | 'programmatic'>
  isReadOnly?: boolean
  isDestructive?: boolean
  /** Builds one bounded user-facing activity label from schema-validated parameters. */
  describeActivity: (params: z.output<TZod>) => ActivityDescription | string | null
  /** Optionally replaces the activity label with a bounded summary of the completed result. */
  describeCompletedActivity?: (params: z.output<TZod>, details: TDetails) => ActivityDescription | string | null
  /** Throw on failure instead of encoding errors in `content` — pi's own tool-loop catches it. */
  execute: (
    toolCallID: string,
    params: z.output<TZod>,
    signal?: AbortSignal,
    onUpdate?: AgentToolUpdateCallback<TDetails>
  ) => Promise<AgentToolResult<TDetails>>
}

export type ActivityDescription = {
  key: string
  bindings?: JSONObject
}
