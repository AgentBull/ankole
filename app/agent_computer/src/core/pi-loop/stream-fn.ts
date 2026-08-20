/**
 * Translates pi-agent-core's `StreamFn` contract onto the existing AIGateway
 * stateful WS transport (`llm/session.ts`, unchanged). One instance is created
 * per Ankole turn and owns the underlying `ModelTurn`'s full lifecycle.
 *
 * `Context.messages` (pi's view) accumulates the full run history; AIGateway
 * expects only the delta since the last anchored response. `turnState.cursor`
 * bridges the two — see the cursor-advancement comment inside `run()` for the
 * exact accounting, which is less trivial than "jump to the current length"
 * because pi hasn't appended this round's own assistant message yet when a
 * round starts. This only holds because pi only ever appends to
 * `context.messages` within a bare `runAgentLoop` (no `transformContext`/
 * compaction in phase one) — see the plan doc.
 *
 * The cursor is shared with `agent-loop.ts` (not purely local) because tool
 * results must reach AIGateway even on a round pi's own loop never revisits —
 * a terminating tool call, or one with no follow-up and no other pending
 * message, never causes another `streamFn` call. `recordToolResultsEagerly`
 * (exported below, called from `prepareNextTurnWithContext`) is that path;
 * `run()`'s own delta is therefore guaranteed to never contain a tool result.
 */

import type {
  AssistantMessage as PiAssistantMessage,
  AssistantMessageEventStream,
  Context as PiContext,
  Message as PiMessage,
  Tool as PiTool,
  ToolResultMessage as PiToolResultMessage,
  UserMessage as PiUserMessage,
  Usage as PiUsage
} from '@earendil-works/pi-ai'
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai'
import type { StreamFn } from '@earendil-works/pi-agent-core'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { withRetry } from '../../common/async'
import { errorMessage } from '../../common/errors'
import {
  createModelTurn,
  repairToolArgumentsJSON,
  type AssistantMessage as OurAssistantMessage,
  type CallModelOptions,
  type Message as OurMessage,
  type ModelUsage,
  type StopReason as OurStopReason,
  type ToolDefinition,
  type ToolSet
} from '../llm'
import { classifyLLMError, isLocallyRetryableLLMError } from '../llm-error-classifier'
import type { AgentLoopConfig, WorkerAgentTool } from '../types'
import type { PiTurnState, ToolCallWireMeta } from './turn-state'

const PI_API = 'openai-responses'

/** See `recordToolResultsEagerly`'s doc inside `createPiStreamFn`. */
export type RecordToolResultsEagerly = (context: PiContext, followUps: PiUserMessage[]) => Promise<string>

/**
 * Builds the `StreamFn` for one Ankole turn plus a `close()` that releases the
 * underlying WS session. `modelTurn`'s `onTextDelta` is fixed at construction
 * (pi-agent-core convention for the transport), but each `StreamFn` invocation
 * needs to push deltas into its own fresh `AssistantMessageEventStream` — a
 * mutable "current sink" indirection bridges the two.
 */
