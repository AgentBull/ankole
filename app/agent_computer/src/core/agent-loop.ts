/**
 * Agent loop — worker-driven Responses loop, orchestrated by pi-agent-core's
 * `Agent` class over the existing AIGateway stateful Responses transport.
 *
 * `Agent` drives the model/tool round-trip natively (`packages/agent`); this
 * file supplies the pieces pi has no concept of: the `StreamFn` bridge to our
 * WS transport (`pi-loop/stream-fn.ts`, unchanged transport underneath),
 * caller gating and image/presentation/lifecycle bookkeeping
 * (`beforeToolCall`/`afterToolCall`), and the iteration-budget/recovery nudges
 * that used to be inline loop logic and are now `agent.steer()` calls timed
 * off `prepareNextTurnWithContext`. The worker still owns the local iteration
 * budget; it does not own history expansion, compaction, continuation
 * anchors, or durable response state — those stay in AIGateway.
 */

import {
  Agent,
  type AfterToolCallResult,
  type AgentTool as PiAgentTool,
  type BeforeToolCallResult
} from '@earendil-works/pi-agent-core'
import type {
  AssistantMessage as PiAssistantMessage,
  Context as PiContext,
  ImageContent as PiImageContent,
  Message as PiMessage,
  Model as PiModel,
  UserMessage as PiUserMessage
} from '@earendil-works/pi-ai'
import { safeJsonStringify as safeJSONStringify, type JsonObject as JSONObject } from '@agentbull/active-support'
import {
  assistantText,
  describeTruncatedToolCalls,
  type AssistantMessage,
  type ContentPart,
  type ImageContent,
  type Message
} from './llm'
import { errorMessage } from '../common/errors'
import { contentText, modelImageAdaptation, imageSummaryBlock, responseImageUnavailableText } from './vision'
import { createPiStreamFn, toolIdentity } from './pi-loop/stream-fn'
import { createPiTurnState, type PiTurnState } from './pi-loop/turn-state'
import type {
  ActivityDescription,
  AgentLoopConfig,
  AgentLoopResult,
  AgentToolResult,
  ReplyPresentationEvent,
  WorkerAgentTool
} from './types'

/** Matches the old hand-rolled loop's worker pool: bounds fan-out for `executionMode:'parallel'` tools. */
const MAX_PARALLEL_TOOL_EXECUTIONS = 4

const EMPTY_AFTER_TOOL_NUDGE_TEXT =
  'You just executed tool calls but returned an empty response. Please process the tool results above and continue with the task.'
const MODEL_ITERATION_LIMIT_SYNTHESIS_TEXT =
  "You've reached the maximum number of tool-calling iterations allowed. Please provide a final response summarizing what you've found and accomplished so far, without calling any more tools."
const PI_API = 'openai-responses'

interface RepeatedToolFailureState {
  key?: string
  count: number
}

/**
 * Runs the model/tool loop until the model returns a final assistant message.
 */
