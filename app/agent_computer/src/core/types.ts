import type {
  AssistantMessage,
  AssistantMessageEvent,
  Context,
  ImageContent,
  Message,
  Model,
  SimpleStreamOptions,
  TextContent,
  ToolResultMessage
} from '@/llm'
import type { z } from 'zod'

/**
 * Configuration for how tool calls from a single assistant message are executed.
 *
 * - "sequential": each tool call is prepared, executed, and finalized before the next one starts.
 * - "parallel": tool calls are prepared sequentially, then allowed tools execute concurrently.
 *   `tool_execution_end` is emitted in tool completion order after each tool is finalized,
 *   while tool-result message artifacts are emitted later in assistant source order.
 */
export type ToolExecutionMode = 'sequential' | 'parallel'

/** A single tool call content block emitted by an assistant message. */
export type AgentToolCall = Extract<AssistantMessage['content'][number], { type: 'toolCall' }>

/**
 * Result returned from `beforeToolCall`.
 *
 * Returning `{ block: true }` prevents the tool from executing. The loop emits an error tool result instead.
 * `reason` becomes the text shown in that error result. If omitted, a default blocked message is used.
 */
export interface BeforeToolCallResult {
  block?: boolean
  reason?: string
}

/**
 * Partial override returned from `afterToolCall`.
 *
 * Merge semantics are field-by-field:
 * - `content`: if provided, replaces the tool result content array in full
 * - `details`: if provided, replaces the tool result details value in full
 * - `isError`: if provided, replaces the tool result error flag
 * - `terminate`: if provided, replaces the early-termination hint
 *
 * Omitted fields keep the original executed tool result values.
 * There is no deep merge for `content` or `details`.
 */
export interface AfterToolCallResult {
  content?: (TextContent | ImageContent)[]
  details?: unknown
  isError?: boolean
  /**
   * Hint that the agent should stop after the current tool batch.
   * Early termination only happens when every finalized tool result in the batch sets this to true.
   */
  terminate?: boolean
}

/** Context passed to `beforeToolCall`. */
export interface BeforeToolCallContext {
  /** The assistant message that requested the tool call. */
  assistantMessage: AssistantMessage
  /** The raw tool call block from `assistantMessage.content`. */
  toolCall: AgentToolCall
  /** Validated tool arguments for the target tool schema. */
  args: unknown
  /** Current agent context at the time the tool call is prepared. */
  context: AgentContext
}

/** Context passed to `afterToolCall`. */
export interface AfterToolCallContext {
  /** The assistant message that requested the tool call. */
  assistantMessage: AssistantMessage
  /** The raw tool call block from `assistantMessage.content`. */
  toolCall: AgentToolCall
  /** Validated tool arguments for the target tool schema. */
  args: unknown
  /** The executed tool result before any `afterToolCall` overrides are applied. */
  result: AgentToolResult<any>
  /** Whether the executed tool result is currently treated as an error. */
  isError: boolean
  /** Current agent context at the time the tool call is finalized. */
  context: AgentContext
}

/** Context passed to `shouldStopAfterTurn`. */
export interface ShouldStopAfterTurnContext {
  /** The assistant message that completed the turn. */
  message: AssistantMessage
  /** Tool result messages passed to the preceding `turn_end` event. */
  toolResults: ToolResultMessage[]
  /** Current agent context after the turn's assistant message and tool results have been appended. */
  context: AgentContext
  /** Messages that this loop invocation will return if it exits at this point. Prompt runs include the initial prompt messages; continuation runs do not include pre-existing context messages. */
  newMessages: AgentMessage[]
}

/** Replacement runtime state used by the agent loop before starting another provider request. */
export interface AgentLoopTurnUpdate {
  /** Context for the next provider request. */
  context?: AgentContext
  /** Model for the next provider request. */
  model?: Model<any>
  /** Thinking level for the next provider request. */
  thinkingLevel?: ThinkingLevel
}

export interface PrepareNextTurnContext extends ShouldStopAfterTurnContext {}