export function createPiStreamFn(
  config: Pick<
    AgentLoopConfig,
    | 'model'
    | 'stateful'
    | 'abortSignal'
    | 'onActivity'
    | 'maxTokens'
    | 'temperature'
    | 'text'
    | 'hostedTools'
    | 'logger'
  >,
  turnState: PiTurnState
): { streamFn: StreamFn; recordToolResultsEagerly: RecordToolResultsEagerly; close: () => void } {
  let currentTextSink: ((delta: string) => void) | undefined
  const { toolCallMeta } = turnState

  const modelTurn = createModelTurn(config.model, {
    stateful: config.stateful,
    abortSignal: config.abortSignal,
    onActivity: config.onActivity,
    onTextDelta: delta => currentTextSink?.(delta)
  })

  const streamFn: StreamFn = (_model, context, _options) => {
    const stream = createAssistantMessageEventStream()
    void run(stream, context)
    return stream
  }

  return { streamFn, recordToolResultsEagerly, close: () => modelTurn.close() }

  /**
   * Records this round's tool results (the delta since the cursor — always
   * exactly the `toolResult` messages pi just pushed) together with their own
   * follow-ups (image/summary adaptation, repeated-failure nudges — data, not
   * `agent.steer()`, so they can be bundled into this one call). Pushes the
   * follow-ups into `context.messages` itself so pi's own view — and the next
   * `run()` call's delta — stays consistent, and returns the new response id.
   */
  async function recordToolResultsEagerly(context: PiContext, followUps: PiUserMessage[]): Promise<string> {
    const toolResults = context.messages.slice(turnState.cursor).map(message => toOurMessage(message, toolCallMeta))
    const followUpMessages = followUps.map(message => toOurMessage(message, toolCallMeta))
    const bundled = [...toolResults, ...followUpMessages]
    const completeActorEventIDs = turnState.pendingCompleteActorEventIDs.splice(0)

    let attempt = 0
    const recorded = await withRetry(
      async () => {
        attempt += 1
        const startedAt = Date.now()
        const recordFields: JSONObject = {
          actor_event_id: config.stateful.actorEventID,
          attempt,
          tool_result_count: bundled.length,
          complete_actor_event_count: completeActorEventIDs.length
        }
        config.logger?.info('worker.tool_results_record_started', 'worker tool results record started', recordFields)
        config.onActivity?.('tool_results_record_start')
        try {
          const result = await modelTurn.recordToolResults(bundled, { completeActorEventIDs })
          config.logger?.info('worker.tool_results_record_completed', 'worker tool results record completed', {
            ...recordFields,
            duration_ms: Date.now() - startedAt,
            response_id: result.responseID
          })
          return result
        } catch (error) {
          const retryable = isLocallyRetryableLLMError(error)
          config.logger?.warning('worker.tool_results_record_failed', 'worker tool results record failed', {
            ...recordFields,
            duration_ms: Date.now() - startedAt,
            will_retry: attempt < 3 && retryable && !config.abortSignal?.aborted
          })
          throw error
        } finally {
          config.onActivity?.('tool_results_record_done')
        }
      },
      { maxAttempts: 3, signal: config.abortSignal, isRetryable: isLocallyRetryableLLMError }
    )
    context.messages.push(...followUps)
    turnState.cursor = context.messages.length
    return requiredResponseID(recorded.responseID)
  }

  async function run(stream: AssistantMessageEventStream, context: PiContext): Promise<void> {
    // A round can start after the turn's already been aborted: pi converts
    // an in-flight tool call's abort into a normal (non-throwing) error
    // result rather than stopping the batch, so `hasMoreToolCalls` can still
    // be true and cause another round. Refuse it here — before ever building
    // or sending a request — rather than relying on the transport to notice.
    if (config.abortSignal?.aborted) {
      stream.push({
        type: 'error',
        reason: 'aborted',
        error: errorAssistantMessage(config, true, errorMessage(config.abortSignal.reason ?? 'aborted'))
      })
      return
    }

    // `context.messages` does not yet contain this round's own assistant
    // message when `run()` starts (pi appends it only after consuming our
    // `start`/`done` events, concurrently with the rest of this function) —
    // so the cursor cannot simply jump to the current length. It advances by
    // exactly what this round consumes *plus one*, accounting for the single
    // assistant message this round is itself about to cause pi to append
    // (uniformly true on every exit path: success, provider error, and
    // abort all resolve through the same one-message `done`/`error` handling
    // in pi's `streamAssistantResponse`). Getting this wrong means the next
    // round re-sends (or `toOurMessage` chokes on) this round's own assistant
    // message, which has no `role` our wire format understands.
    //
    // The delta itself never contains a tool result: `recordToolResultsEagerly`
    // (called from `prepareNextTurnWithContext`, before pi ever gets back here)
    // already consumed and advanced the cursor past those. Whatever remains is
    // plain steering — external, iteration-limit synthesis, empty-response
    // nudge, or response repair — bound for `.call()` as-is.
    const delta = context.messages.slice(turnState.cursor)
    try {
      const messagesForCall = delta.map(message => toOurMessage(message, toolCallMeta))

      let textSoFar = ''
      let textStarted = false
      currentTextSink = delta => {
        if (!textStarted) {
          textStarted = true
          stream.push({ type: 'text_start', contentIndex: 0, partial: partialMessage(config, '') })
        }
        textSoFar += delta
        stream.push({ type: 'text_delta', contentIndex: 0, delta, partial: partialMessage(config, textSoFar) })
      }
      stream.push({ type: 'start', partial: partialMessage(config, '') })

      const callOptions: CallModelOptions = {
        instructions: context.systemPrompt,
        messages: messagesForCall,
        tools: toWireToolSet(context.tools),
        programmaticToolCalling: hasProgrammaticCaller(context.tools),
        hostedTools: config.hostedTools,
        maxOutputTokens: config.maxTokens,
        temperature: config.temperature,
        text: config.text
      }
      let modelAttempt = 0
      const result = await withRetry(
        async () => {
          modelAttempt += 1
          const startedAt = Date.now()
          const requestFields: JSONObject = {
            actor_event_id: config.stateful.actorEventID,
            model: config.model.name,
            provider: config.model.provider,
            selector: config.model.selector,
            attempt: modelAttempt,
            input_message_count: callOptions.messages.length,
            tool_count: callOptions.tools ? Object.keys(callOptions.tools).length : 0,
            hosted_tool_count: config.hostedTools?.length ?? 0
          }
          config.logger?.info('worker.model_call_started', 'worker model call started', requestFields)
          try {
            const callResult = await modelTurn.call(callOptions)
            const terminalError = terminalModelError(callResult)
            if (terminalError) throw terminalError
            config.logger?.info('worker.model_call_completed', 'worker model call completed', {
              ...requestFields,
              duration_ms: Date.now() - startedAt,
              response_id: callResult.responseID,
              stop_reason: callResult.message.stopReason
            })
            return callResult
          } catch (error) {
            const retryable = isLocallyRetryableLLMError(error)
            config.logger?.warning('worker.model_call_failed', 'worker model call failed', {
              ...requestFields,
              duration_ms: Date.now() - startedAt,
              ...modelErrorFields(error),
              will_retry: modelAttempt < 3 && retryable && !config.abortSignal?.aborted
            })
            throw error
          }
        },
        { maxAttempts: 3, signal: config.abortSignal, isRetryable: isLocallyRetryableLLMError }
      )
      currentTextSink = undefined

      if (textStarted) {
        stream.push({
          type: 'text_end',
          contentIndex: 0,
          content: textSoFar,
          partial: partialMessage(config, textSoFar)
        })
      }

      const finalMessage = toPiAssistantMessage(
        result.message,
        requiredResponseID(result.responseID),
        config,
        turnState
      )
      if (finalMessage.stopReason === 'aborted' || finalMessage.stopReason === 'error') {
        stream.push({ type: 'error', reason: finalMessage.stopReason, error: finalMessage })
      } else {
        stream.push({
          type: 'done',
          reason: finalMessage.stopReason as Extract<OurStopReason, 'stop' | 'length' | 'toolUse'>,
          message: finalMessage
        })
      }
    } catch (error) {
      currentTextSink = undefined
      const aborted = config.abortSignal?.aborted === true
      turnState.lastError = error
      stream.push({
        type: 'error',
        reason: aborted ? 'aborted' : 'error',
        error: errorAssistantMessage(config, aborted, errorMessage(error))
      })
    } finally {
      turnState.cursor += delta.length + 1
    }
  }
}

