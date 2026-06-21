import { type ImageContent, type Message, type Model, type SimpleStreamOptions, type TextContent } from '@/llm'
import { runAgentLoop, runAgentLoopContinue } from './agent-loop'
import { textFromAgentMessage } from './bullx'
import type {
  AfterToolCallContext,
  AfterToolCallResult,
  AgentContext,
  AgentEvent,
  AgentLoopConfig,
  AgentLoopTurnUpdate,
  AgentMessage,
  AgentState,
  AgentTool,
  BeforeLlmCallContext,
  BeforeLlmCallResult,
  BeforeToolCallContext,
  BeforeToolCallResult,
  QueueMode,
  ShouldStopAfterTurnContext,
  ToolExecutionMode
} from './types'

export type { QueueMode } from './types'

// Fallback used when the caller supplies no `convertToLlm`: keep only the three message roles the
// provider understands and drop everything custom (notifications, compaction summaries, UI-only rows).
// Real BullX runs pass their own converter via harness/messages; this just keeps a bare Agent usable.
function defaultConvertToLlm(messages: AgentMessage[]): Message[] {
  return messages.filter(
    message => message.role === 'user' || message.role === 'assistant' || message.role === 'toolResult'
  )
}

const EMPTY_USAGE = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
}

// Placeholder model so an Agent constructed without one is still well-typed and can emit failure
// messages; any real run overwrites `state.model`. The zeroed cost/window means it can never actually
// call a provider, which is intentional — it forces the caller to set a model first.
const DEFAULT_MODEL = {
  id: 'unknown',
  name: 'unknown',
  api: 'unknown',
  provider: 'unknown',
  baseUrl: '',
  reasoning: false,
  input: [],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 0,
  maxTokens: 0
} satisfies Model<any>

type MutableAgentState = Omit<AgentState, 'isStreaming' | 'streamingMessage' | 'pendingToolCalls' | 'errorMessage'> & {
  isStreaming: boolean
  streamingMessage?: AgentMessage
  pendingToolCalls: Set<string>
  errorMessage?: string
}

// Builds the live state object. `tools` and `messages` are exposed through accessors that copy on both
// read-in (constructor `.slice()`) and assign, so a caller holding the array it passed in cannot mutate
// the agent's transcript out from under a run, and vice-versa. Every other field is a plain mutable
// property the loop's event reducer writes to directly.
function createMutableAgentState(
  initialState?: Partial<Omit<AgentState, 'pendingToolCalls' | 'isStreaming' | 'streamingMessage' | 'errorMessage'>>
): MutableAgentState {
  let tools = initialState?.tools?.slice() ?? []
  let messages = initialState?.messages?.slice() ?? []

  return {
    systemPrompt: initialState?.systemPrompt ?? '',
    model: initialState?.model ?? DEFAULT_MODEL,
    thinkingLevel: initialState?.thinkingLevel ?? 'off',
    get tools() {
      return tools
    },
    set tools(nextTools: AgentTool<any>[]) {
      tools = nextTools.slice()
    },
    get messages() {
      return messages
    },
    set messages(nextMessages: AgentMessage[]) {
      messages = nextMessages.slice()
    },
    isStreaming: false,
    streamingMessage: undefined,
    pendingToolCalls: new Set<string>(),
    errorMessage: undefined
  }
}