/** Context passed after AgentMessage[] has been converted to the exact provider-bound LLM context. */
export interface BeforeLlmCallContext {
  /** Agent-level context before provider conversion. */
  context: AgentContext
  /** Agent messages after `transformContext` and before `convertToLlm`. */
  messages: AgentMessage[]
  /** Provider-bound LLM context that will be sent to the AI SDK model. */
  llmContext: Context
  /** Provider-bound messages; same object as `llmContext.messages`, exposed for convenience. */
  llmMessages: Message[]
  /** Model selected for this provider request. */
  model: Model<any>
}

/** Optional request option updates returned from `beforeLlmCall`. */
export interface BeforeLlmCallResult {
  /** Metadata attached to BullX-local provider observability for the immediately following request. */
  metadata?: Record<string, unknown>
}

export interface AgentLoopConfig extends SimpleStreamOptions {
  model: Model<any>

  /**
   * Converts AgentMessage[] to LLM-compatible Message[] before each LLM call.
   *
   * Each AgentMessage must be converted to a UserMessage, AssistantMessage, or ToolResultMessage
   * that the LLM can understand. AgentMessages that cannot be converted (e.g., UI-only notifications,
   * status messages) should be filtered out.
   *
   * Contract: must not throw or reject. Return a safe fallback value instead.
   * Throwing interrupts the low-level agent loop without producing a normal event sequence.
   *
   * @example
   * ```typescript
   * convertToLlm: (messages) => messages.flatMap(m => {
   *   if (m.role === "custom") {
   *     // Convert custom message to user message
   *     return [{ role: "user", content: m.content, timestamp: m.timestamp }];
   *   }
   *   if (m.role === "notification") {
   *     // Filter out UI-only messages
   *     return [];
   *   }
   *   // Pass through standard LLM messages
   *   return [m];
   * })
   * ```
   */
  convertToLlm: (messages: AgentMessage[]) => Message[] | Promise<Message[]>

  /**
   * Optional transform applied to the context before `convertToLlm`.
   *
   * Use this for operations that work at the AgentMessage level:
   * - Context window management (pruning old messages)
   * - Injecting context from external sources
   *
   * Contract: must not throw or reject. Return the original messages or another
   * safe fallback value instead.
   *
   * @example
   * ```typescript
   * transformContext: async (messages) => {
   *   if (estimateTokens(messages) > MAX_TOKENS) {
   *     return pruneOldMessages(messages);
   *   }
   *   return messages;
   * }
   * ```
   */
  transformContext?: (messages: AgentMessage[], signal?: AbortSignal) => Promise<AgentMessage[]>

  /**
   * Called after each turn fully completes and `turn_end` has been emitted.
   *
   * If it returns true, the loop emits `agent_end` and exits before polling steering or follow-up queues,
   * without starting another LLM call. The current assistant response and any tool executions finish normally.
   *
   * Use this to request a graceful stop after the current turn, e.g. before context gets too full.
   *
   * Contract: must not throw or reject. Throwing interrupts the low-level agent loop without producing a normal event sequence.
   */
  shouldStopAfterTurn?: (context: ShouldStopAfterTurnContext) => boolean | Promise<boolean>

  /**
   * Called after `turn_end` and before the loop decides whether another provider request should start.
   * Return replacement context/model/thinking state to affect the next turn in this run.
   * Return undefined to keep using the current context/config.
   */
  prepareNextTurn?: (
    context: PrepareNextTurnContext
  ) => AgentLoopTurnUpdate | undefined | Promise<AgentLoopTurnUpdate | undefined>

  /**
   * Called after `transformContext` and `convertToLlm`, immediately before the provider request.
   *
   * This is the only point where the exact model-visible request shape is available.
   * Return metadata to attach to BullX-local observability for the immediately following request.
   */
  beforeLlmCall?: (
    context: BeforeLlmCallContext,
    signal?: AbortSignal
  ) => BeforeLlmCallResult | undefined | Promise<BeforeLlmCallResult | undefined>