function toWireToolSet(tools: PiTool[] | undefined): ToolSet | undefined {
  if (!tools?.length) return undefined
  const definitions: [string, ToolDefinition][] = (tools as WorkerAgentTool[]).map(tool => [
    toolIdentity(tool.namespace, tool.name),
    {
      name: tool.name,
      description: tool.description,
      parameters: tool.schema,
      inputFormat: tool.inputFormat,
      jsonSchema: tool.jsonSchema,
      outputSchema: tool.outputSchema,
      namespace: tool.namespace,
      namespaceDescription: tool.namespaceDescription,
      deferLoading: tool.deferLoading,
      toolSearchText: tool.toolSearchText,
      allowedCallers: allowedCallers(tool)
    }
  ])
  return Object.fromEntries(definitions)
}

/** Every wire tool declares its allowed callers explicitly; unset means direct-only. */
function allowedCallers(tool: WorkerAgentTool): Array<'direct' | 'programmatic'> {
  return tool.allowedCallers ?? ['direct']
}

function hasProgrammaticCaller(tools: PiTool[] | undefined): boolean {
  return ((tools as WorkerAgentTool[] | undefined) ?? []).some(tool => allowedCallers(tool).includes('programmatic'))
}

/** `functions` is the Codex default namespace: a bare tool and one explicitly in `functions` share this identity. */
export function toolIdentity(namespace: string | undefined, name: string): string {
  const canonicalNamespace = !namespace || namespace === 'functions' ? 'functions' : namespace
  return `${canonicalNamespace}\0${name}`
}