export async function runAgentLoop(config: AgentLoopConfig): Promise<AgentLoopResult> {
  assertNoDuplicateTools(config.tools)

  const turnState = createPiTurnState()
  const { streamFn, recordToolResultsEagerly, close } = createPiStreamFn(config, turnState)
  const emitPresentationEvent = createPresentationEmitter(config)
  const semaphore = createSemaphore(MAX_PARALLEL_TOOL_EXECUTIONS)

  let modelIterations = 0
  let sawToolResults = false
  let nudgedEmptyAfterTools = false
  let repairedFinalResponse = false
  let salvagedTruncatedToolCall = false
  let outcome: AgentLoopResult['outcome'] = 'loop_finished'
  // Set on every `recordToolResultsEagerly` call. A round whose tool results
  // terminate the run (or otherwise leave nothing pending) never causes
  // another `streamFn` call, so `agent.state.messages` can end on a tool
  // result rather than a response-backed assistant message — this is the
  // response id for that case (see the final-result construction below).
  let latestRecordedResponseID: string | undefined
  const repeatedFailureState: RepeatedToolFailureState = { count: 0 }

  // `execute()`'s return type carries our own `ContentPart[]` content shape
  // (see types.ts's doc comment), not pi-ai's `(TextContent|ImageContent)[]`.
  // `afterToolCall` below unconditionally overrides `content` to a single
  // pi-shaped text block before pi ever stores the result, so the mismatch
  // never reaches pi's own machinery at runtime — safe to assert past here.
  // oxlint-disable-next-line prefer-const
  let agent!: Agent
  const wrappedTools = (config.tools ?? []).map(tool => ({
    ...tool,
    execute: wrapToolExecute(tool, config, turnState, semaphore)
  }))
  agent = new Agent({
    initialState: {
      systemPrompt: config.systemPrompt ?? '',
      model: stubModel(config),
      thinkingLevel: 'off',
      tools: wrappedTools as unknown as PiAgentTool[]
    },
    streamFn,

    beforeToolCall: async ctx => {
      // pi executes every tool call the model requested in one round even
      // after an earlier one terminates (unlike the old hand-rolled loop's
      // `break`) — block the rest once that's happened, so a dangling call
      // still gets a paired result instead of actually running.
      if (turnState.roundTerminated) {
        const result: BeforeToolCallResult = {
          block: true,
          reason: 'A prior tool call already ended this turn.',
          terminate: true
        }
        return result
      }

      const meta = turnState.toolCallMeta.get(ctx.toolCall.id)
      const caller = meta?.caller?.type === 'program' ? 'programmatic' : 'direct'
      const tool = findTool(agent, ctx.toolCall.name)
      const allowed = tool?.allowedCallers ?? ['direct']
      const displayName = toolDisplayName(meta?.namespace, ctx.toolCall.name)

      if (!allowed.includes(caller)) {
        config.logger?.warning('worker.tool_call_rejected', 'worker tool call rejected', {
          actor_event_id: config.stateful.actorEventID,
          tool_name: ctx.toolCall.name,
          tool_call_id: ctx.toolCall.id,
          failure_code: 'caller_not_allowed',
          caller
        })
        const result: BeforeToolCallResult = {
          block: true,
          reason: `Caller ${caller} is not allowed for tool ${displayName}`
        }
        return result
      }

      // Real, strict validation — pi's own typebox gate already ran on
      // `ctx.args`, but typebox's coercion is looser than zod's (e.g. it
      // accepts a number where the schema declares a string). Validate the
      // raw, pre-coercion value here and stash the zod-parsed result for the
      // wrapped `execute` (`wrapToolExecute`) so `execute()` truly receives
      // `z.output<TZod>`, not pi's coerced view.
      if (!tool) return undefined
      const parsed = tool.schema.safeParse(ctx.toolCall.arguments)
      if (!parsed.success) {
        config.logger?.warning('worker.tool_call_rejected', 'worker tool call rejected', {
          actor_event_id: config.stateful.actorEventID,
          tool_name: ctx.toolCall.name,
          tool_call_id: ctx.toolCall.id,
          failure_code: 'invalid_arguments'
        })
        const result: BeforeToolCallResult = {
          block: true,
          reason: `Invalid arguments for tool ${displayName}: ${errorMessage(parsed.error)}`
        }
        return result
      }

      const activity = toolActivity(ctx.toolCall.id, tool, parsed.data)
      turnState.activeToolCalls.set(ctx.toolCall.id, { parsedArgs: parsed.data, activity, startedAt: Date.now() })
      if (activity) {
        await emitPresentationEvent({ kind: 'tool.activity', payload: { ...activity, phase: 'running' } })
      }
      config.logger?.info('worker.tool_call_started', 'worker tool call started', {
        actor_event_id: config.stateful.actorEventID,
        tool_name: ctx.toolCall.name,
        ...(meta?.namespace ? { tool_namespace: meta.namespace } : {}),
        tool_call_id: ctx.toolCall.id,
        execution_mode: tool.executionMode,
        read_only: tool.isReadOnly === true,
        destructive: tool.isDestructive === true
      })

      return undefined
    },

    afterToolCall: async ctx => {
      const result = ctx.result as unknown as AgentToolResult<unknown>
      const meta = turnState.toolCallMeta.get(ctx.toolCall.id)
      const active = turnState.activeToolCalls.get(ctx.toolCall.id)
      turnState.activeToolCalls.delete(ctx.toolCall.id)

      for (const event of result.presentation ?? []) {
        await emitPresentationEvent(event)
      }
      if (result.completeActorEventIDs?.length) {
        turnState.pendingCompleteActorEventIDs.push(...result.completeActorEventIDs)
      }

      const failureWarning = updateRepeatedFailureState(
        ctx.isError,
        meta?.namespace,
        ctx.toolCall.name,
        repeatedFailureState
      )
      if (failureWarning) turnState.pendingToolResultFollowUps.push(failureWarning)

      const adapted = await adaptedResultText(result.content, config)
      if (adapted.followUp) turnState.pendingToolResultFollowUps.push(adapted.followUp)

      // A tool that returns no text content (only `details`) still needs a
      // non-empty function_call_output — fall back to the raw details rather
      // than sending the model nothing.
      const outputText = adapted.text || safeJSONStringify(result.details)
      const override: AfterToolCallResult = {
        content: [{ type: 'text', text: outputText }]
      }
      if (result.terminate === true && meta?.caller?.type === 'program') override.terminate = false

      const tool = findTool(agent, ctx.toolCall.name)
      const logFields: JSONObject = {
        actor_event_id: config.stateful.actorEventID,
        tool_name: ctx.toolCall.name,
        ...(meta?.namespace ? { tool_namespace: meta.namespace } : {}),
        tool_call_id: ctx.toolCall.id,
        duration_ms: Date.now() - (active?.startedAt ?? Date.now()),
        output_chars: outputText.length,
        terminate: (override.terminate ?? result.terminate) === true
      }
      if (ctx.isError) {
        config.logger?.warning('worker.tool_call_failed', 'worker tool call failed', {
          ...logFields,
          failure_code: 'runtime_error'
        })
      } else {
        config.logger?.info('worker.tool_call_completed', 'worker tool call completed', logFields)
      }

      if (active?.activity) {
        const completed =
          !ctx.isError && tool
            ? completedToolActivity(active.activity, tool, active.parsedArgs, result.details)
            : active.activity
        await emitPresentationEvent({
          kind: 'tool.activity',
          payload: { ...completed, phase: ctx.isError ? 'failed' : 'completed' }
        })
      }

      if ((override.terminate ?? result.terminate) === true && !ctx.isError) turnState.roundTerminated = true
      return override
    },

    prepareNextTurnWithContext: async ctx => {
      // An abort mid-round converts every in-flight tool call into a normal
      // (non-throwing) error result — pi has no other way to signal it. Once
      // the signal has actually fired, nothing here should record, steer, or
      // otherwise treat the round as real progress; the caller sees the
      // real abort reason once `agent.prompt()` settles (see the final
      // abort check after it).
      if (config.abortSignal?.aborted) return undefined

      modelIterations += 1
      turnState.roundTerminated = false

      const truncatedToolCalls = turnState.pendingTruncatedToolCalls
      turnState.pendingTruncatedToolCalls = []
      if (truncatedToolCalls.length > 0 && !salvagedTruncatedToolCall) {
        // The same request would hit the same limit, so a second salvage
        // attempt only helps once the model has already learned where its
        // arguments stopped — beyond that, accept the cut response as final
        // (see the module doc: the worker owns the iteration budget, not
        // endless retries against the same wall).
        salvagedTruncatedToolCall = true
        config.logger?.warning(
          'worker.tool_call_truncated',
          'worker discarded tool calls cut off by the output limit',
          {
            actor_event_id: config.stateful.actorEventID,
            model_iteration: modelIterations,
            tool_names: truncatedToolCalls.map(call => call.name),
            cut_fields: truncatedToolCalls.map(call => call.cutField ?? '')
          }
        )
        agent.steer(userMessage(describeTruncatedToolCalls(truncatedToolCalls)))
      }

      if (ctx.toolResults.length > 0) {
        sawToolResults = true
        nudgedEmptyAfterTools = false
        // Eager, not deferred to the next `streamFn` call: a terminating (or
        // otherwise not-continuing) round never causes one. See `stream-fn.ts`'s
        // module doc and `recordToolResultsEagerly`'s own doc for the full reasoning.
        // `ctx.context` is pi-agent-core's `AgentContext` (`messages` widened
        // for its own `CustomAgentMessages` extension point); harmless to
        // narrow since we never register one, same as the `tools` cast above.
        latestRecordedResponseID = await recordToolResultsEagerly(
          ctx.context as unknown as PiContext,
          turnState.pendingToolResultFollowUps.splice(0)
        )
      }

      // Only relevant when this round's tool results would otherwise start
      // another one — a round that already finished with a plain text answer
      // needs no synthesis even exactly on the last allowed iteration.
      // One-shot beyond that: `modelIterations` never decreases, so without
      // the outcome guard this would re-fire on every later round too (the
      // synthesis round itself included), re-queuing the same steer message
      // forever instead of the single corrective nudge the old `while`
      // loop's `break` used to guarantee.
      if (
        ctx.toolResults.length > 0 &&
        modelIterations >= config.maxModelIterations &&
        outcome !== 'iteration_exhausted'
      ) {
        outcome = 'iteration_exhausted'
        agent.steer(
          userMessage(`${MODEL_ITERATION_LIMIT_SYNTHESIS_TEXT}\nmax_model_iterations=${config.maxModelIterations}`)
        )
        return { context: { ...ctx.context, tools: [] } }
      }

      // Fetched once (not just for the label below) so a queue-draining
      // `getSteeringMessages` isn't called twice for the same round.
      const steeringMessages =
        ctx.toolResults.length > 0 && !turnState.roundTerminated && config.getSteeringMessages
          ? await config.getSteeringMessages()
          : []
      if (ctx.toolResults.length > 0 && !turnState.roundTerminated) {
        await emitPresentationEvent({
          kind: 'turn.phase',
          payload: {
            operation_id: 'turn',
            state: 'working',
            label_key:
              steeringMessages.length > 0
                ? 'signals_gateway.reply.activity.turn_reprocessing'
                : 'signals_gateway.reply.activity.turn_finishing'
          }
        })
      }

      const text = piAssistantText(ctx.message)
      if (sawToolResults && !nudgedEmptyAfterTools && ctx.message.stopReason === 'stop' && text.trim().length === 0) {
        nudgedEmptyAfterTools = true
        agent.steer(userMessage(EMPTY_AFTER_TOOL_NUDGE_TEXT))
      }

      if (!repairedFinalResponse && ctx.message.stopReason === 'stop' && config.repairFinalResponse) {
        const repair = config.repairFinalResponse(toOurAssistantMessage(ctx.message))
        if (repair) {
          repairedFinalResponse = true
          agent.steer(toPiUserMessage(repair))
        }
      }

      for (const message of steeringMessages) agent.steer(toPiUserMessage(message))

      return undefined
    }
  })

  // A signal that's already aborted before this listener attaches won't fire
  // it (past events don't replay) — `agent.abort()` would be a no-op anyway
  // before `.prompt()` starts an active run. That's fine: the transport
  // (`llm/session.ts`, unchanged) already checks the signal itself and
  // reports a clean `stopReason:'aborted'` once it tries to use it, same as
  // it always has; this listener only needs to cover an abort that arrives
  // mid-run, after `agent.abort()` becomes meaningful.
  const abortListener = (): void => agent.abort()
  config.abortSignal?.addEventListener('abort', abortListener)

  const unsubscribe = agent.subscribe(async event => {
    if (event.type === 'message_update' && event.assistantMessageEvent.type === 'text_delta') {
      config.onActivity?.('model_text_delta')
      config.onTextDelta?.(event.assistantMessageEvent.delta)
    }
    if (event.type === 'tool_execution_start' || event.type === 'tool_execution_end') {
      config.onActivity?.(event.type)
    }
  })

  await emitPresentationEvent({
    kind: 'turn.phase',
    payload: { operation_id: 'turn', state: 'working', label_key: 'signals_gateway.reply.activity.turn_understanding' }
  })

  let finalMessages: unknown[] = []
  try {
    await agent.prompt(config.messages.map(toPiMessage))
    finalMessages = agent.state.messages
  } finally {
    unsubscribe()
    config.abortSignal?.removeEventListener('abort', abortListener)
    close()
  }

  // An abort can land while tool execution is mid-flight (queued parallel
  // calls never start — see `wrapToolExecute`'s semaphore; active ones reject
  // through their own signal) — pi turns that into a normal (non-throwing)
  // aborted/error message, same as any other terminal stream state, so the
  // caller only ever sees the real reason by checking the signal itself.
  if (config.abortSignal?.aborted) {
    throw config.abortSignal.reason ?? new DOMException('The operation was aborted.', 'AbortError')
  }

  // The run can end on a trailing tool-result message instead of an assistant
  // message: a terminating tool call (or one with nothing else pending) never
  // causes another `streamFn` call — see `recordToolResultsEagerly`. In that
  // case the content to return is still the most recent assistant message
  // (the one that made the calls), but its own `responseId` is stale; the
  // eagerly recorded id is the one that actually anchors AIGateway's state.
  const lastEntry = finalMessages[finalMessages.length - 1]
  const lastAssistant = findLastAssistantMessage(finalMessages)
  // A terminal provider/AIGateway failure that outlasted every retry (see
  // `stream-fn.ts`'s `terminalModelError`) ends the run the same way pi ends
  // any other round: a normal resolved `agent.prompt()`, not a rejection.
  // Surface the real failure instead of the generic "no response" fallback.
  if (lastAssistant?.stopReason === 'error') {
    // Prefer the real caught error (see `PiTurnState.lastError`'s doc) over
    // reconstructing one from its string-only `errorMessage` — a caller
    // matching on `.retryable` or another tagged property needs the object,
    // not a fresh `Error` that only carries its `.message`.
    throw turnState.lastError ?? new Error(lastAssistant.errorMessage || 'LLM provider returned an error')
  }
  const responseID = lastEntry === lastAssistant ? lastAssistant?.responseId : latestRecordedResponseID
  if (!lastAssistant || !responseID) {
    throw new Error('agent loop completed without a response-backed assistant message')
  }

  return { message: toOurAssistantMessage(lastAssistant), responseID, outcome }
}