  /**
   * Returns steering messages to inject into the conversation mid-run.
   *
   * Called after the current assistant turn finishes executing its tool calls, unless `shouldStopAfterTurn` exits first.
   * If messages are returned, they are added to the context before the next LLM call.
   * Tool calls from the current assistant message are not skipped.
   *
   * Use this for "steering" the agent while it's working.
   *
   * Contract: must not throw or reject. Return [] when no steering messages are available.
   */
  getSteeringMessages?: () => Promise<AgentMessage[]>

  /**
   * Returns follow-up messages to process after the agent would otherwise stop.
   *
   * Called when the agent has no more tool calls and no steering messages.
   * If messages are returned, they're added to the context and the agent
   * continues with another turn.
   *
   * Use this for follow-up messages that should wait until the agent finishes.
   *
   * Contract: must not throw or reject. Return [] when no follow-up messages are available.
   */
  getFollowUpMessages?: () => Promise<AgentMessage[]>

  /**
   * Tool execution mode.
   * - "sequential": execute tool calls one by one
   * - "parallel": preflight tool calls sequentially, then execute allowed tools concurrently;
   *   emit `tool_execution_end` in tool completion order after each tool is finalized,
   *   then emit tool-result message artifacts later in assistant source order
   *
   * Default: "parallel"
   */
  toolExecution?: ToolExecutionMode

  /**
   * Hard cap on the number of LLM turns in a single loop run. When the cap is
   * reached the loop runs one final tool-free "grace" turn (asking the model to
   * summarize) so a runaway tool-calling model yields a usable answer instead of
   * looping forever. Undefined means no cap (the historical behavior).
   */
  maxTurns?: number

  /**
   * When true, an empty assistant reply that arrives immediately after tool results
   * triggers a single nudge (an injected user message) to continue, instead of
   * silently ending the run on a model hiccup. Re-armed per loop run.
   */
  nudgeOnEmptyAfterTools?: boolean

  /**
   * Called before a tool is executed, after arguments have been validated.
   *
   * Return `{ block: true }` to prevent execution. The loop emits an error tool result instead.
   * The hook receives the agent abort signal and is responsible for honoring it.
   */
  beforeToolCall?: (context: BeforeToolCallContext, signal?: AbortSignal) => Promise<BeforeToolCallResult | undefined>

  /**
   * Called after a tool finishes executing, before `tool_execution_end` and tool-result message events are emitted.
   *
   * Return an `AfterToolCallResult` to override parts of the executed tool result:
   * - `content` replaces the full content array
   * - `details` replaces the full details payload
   * - `isError` replaces the error flag
   * - `terminate` replaces the early-termination hint
   *
   * Any omitted fields keep their original values. No deep merge is performed.
   * The hook receives the agent abort signal and is responsible for honoring it.
   */
  afterToolCall?: (context: AfterToolCallContext, signal?: AbortSignal) => Promise<AfterToolCallResult | undefined>
}

/**
 * Thinking/reasoning level for models that support it.
 * Note: "xhigh" is only supported by selected model families. Use model thinking-level metadata
 * from @/llm to detect support for a concrete model.
 */
export type ThinkingLevel = 'off' | 'minimal' | 'low' | 'medium' | 'high' | 'xhigh'

/**
 * Extensible interface for custom app messages.
 * Apps can extend via declaration merging:
 *
 * @example
 * ```typescript
 * declare module "@mariozechner/agent" {
 *   interface CustomAgentMessages {
 *     artifact: ArtifactMessage;
 *     notification: NotificationMessage;
 *   }
 * }
 * ```
 */
export interface CustomAgentMessages {
  // Empty by default - apps extend via declaration merging
}

/**
 * AgentMessage: Union of LLM messages + custom messages.
 * This abstraction allows apps to add custom message types while maintaining
 * type safety and compatibility with the base LLM messages.
 */
export type AgentMessage = Message | CustomAgentMessages[keyof CustomAgentMessages]