function requiredResponseID(responseID: string | undefined): string {
  if (!responseID?.startsWith('resp_')) {
    throw new Error('AIGateway model call completed without a valid response id')
  }
  return responseID
}

/**
 * `modelTurn.call()` reports a terminal provider/AIGateway failure (a
 * `response.failed`/non-`max_output_tokens` `incomplete` status) as an
 * ordinary, non-throwing result with `stopReason:'error'` — `wire.ts`'s
 * parsing has no exception boundary to throw across. `withRetry` only ever
 * sees thrown rejections, so this is the seam that turns "terminal" into a
 * real throw carrying `errorRetryable` as `.retryable`, the exact property
 * `classifyLLMError`/`isLocallyRetryableLLMError` read to decide whether to
 * retry it — same effect as an actual transport-level throw.
 */
function terminalModelError(result: { message: OurAssistantMessage; errorRetryable?: boolean }): Error | undefined {
  const { message } = result
  if (message.stopReason !== 'error' && message.stopReason !== 'aborted') return undefined
  const error = new Error(message.errorMessage || 'LLM provider returned an error')
  error.name = 'LLMProviderTerminalError'
  if (result.errorRetryable !== undefined) Object.assign(error, { retryable: result.errorRetryable })
  return error
}

/** Bounded, structured diagnostics for a failed model call — no prompts, tool data, or raw provider bodies. */
function modelErrorFields(error: unknown): JSONObject {
  const classification = classifyLLMError(error)
  if (!error || typeof error !== 'object') {
    return { error_kind: classification.kind, retryable: classification.retryable }
  }

  const record = error as { code?: unknown; status?: unknown }
  const message = error instanceof Error ? error.message : ''
  const messageStatus = message.match(/\bstatus=(\d{3})\b/)?.[1]
  const messageCode = message.match(/\bcode=([A-Za-z0-9_.:-]+)\b/)?.[1]
  const status =
    typeof record.status === 'number' ? record.status : messageStatus ? Number.parseInt(messageStatus, 10) : undefined
  const code = typeof record.code === 'string' ? record.code : messageCode

  return {
    error_kind: classification.kind,
    retryable: classification.retryable,
    ...(code ? { error_code: code } : {}),
    ...(status !== undefined ? { status } : {})
  }
}

/** Translates one pi-ai message (from `context.messages`) into our wire-level `Message`. */
function toOurMessage(message: PiMessage, toolCallMeta: Map<string, ToolCallWireMeta>): OurMessage {
  if (message.role === 'user') {
    if (typeof message.content === 'string') return { role: 'user', content: message.content }
    return {
      role: 'user',
      content: message.content.map(part =>
        part.type === 'text'
          ? { type: 'text' as const, text: part.text }
          : { type: 'image' as const, image: dataURLFromPiImage(part.data, part.mimeType), mimeType: part.mimeType }
      )
    }
  }

  if (message.role === 'toolResult') {
    return toolResultToOurMessage(message, toolCallMeta)
  }

  // Assistant messages never appear mid-delta: pi appends them to `context.messages`
  // via the same `done`/`error` event this file itself produces, and the next
  // `StreamFn` call's cursor always starts past them (they were already sent as
  // part of the request that produced them).
  throw new Error(`unexpected message role in StreamFn delta: ${message.role}`)
}

function toolResultToOurMessage(message: PiToolResultMessage, toolCallMeta: Map<string, ToolCallWireMeta>): OurMessage {
  const meta = toolCallMeta.get(message.toolCallId)
  const text = message.content
    .map(part => (part.type === 'text' ? part.text : `[image result attached separately]`))
    .join('')
  return {
    role: 'tool',
    toolCallID: message.toolCallId,
    toolCallType: meta?.type,
    result: text,
    ...(meta?.caller ? { caller: meta.caller } : {})
  }
}