/** Throws before any model call: two tools sharing one wire identity is a caller bug, not a runtime failure to negotiate. */
function assertNoDuplicateTools(tools: WorkerAgentTool[] | undefined): void {
  const seen = new Set<string>()
  for (const tool of tools ?? []) {
    const identity = toolIdentity(tool.namespace, tool.name)
    if (seen.has(identity)) throw new Error(`duplicate tool name: ${toolDisplayName(tool.namespace, tool.name)}`)
    seen.add(identity)
  }
}

/**
 * Assigns one turn-local monotonic revision and keeps live presentation
 * delivery best-effort. A transport failure must not turn a successful tool
 * execution into a failed Agent turn.
 */
function createPresentationEmitter(config: AgentLoopConfig): (event: ReplyPresentationEvent) => Promise<void> {
  let revision = 0
  return async event => {
    if (!config.onPresentationEvent) return
    const next: ReplyPresentationEvent = { kind: event.kind, payload: { ...event.payload, revision: ++revision } }
    try {
      await config.onPresentationEvent(next)
    } catch {
      config.onActivity?.('reply_presentation_event_failed')
    }
  }
}

/** A counting semaphore that fails a still-queued `acquire()` instead of ever granting it once `signal` aborts. */
function createSemaphore(limit: number): { acquire: (signal?: AbortSignal) => Promise<() => void> } {
  let active = 0
  const queue: Array<() => void> = []

  function release(): void {
    active -= 1
    queue.shift()?.()
  }

  return {
    acquire(signal) {
      return new Promise<() => void>((resolve, reject) => {
        if (signal?.aborted) {
          reject(signal.reason)
          return
        }
        const onAbort = (): void => {
          const index = queue.indexOf(grant)
          if (index >= 0) queue.splice(index, 1)
          reject(signal?.reason)
        }
        const grant = (): void => {
          signal?.removeEventListener('abort', onAbort)
          active += 1
          resolve(release)
        }
        if (active < limit) grant()
        else {
          queue.push(grant)
          signal?.addEventListener('abort', onAbort, { once: true })
        }
      })
    }
  }
}