/** Options for constructing an {@link Agent}. */
export interface AgentOptions {
  initialState?: Partial<Omit<AgentState, 'pendingToolCalls' | 'isStreaming' | 'streamingMessage' | 'errorMessage'>>
  convertToLlm?: (messages: AgentMessage[]) => Message[] | Promise<Message[]>
  transformContext?: (messages: AgentMessage[], signal?: AbortSignal) => Promise<AgentMessage[]>
  onPayload?: SimpleStreamOptions['onPayload']
  onResponse?: SimpleStreamOptions['onResponse']
  /**
   * Fired on every streaming message update with the assistant answer text so
   * far (thinking excluded). Used to drive live streaming-card rendering. Must
   * not throw — exceptions are swallowed so they never break the run.
   */
  onStreamingText?: (fullText: string) => void
  beforeToolCall?: (context: BeforeToolCallContext, signal?: AbortSignal) => Promise<BeforeToolCallResult | undefined>
  afterToolCall?: (context: AfterToolCallContext, signal?: AbortSignal) => Promise<AfterToolCallResult | undefined>
  beforeLlmCall?: (
    context: BeforeLlmCallContext,
    signal?: AbortSignal
  ) => Promise<BeforeLlmCallResult | undefined> | BeforeLlmCallResult | undefined
  shouldStopAfterTurn?: (context: ShouldStopAfterTurnContext) => boolean | Promise<boolean>
  prepareNextTurn?: (signal?: AbortSignal) => Promise<AgentLoopTurnUpdate | undefined> | AgentLoopTurnUpdate | undefined
  steeringMode?: QueueMode
  followUpMode?: QueueMode
  requestOptions?: SimpleStreamOptions
  toolExecution?: ToolExecutionMode
  /** Hard cap on LLM turns per run; on reaching it a tool-free grace summary turn runs, then the loop stops. */
  maxTurns?: number
  /** Nudge the model to continue once when it returns an empty reply right after tool results. */
  nudgeOnEmptyAfterTools?: boolean
}

/**
 * FIFO buffer for steering and follow-up messages waiting to be injected between turns.
 *
 * `drain()` honors `mode`: "all" empties the queue at once, while "one-at-a-time" releases just the
 * oldest message and leaves the rest for the next drain point. One-at-a-time is the default so a burst
 * of user messages is fed in one per turn, letting the model react to each before seeing the next.
 */
class PendingMessageQueue {
  private messages: AgentMessage[] = []
  public mode: QueueMode

  constructor(mode: QueueMode) {
    this.mode = mode
  }

  enqueue(message: AgentMessage): void {
    this.messages.push(message)
  }

  hasItems(): boolean {
    return this.messages.length > 0
  }

  drain(): AgentMessage[] {
    if (this.mode === 'all') {
      const drained = this.messages.slice()
      this.messages = []
      return drained
    }

    const first = this.messages[0]
    if (!first) {
      return []
    }
    this.messages = this.messages.slice(1)
    return [first]
  }

  clear(): void {
    this.messages = []
  }
}

type ActiveRun = {
  promise: Promise<void>
  resolve: () => void
  abortController: AbortController
}

/**
 * Stateful wrapper around the low-level agent loop.
 *
 * `Agent` owns the current transcript, emits lifecycle events, executes tools,
 * and exposes queueing APIs for steering and follow-up messages.
 */
export class Agent {
  private _state: MutableAgentState
  private readonly listeners = new Set<(event: AgentEvent, signal: AbortSignal) => Promise<void> | void>()
  private readonly steeringQueue: PendingMessageQueue
  private readonly followUpQueue: PendingMessageQueue

  public convertToLlm: (messages: AgentMessage[]) => Message[] | Promise<Message[]>
  public transformContext?: (messages: AgentMessage[], signal?: AbortSignal) => Promise<AgentMessage[]>
  public onPayload?: SimpleStreamOptions['onPayload']
  public onResponse?: SimpleStreamOptions['onResponse']
  public onStreamingText?: (fullText: string) => void
  public beforeToolCall?: (
    context: BeforeToolCallContext,
    signal?: AbortSignal
  ) => Promise<BeforeToolCallResult | undefined>
  public afterToolCall?: (
    context: AfterToolCallContext,
    signal?: AbortSignal
  ) => Promise<AfterToolCallResult | undefined>
  public beforeLlmCall?: (
    context: BeforeLlmCallContext,
    signal?: AbortSignal
  ) => Promise<BeforeLlmCallResult | undefined> | BeforeLlmCallResult | undefined
  public shouldStopAfterTurn?: (context: ShouldStopAfterTurnContext) => boolean | Promise<boolean>
  public prepareNextTurn?: (
    signal?: AbortSignal
  ) => Promise<AgentLoopTurnUpdate | undefined> | AgentLoopTurnUpdate | undefined
  private activeRun?: ActiveRun
  public requestOptions?: SimpleStreamOptions
  /** Tool execution strategy for assistant messages that contain multiple tool calls. */
  public toolExecution: ToolExecutionMode
  /** Hard cap on LLM turns per run; on reaching it a tool-free grace summary turn runs, then the loop stops. */
  public maxTurns?: number
  /** Nudge the model to continue once when it returns an empty reply right after tool results. */
  public nudgeOnEmptyAfterTools: boolean