function dataURLFromPiImage(base64Data: string, mimeType: string): string {
  return `data:${mimeType};base64,${base64Data}`
}

function partialMessage(config: Pick<AgentLoopConfig, 'model'>, text: string): PiAssistantMessage {
  return {
    role: 'assistant',
    content: text ? [{ type: 'text', text }] : [],
    api: PI_API,
    provider: config.model.provider,
    model: config.model.name,
    usage: zeroUsage(),
    stopReason: 'pending',
    timestamp: Date.now()
  }
}

function errorAssistantMessage(
  config: Pick<AgentLoopConfig, 'model'>,
  aborted: boolean,
  message: string
): PiAssistantMessage {
  return {
    role: 'assistant',
    content: [],
    api: PI_API,
    provider: config.model.provider,
    model: config.model.name,
    usage: zeroUsage(),
    stopReason: aborted ? 'aborted' : 'error',
    errorMessage: message,
    timestamp: Date.now()
  }
}

function zeroUsage(): PiUsage {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
  }
}

function toPiUsage(usage: ModelUsage | undefined): PiUsage {
  if (!usage) return zeroUsage()
  return {
    input: usage.inputTokens,
    output: usage.outputTokens,
    cacheRead: usage.cachedInputTokens ?? 0,
    cacheWrite: 0,
    reasoning: usage.reasoningTokens,
    totalTokens: usage.inputTokens + usage.outputTokens,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
  }
}

/** Translates our `ModelCallResult.message` into pi-ai's `AssistantMessage` shape. */
function toPiAssistantMessage(
  message: OurAssistantMessage,
  responseID: string,
  config: Pick<AgentLoopConfig, 'model' | 'onActivity'>,
  turnState: PiTurnState
): PiAssistantMessage {
  const content: PiAssistantMessage['content'] = message.content.map(part => ({
    type: 'text',
    text: part.text
  }))

  // A truncated tool call's own diagnostic text belongs to `agent-loop.ts`'s
  // salvage message, not pi's native `stopReason:'length'` handling (which
  // would execute or fail these calls and record a generic one instead) —
  // see `PiTurnState.pendingTruncatedToolCalls`'s doc. Drop the dangling
  // call content so pi never touches it as a tool call at all.
  if (message.truncatedToolCalls?.length) {
    turnState.pendingTruncatedToolCalls = message.truncatedToolCalls
  } else {
    for (const call of message.toolCalls ?? []) {
      turnState.toolCallMeta.set(call.id, { type: call.type, namespace: call.namespace, caller: call.caller })
      // A custom/freeform tool's "arguments" is raw text (a patch, a command
      // line — whatever its `inputFormat` grammar produced), not JSON;
      // repairing/parsing it as JSON would corrupt or reject it. Pass it
      // through as-is — pi's own typebox gate validates the raw value
      // against the tool's real (possibly non-object) schema either way.
      // pi-ai types `arguments` as `Record<string, any>` only for the common
      // function-call case; a plain string reaches `execute()` unmodified at
      // runtime regardless of that static shape.
      let toolArguments: Record<string, unknown>
      if (call.type === 'custom') {
        toolArguments = call.arguments as unknown as Record<string, unknown>
      } else {
        const repaired = repairToolArgumentsJSON(call.arguments)
        if (repaired.repair !== 'none') config.onActivity?.(`tool_arguments_repaired:${repaired.repair}`)
        toolArguments = repaired.value as Record<string, unknown>
      }
      content.push({
        type: 'toolCall',
        id: call.id,
        name: call.name,
        arguments: toolArguments,
        ...(call.namespace ? { namespace: call.namespace } : {})
      })
    }
  }

  return {
    role: 'assistant',
    content,
    api: PI_API,
    provider: config.model.provider,
    model: message.model ?? config.model.name,
    responseId: responseID,
    usage: toPiUsage(message.usage),
    stopReason: message.stopReason ?? 'stop',
    ...(message.errorMessage ? { errorMessage: message.errorMessage } : {}),
    timestamp: Date.now()
  }
}