/**
 * Wraps a tool's real `execute` with the concerns pi has no hook for: the
 * zod-parsed arguments `beforeToolCall` already validated (not pi's looser
 * typebox-coerced view), `withActivitySuspended` around the actual call
 * (matching the old loop's inactivity-tracking exemption), and — only for
 * `executionMode:'parallel'` tools — the shared concurrency bound pi's own
 * `Promise.all` fan-out does not enforce. Activity rows and structured
 * logging live in `beforeToolCall`/`afterToolCall` instead, which bracket
 * this call and already have the round/result context they need.
 */
function wrapToolExecute(
  tool: WorkerAgentTool,
  config: AgentLoopConfig,
  turnState: PiTurnState,
  semaphore: { acquire: (signal?: AbortSignal) => Promise<() => void> }
): WorkerAgentTool['execute'] {
  return async (toolCallID, params, _piSignal, onUpdate) => {
    // The turn's own `config.abortSignal`, not pi's own per-call signal
    // (relayed from `agent.abort()`, a different object with a different
    // `.reason`) — a tool must see and reject on the exact signal the caller
    // controls, matching the old loop's direct `tool.execute(..., config.abortSignal)`.
    const signal = config.abortSignal
    const parsedArgs = turnState.activeToolCalls.get(toolCallID)?.parsedArgs ?? params
    const release = tool.executionMode === 'parallel' ? await semaphore.acquire(signal) : undefined
    try {
      const run = (): ReturnType<WorkerAgentTool['execute']> =>
        tool.execute(toolCallID, parsedArgs as never, signal, onUpdate)
      return config.withActivitySuspended ? await config.withActivitySuspended('tool_execution', run) : await run()
    } finally {
      release?.()
    }
  }
}