/** Final or partial result produced by a tool. */
export interface AgentToolResult<T> {
  /** Text or image content returned to the model. */
  content: (TextContent | ImageContent)[]
  /** Arbitrary structured details for logs or UI rendering. */
  details: T
  /**
   * Hint that the agent should stop after the current tool batch.
   * Early termination only happens when every finalized tool result in the batch sets this to true.
   */
  terminate?: boolean
}

/** Callback used by tools to stream partial execution updates. */
export type AgentToolUpdateCallback<T = any> = (partialResult: AgentToolResult<T>) => void

/** Tool definition used by the agent runtime. */
export interface AgentTool<TParameters extends z.ZodType = z.ZodType, TDetails = any> {
  name: string
  description: string
  /** Zod schema owned by BullX business code. */
  schema: TParameters
  /** Human-readable label for UI display. */
  label: string
  /**
   * Optional compatibility shim for raw tool-call arguments before schema validation.
   * Must return an object that matches `TParameters`.
   */
  prepareArguments?: (args: unknown) => z.output<TParameters>
  /**
   * Execute the tool call. Throw on failure instead of encoding errors in `content`: the loop catches
   * the throw, turns it into an error tool result, and feeds that back to the model. Honor `signal`;
   * call `onUpdate` to stream partial progress for live UI.
   */
  execute: (
    toolCallId: string,
    params: z.output<TParameters>,
    signal?: AbortSignal,
    onUpdate?: AgentToolUpdateCallback<TDetails>
  ) => Promise<AgentToolResult<TDetails>>
  /**
   * Per-tool execution mode override.
   * - "sequential": this tool must execute one at a time with other tool calls.
   * - "parallel": this tool can execute concurrently with other tool calls.
   *
   * If omitted, the default execution mode applies.
   */
  executionMode?: ToolExecutionMode
  /**
   * Declared (fail-closed) read-only hint — true means the tool only reads state.
   * Bullx tool-layer metadata set via `buildTool`; not consumed by the AI SDK loop,
   * reserved for the permission gate. Defaults to false (treated as a write).
   */
  isReadOnly?: boolean
  /**
   * Declared (fail-closed) destructive hint. Defaults to true (treated as
   * potentially destructive) so a new tool must explicitly opt out.
   */
  isDestructive?: boolean
}

/** Context snapshot passed into the low-level agent loop. */
export interface AgentContext {
  /** System prompt included with the request. */
  systemPrompt: string
  /** Transcript visible to the model. */
  messages: AgentMessage[]
  /** Tools available for this run. */
  tools?: AgentTool<any>[]
}

/**
 * Events emitted by the Agent for UI updates.
 *
 * `agent_end` is the last event emitted for a run, but awaited `Agent.subscribe()`
 * listeners for that event are still part of run settlement. The agent becomes
 * idle only after those listeners finish.
 */
export type AgentEvent =
  // Agent lifecycle
  | { type: 'agent_start' }
  | { type: 'agent_end'; messages: AgentMessage[] }
  // Turn lifecycle - a turn is one assistant response + any tool calls/results
  | { type: 'turn_start' }
  | { type: 'turn_end'; message: AgentMessage; toolResults: ToolResultMessage[] }
  | { type: 'max_turns_reached'; maxTurns: number; turnCount: number }
  // Message lifecycle - emitted for user, assistant, and toolResult messages
  | { type: 'message_start'; message: AgentMessage }
  // Only emitted for assistant messages during streaming
  | { type: 'message_update'; message: AgentMessage; assistantMessageEvent: AssistantMessageEvent }
  | { type: 'message_end'; message: AgentMessage }
  // Tool execution lifecycle. In parallel mode `tool_execution_end` fires in completion order (whichever
  // tool finishes first), but the corresponding tool-result `message_start`/`message_end` are emitted
  // afterward in assistant source order, so the transcript stays in the order the model issued the calls.
  | { type: 'tool_execution_start'; toolCallId: string; toolName: string; args: any }
  | { type: 'tool_execution_update'; toolCallId: string; toolName: string; args: any; partialResult: any }
  | { type: 'tool_execution_end'; toolCallId: string; toolName: string; args: any; result: any; isError: boolean }