  constructor(options: AgentOptions = {}) {
    this._state = createMutableAgentState(options.initialState)
    this.convertToLlm = options.convertToLlm ?? defaultConvertToLlm
    this.transformContext = options.transformContext
    this.onPayload = options.onPayload
    this.onResponse = options.onResponse
    this.onStreamingText = options.onStreamingText
    this.beforeToolCall = options.beforeToolCall
    this.afterToolCall = options.afterToolCall
    this.beforeLlmCall = options.beforeLlmCall
    this.shouldStopAfterTurn = options.shouldStopAfterTurn
    this.prepareNextTurn = options.prepareNextTurn
    this.steeringQueue = new PendingMessageQueue(options.steeringMode ?? 'one-at-a-time')
    this.followUpQueue = new PendingMessageQueue(options.followUpMode ?? 'one-at-a-time')
    this.requestOptions = options.requestOptions
    this.toolExecution = options.toolExecution ?? 'parallel'
    this.maxTurns = options.maxTurns
    this.nudgeOnEmptyAfterTools = options.nudgeOnEmptyAfterTools ?? false
  }

  /**
   * Subscribe to agent lifecycle events.
   *
   * Listener promises are awaited in subscription order and are included in
   * the current run's settlement. Listeners also receive the active abort
   * signal for the current run.
   *
   * `agent_end` is the final emitted event for a run, but the agent does not
   * become idle until all awaited listeners for that event have settled.
   */
  subscribe(listener: (event: AgentEvent, signal: AbortSignal) => Promise<void> | void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /**
   * Current agent state.
   *
   * Assigning `state.tools` or `state.messages` copies the provided top-level array.
   */
  get state(): AgentState {
    return this._state
  }

  /** Controls how queued steering messages are drained. */
  set steeringMode(mode: QueueMode) {
    this.steeringQueue.mode = mode
  }

  get steeringMode(): QueueMode {
    return this.steeringQueue.mode
  }

  /** Controls how queued follow-up messages are drained. */
  set followUpMode(mode: QueueMode) {
    this.followUpQueue.mode = mode
  }

  get followUpMode(): QueueMode {
    return this.followUpQueue.mode
  }

  /** Queue a message to be injected after the current assistant turn finishes. */
  steer(message: AgentMessage): void {
    this.steeringQueue.enqueue(message)
  }

  /** Queue a message to run only after the agent would otherwise stop. */
  followUp(message: AgentMessage): void {
    this.followUpQueue.enqueue(message)
  }

  /** Remove all queued steering messages. */
  clearSteeringQueue(): void {
    this.steeringQueue.clear()
  }

  /** Remove all queued follow-up messages. */
  clearFollowUpQueue(): void {
    this.followUpQueue.clear()
  }

  /** Remove all queued steering and follow-up messages. */
  clearAllQueues(): void {
    this.clearSteeringQueue()
    this.clearFollowUpQueue()
  }

  /** Returns true when either queue still contains pending messages. */
  hasQueuedMessages(): boolean {
    return this.steeringQueue.hasItems() || this.followUpQueue.hasItems()
  }

  /** Active abort signal for the current run, if any. */
  get signal(): AbortSignal | undefined {
    return this.activeRun?.abortController.signal
  }

  /** Abort the current run, if one is active. */
  abort(): void {
    this.activeRun?.abortController.abort()
  }

  /**
   * Resolve when the current run and all awaited event listeners have finished.
   *
   * This resolves after `agent_end` listeners settle.
   */
  waitForIdle(): Promise<void> {
    return this.activeRun?.promise ?? Promise.resolve()
  }

  /** Clear transcript state, runtime state, and queued messages. */
  reset(): void {
    this._state.messages = []
    this._state.isStreaming = false
    this._state.streamingMessage = undefined
    this._state.pendingToolCalls = new Set<string>()
    this._state.errorMessage = undefined
    this.clearFollowUpQueue()
    this.clearSteeringQueue()
  }

  /** Start a new prompt from text, a single message, or a batch of messages. */
  async prompt(message: AgentMessage | AgentMessage[]): Promise<void>
  async prompt(input: string, images?: ImageContent[]): Promise<void>
  async prompt(input: string | AgentMessage | AgentMessage[], images?: ImageContent[]): Promise<void> {
    if (this.activeRun) {
      throw new Error(
        'Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion.'
      )
    }
    const messages = this.normalizePromptInput(input, images)
    await this.runPromptMessages(messages)
  }

  /** Continue from the current transcript. The last message must be a user or tool-result message. */
  async continue(): Promise<void> {
    if (this.activeRun) {
      throw new Error('Agent is already processing. Wait for completion before continuing.')
    }

    const lastMessage = this._state.messages[this._state.messages.length - 1]
    if (!lastMessage) {
      throw new Error('No messages to continue from')
    }

    // A transcript ending in an assistant message has nothing for the model to answer, so a plain
    // continuation is invalid. But if messages were queued while it was idle, treat those as the new
    // prompt instead of erroring: steering first (more urgent), then follow-ups.
    if (lastMessage.role === 'assistant') {
      const queuedSteering = this.steeringQueue.drain()
      if (queuedSteering.length > 0) {
        // We already drained here, so tell the loop to skip its own opening steering poll — otherwise
        // it would drain the queue a second time and could inject a later steering message twice.
        await this.runPromptMessages(queuedSteering, { skipInitialSteeringPoll: true })
        return
      }

      const queuedFollowUps = this.followUpQueue.drain()
      if (queuedFollowUps.length > 0) {
        await this.runPromptMessages(queuedFollowUps)
        return
      }

      throw new Error('Cannot continue from message role: assistant')
    }

    await this.runContinuation()
  }

  private normalizePromptInput(input: string | AgentMessage | AgentMessage[], images?: ImageContent[]): AgentMessage[] {
    if (Array.isArray(input)) {
      return input
    }

    if (typeof input !== 'string') {
      return [input]
    }

    const content: Array<TextContent | ImageContent> = [{ type: 'text', text: input }]
    if (images && images.length > 0) {
      content.push(...images)
    }
    return [{ role: 'user', content, timestamp: Date.now() }]
  }

  private async runPromptMessages(
    messages: AgentMessage[],
    options: { skipInitialSteeringPoll?: boolean } = {}
  ): Promise<void> {
    await this.runWithLifecycle(async signal => {
      await runAgentLoop(
        messages,
        this.createContextSnapshot(),
        this.createLoopConfig(options),
        event => this.processEvents(event),
        signal
      )
    })
  }

  private async runContinuation(): Promise<void> {
    await this.runWithLifecycle(async signal => {
      await runAgentLoopContinue(
        this.createContextSnapshot(),
        this.createLoopConfig(),
        event => this.processEvents(event),
        signal
      )
    })
  }

  private createContextSnapshot(): AgentContext {
    return {
      systemPrompt: this._state.systemPrompt,
      messages: this._state.messages.slice(),
      tools: this._state.tools.slice()
    }
  }

  // Snapshots the agent's current config/hooks into the plain object the loop expects. Re-built per run
  // so each run sees the model/thinking level current at start. Spreading `requestOptions` first lets
  // the explicit fields below win over anything it carries.
  private createLoopConfig(options: { skipInitialSteeringPoll?: boolean } = {}): AgentLoopConfig {
    // Closed-over one-shot latch: when `continue()` already drained steering for this run, the first
    // `getSteeringMessages` call returns [] and re-arms; later calls poll the queue normally.
    let skipInitialSteeringPoll = options.skipInitialSteeringPoll === true
    return {
      model: this._state.model,
      ...this.requestOptions,
      // `thinkingLevel: 'off'` maps to the loop's `'none'` reasoning sentinel.
      reasoning: this._state.thinkingLevel === 'off' ? 'none' : this._state.thinkingLevel,
      onPayload: this.onPayload ?? this.requestOptions?.onPayload,
      onResponse: this.onResponse ?? this.requestOptions?.onResponse,
      toolExecution: this.toolExecution,
      maxTurns: this.maxTurns,
      nudgeOnEmptyAfterTools: this.nudgeOnEmptyAfterTools,
      beforeToolCall: this.beforeToolCall,
      afterToolCall: this.afterToolCall,
      beforeLlmCall: this.beforeLlmCall
        ? async (context, signal) => await this.beforeLlmCall?.(context, signal)
        : undefined,
      shouldStopAfterTurn: this.shouldStopAfterTurn,
      prepareNextTurn: this.prepareNextTurn ? async () => await this.prepareNextTurn?.(this.signal) : undefined,
      convertToLlm: this.convertToLlm,
      transformContext: this.transformContext,
      getSteeringMessages: async () => {
        if (skipInitialSteeringPoll) {
          skipInitialSteeringPoll = false
          return []
        }
        return this.steeringQueue.drain()
      },
      getFollowUpMessages: async () => this.followUpQueue.drain()
    }
  }

  // Single entry/exit gate around any loop invocation. Installs the `activeRun` token (the thing
  // `prompt`/`continue` check to refuse re-entrancy, and `waitForIdle` awaits), flips streaming state,
  // runs the body, and guarantees teardown. The `resolve` is captured out of the Promise executor so
  // `finishRun` can settle `waitForIdle` from the `finally`.
  private async runWithLifecycle(executor: (signal: AbortSignal) => Promise<void>): Promise<void> {
    if (this.activeRun) {
      throw new Error('Agent is already processing.')
    }

    const abortController = new AbortController()
    let resolvePromise = () => {}
    const promise = new Promise<void>(resolve => {
      resolvePromise = resolve
    })
    this.activeRun = { promise, resolve: resolvePromise, abortController }

    this._state.isStreaming = true
    this._state.streamingMessage = undefined
    this._state.errorMessage = undefined

    try {
      await executor(abortController.signal)
    } catch (error) {
      // The loop is contracted not to throw in normal operation, so reaching here means an unexpected
      // failure (e.g. a hook that broke its no-throw contract). Convert it into a normal-shaped event
      // sequence instead of letting the throw escape, so subscribers settle cleanly.
      await this.handleRunFailure(error, abortController.signal.aborted)
    } finally {
      this.finishRun()
    }
  }

  // Synthesizes the message/turn/agent_end events the loop would normally emit, carrying a stopReason
  // of 'aborted' vs 'error' and the flattened cause chain. This keeps the failure path observationally
  // identical to a clean run for every subscriber (UI, recorder), so nothing downstream needs a
  // separate "the run threw" code path.
  private async handleRunFailure(error: unknown, aborted: boolean): Promise<void> {
    const failureMessage = {
      role: 'assistant',
      content: [{ type: 'text', text: '' }],
      api: this._state.model.api,
      provider: this._state.model.provider,
      model: this._state.model.id,
      usage: EMPTY_USAGE,
      stopReason: aborted ? 'aborted' : 'error',
      errorMessage: agentErrorMessage(error),
      timestamp: Date.now()
    } satisfies AgentMessage
    await this.processEvents({ type: 'message_start', message: failureMessage })
    await this.processEvents({ type: 'message_end', message: failureMessage })
    await this.processEvents({ type: 'turn_end', message: failureMessage, toolResults: [] })
    await this.processEvents({ type: 'agent_end', messages: [failureMessage] })
  }

  private finishRun(): void {
    this._state.isStreaming = false
    this._state.streamingMessage = undefined
    this._state.pendingToolCalls = new Set<string>()
    this.activeRun?.resolve()
    this.activeRun = undefined
  }

  /**
   * Reduce internal state for a loop event, then await listeners.
   *
   * `agent_end` only means no further loop events will be emitted. The run is
   * considered idle later, after all awaited listeners for `agent_end` finish
   * and `finishRun()` clears runtime-owned state.
   */
  private async processEvents(event: AgentEvent): Promise<void> {
    switch (event.type) {
      case 'message_start':
        this._state.streamingMessage = event.message
        break

      case 'message_update':
        this._state.streamingMessage = event.message
        if (this.onStreamingText) {
          try {
            this.onStreamingText(textFromAgentMessage(event.message))
          } catch {
            // Streaming-card rendering is decorative; never let it break the run.
          }
        }
        break

      case 'message_end':
        this._state.streamingMessage = undefined
        this._state.messages.push(event.message)
        break

      // pendingToolCalls is rebuilt as a fresh Set on every change rather than mutated in place: the
      // getter hands the live Set out as ReadonlySet, and copy-on-write means a consumer that snapshot
      // the previous value sees a stable set, not one that mutates under it mid-render.
      case 'tool_execution_start': {
        const pendingToolCalls = new Set(this._state.pendingToolCalls)
        pendingToolCalls.add(event.toolCallId)
        this._state.pendingToolCalls = pendingToolCalls
        break
      }

      case 'tool_execution_end': {
        const pendingToolCalls = new Set(this._state.pendingToolCalls)
        pendingToolCalls.delete(event.toolCallId)
        this._state.pendingToolCalls = pendingToolCalls
        break
      }

      case 'turn_end':
        if (event.message.role === 'assistant' && event.message.errorMessage) {
          this._state.errorMessage = event.message.errorMessage
        }
        break

      case 'agent_end':
        this._state.streamingMessage = undefined
        break
    }

    // Every emitted event belongs to a run, so the signal must exist here; its absence is a real
    // invariant break (an event escaping outside a run) and is surfaced rather than silently ignored.
    const signal = this.activeRun?.abortController.signal
    if (!signal) {
      throw new Error('Agent listener invoked outside active run')
    }
    // Listeners run serially in subscription order and are awaited, so a slow subscriber backpressures
    // the loop and `agent_end` settlement waits on all of them (see the class/subscribe docs).
    for (const listener of this.listeners) {
      await listener(event, signal)
    }
  }
}

// Flattens an error (and its whole cause chain) into one human-readable string for the failure
// message's `errorMessage`. Walks nested causes and, for Drizzle/Postgres errors, lifts the structured
// fields (constraint, detail, ...) into the text — without this a DB write failure would read as a
// generic "Failed query" and lose the constraint name an operator needs. See agent.test.ts.
function agentErrorMessage(error: unknown): string {
  const messages: string[] = []
  collectErrorMessages(error, messages, new WeakSet<object>())
  // Joined with "Caused by:" to mirror the cause chain; deduped so a message repeated at several
  // wrapping levels does not appear twice.
  return dedupeMessages(messages).join('\nCaused by: ') || 'Unknown error'
}

function collectErrorMessages(error: unknown, messages: string[], seen: WeakSet<object>, depth = 0): void {
  if (error === undefined || error === null || depth > 12) return
  if (typeof error === 'string') {
    messages.push(error)
    return
  }
  if (typeof error !== 'object') {
    messages.push(String(error))
    return
  }
  if (seen.has(error)) return
  seen.add(error)

  if (error instanceof Error && error.message) messages.push(error.message)
  const record = error as Record<string, unknown>
  // Postgres/Drizzle error metadata. These never live in `.message`, so harvest them explicitly to
  // make a constraint violation diagnosable from the surfaced text alone.
  for (const key of ['code', 'constraint', 'detail', 'hint', 'table', 'column']) {
    const value = record[key]
    if (typeof value === 'string' && value.trim()) messages.push(`${key}: ${value}`)
  }
  for (const key of ['cause', 'error', 'response', 'data']) {
    const nested = record[key]
    if (nested && nested !== error) collectErrorMessages(nested, messages, seen, depth + 1)
  }
}

function dedupeMessages(messages: string[]): string[] {
  const seen = new Set<string>()
  const result: string[] = []
  for (const message of messages) {
    const normalized = message.trim()
    if (!normalized || seen.has(normalized)) continue
    seen.add(normalized)
    result.push(normalized)
  }
  return result
}