/** Builds the "running" tool.activity payload, or `null` when the tool explicitly suppresses one. */
function toolActivity(toolCallID: string, tool: WorkerAgentTool, parsedArgs: unknown): JSONObject | null {
  let described: ActivityDescription | string | null | undefined
  try {
    described = tool.describeActivity(parsedArgs as never)
  } catch {
    described = undefined
  }
  if (described === null) return null
  return {
    operation_id: toolCallID,
    ...activityDescriptionPayload(described),
    consequential: tool.isDestructive === true
  }
}

/**
 * Lets a tool replace its parameter-only label with safe result facts.
 * Summary failures do not change tool execution or remove the original activity.
 */
function completedToolActivity(
  activity: JSONObject,
  tool: WorkerAgentTool,
  parsedArgs: unknown,
  details: unknown
): JSONObject {
  if (!tool.describeCompletedActivity) return activity
  try {
    const described = tool.describeCompletedActivity(parsedArgs as never, details)
    return described ? { ...activity, ...activityDescriptionPayload(described) } : activity
  } catch {
    return activity
  }
}

function activityDescriptionPayload(description: ActivityDescription | string | null | undefined): JSONObject {
  if (typeof description === 'string') {
    const label = description.trim()
    return label ? { label } : { label_key: 'signals_gateway.reply.activity.processing' }
  }
  if (!description) return { label_key: 'signals_gateway.reply.activity.processing' }
  return { label_key: description.key, ...(description.bindings ? { label_bindings: description.bindings } : {}) }
}

function findLastAssistantMessage(messages: unknown[]): PiAssistantMessage | undefined {
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index] as PiMessage
    if (message.role === 'assistant') return message
  }
  return undefined
}

function findTool(agent: Agent, name: string): WorkerAgentTool | undefined {
  return (agent.state.tools as unknown as WorkerAgentTool[]).find(tool => tool.name === name)
}

function toolDisplayName(namespace: string | undefined, name: string): string {
  return namespace && namespace !== 'functions' ? `${namespace}.${name}` : name
}

function userMessage(content: string): PiUserMessage {
  return { role: 'user', content, timestamp: Date.now() }
}

function toPiUserMessage(message: Message): PiUserMessage {
  const content = message.role === 'user' ? message.content : contentTextOf(message)
  if (typeof content === 'string') return userMessage(content)
  return {
    role: 'user',
    timestamp: Date.now(),
    content: content.map(part =>
      part.type === 'text' ? { type: 'text' as const, text: part.text } : toPiImagePart(part)
    )
  }
}

function contentTextOf(message: Message): string {
  if (message.role === 'user') return typeof message.content === 'string' ? message.content : ''
  if (message.role === 'assistant') return assistantText(message)
  return message.result
}

function toPiMessage(message: Message): PiMessage {
  if (message.role === 'user') return toPiUserMessage(message)
  throw new Error(`unsupported initial message role: ${message.role}`)
}

function toPiImagePart(part: ImageContent): PiImageContent {
  const { data, mimeType } = base64FromImage(part)
  return { type: 'image', data, mimeType }
}

function base64FromImage(part: ImageContent): { data: string; mimeType: string } {
  const mimeType = part.mimeType ?? 'image/png'
  if (typeof part.image === 'string') {
    const match = /^data:[^;]+;base64,(.+)$/.exec(part.image)
    if (match) return { data: match[1]!, mimeType }
    return { data: part.image, mimeType }
  }
  const bytes =
    part.image instanceof Uint8Array
      ? part.image
      : part.image instanceof ArrayBuffer
        ? new Uint8Array(part.image)
        : new Uint8Array((part.image as ArrayBufferView).buffer)
  return { data: Buffer.from(bytes).toString('base64'), mimeType }
}

function piAssistantText(message: PiAssistantMessage): string {
  return message.content
    .filter((part): part is Extract<typeof part, { type: 'text' }> => part.type === 'text')
    .map(part => part.text)
    .join('')
}

/** Reverses the `stream-fn.ts` translation just enough for `repairFinalResponse`. */
function toOurAssistantMessage(message: PiAssistantMessage): AssistantMessage {
  return {
    role: 'assistant',
    content: message.content
      .filter((part): part is Extract<typeof part, { type: 'text' }> => part.type === 'text')
      .map(part => ({ type: 'text' as const, text: part.text })),
    stopReason: message.stopReason as AssistantMessage['stopReason'],
    model: message.model,
    ...(message.errorMessage ? { errorMessage: message.errorMessage } : {}),
    ...(message.usage
      ? {
          usage: {
            inputTokens: message.usage.input,
            outputTokens: message.usage.output,
            reasoningTokens: message.usage.reasoning,
            cachedInputTokens: message.usage.cacheRead
          }
        }
      : {})
  }
}

/**
 * Mirrors `processToolResultForModel`: flattens a tool's content into
 * model-visible text, adapting or stripping images per the turn's vision
 * capability. `followUp`, when present, is an image/summary follow-up that
 * belongs with this same tool result — the caller pushes it onto
 * `PiTurnState.pendingToolResultFollowUps`, not `agent.steer()` (see that
 * field's doc for why).
 */
async function adaptedResultText(
  content: ContentPart[],
  config: AgentLoopConfig
): Promise<{ text: string; followUp?: PiUserMessage }> {
  const text = contentText(content)
  const images = content.filter((part): part is ImageContent => part.type === 'image')
  if (images.length === 0) return { text }

  const adaptation = await modelImageAdaptation(
    images,
    { input_modalities: config.modelInputModalities },
    {
      visionFallbackModel: config.visionFallbackModel,
      abortSignal: config.abortSignal
    }
  )

  if (adaptation.kind === 'none') return { text }

  if (adaptation.kind === 'direct') {
    const followUp: PiUserMessage = {
      role: 'user',
      timestamp: Date.now(),
      content: [{ type: 'text', text: 'Tool returned image content.' }, ...adaptation.images.map(toPiImagePart)]
    }
    return { text: toolImageOutputText(text, adaptation.images.length), followUp }
  }

  if (adaptation.kind === 'summary') {
    return {
      text: toolImageOutputText(text, images.length),
      followUp: userMessage(imageSummaryBlock(adaptation.summary, 'tool'))
    }
  }

  return { text: [text, responseImageUnavailableText()].filter(Boolean).join('\n') }
}

function toolImageOutputText(text: string, imageCount: number): string {
  return [text, `[${imageCount} image result${imageCount === 1 ? '' : 's'} attached as follow-up user input]`]
    .filter(Boolean)
    .join('\n')
}

/** Returns a repeated-failure warning follow-up once a tool's failure streak reaches 2. */
function updateRepeatedFailureState(
  isError: boolean,
  namespace: string | undefined,
  toolName: string,
  state: RepeatedToolFailureState
): PiUserMessage | undefined {
  const key = `${namespace ?? ''} ${toolName}`
  if (!isError) {
    state.key = undefined
    state.count = 0
    return undefined
  }

  // oxlint-disable-next-line no-unused-expressions
  state.key === key ? (state.count += 1) : ((state.key = key), (state.count = 1))
  if (state.count === 2) {
    return userMessage(repeatedToolFailureWarning(toolDisplayName(namespace, toolName), state.count))
  }
  return undefined
}

function repeatedToolFailureWarning(toolName: string, count: number): string {
  const common =
    `${toolName} has failed ${count} times this turn. This looks like a loop. ` +
    'Do not switch to text-only replies; keep using tools, but diagnose before retrying. ' +
    'First inspect the latest error/output and verify your assumptions. '
  const recovery =
    toolName === 'command'
      ? 'For terminal failures, run a small diagnostic such as `pwd && ls -la` in the same tool, then try an absolute path, a simpler command, a different working directory, or a different tool such as read_file/apply_patch.'
      : 'Try different arguments, a narrower query/path, an absolute path when relevant, or a different tool that can make progress. If the blocker is external, report the blocker after one diagnostic attempt instead of repeating the same failing path.'
  return `[Tool loop warning: repeated_tool_failure; count=${count}; ${common}${recovery}]`
}

/**
 * pi's `Model` descriptor is only consulted by provider-catalog machinery we
 * never touch (`StreamFn` bypasses it — `stream-fn.ts` talks to AIGateway
 * directly via the closure-captured real `ModelConfig`). This stub exists
 * purely to satisfy `Agent`'s required `initialState.model` field; its cost/
 * context-window/token-limit values are placeholders, never read at runtime.
 */
function stubModel(config: AgentLoopConfig): PiModel<'openai-responses'> {
  return {
    id: config.model.name,
    name: config.model.name,
    api: PI_API,
    provider: config.model.provider,
    baseUrl: '',
    reasoning: false,
    input: ['text'],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 0,
    maxTokens: 0
  }
}
