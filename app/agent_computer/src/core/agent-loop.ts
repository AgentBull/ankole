/**
 * Agent loop — worker-driven Responses loop using AIGateway's stateful Responses transport.
 *
 * The loop is simple (plan §4.2):
 *   1. Call the model via a turn-scoped OpenAI Responses adapter.
 *   2. If the response contains client tool calls, execute them locally.
 *   3. Record the matching tool outputs through AIGateway.
 *   4. Continue from the recorded journal anchor until no client tool calls remain.
 *
 * The worker owns loop termination and its local iteration budget. It does NOT
 * own history expansion, compaction, continuation anchors, or durable response
 * state; those remain in AIGateway. The worker executes tools, records their
 * results, and explicitly reports when the whole Agent turn has ended.
 */

import { Buffer } from 'node:buffer'
import { createHash, randomBytes } from 'node:crypto'
import {
  safeJsonParse as safeJSONParse,
  safeJsonStringify as safeJSONStringify,
  type JsonObject as JSONObject
} from '@pleisto/active-support'
import { withRetry } from '../common/async'
import { errorMessage } from '../common/errors'
import {
  assistantText,
  createModelTurn,
  MAX_TOOL_ARGUMENT_BYTES,
  validateToolArgumentsWithRepair,
  type Message,
  type AssistantMessage,
  type ToolResultMessage,
  type UserMessage,
  type ImageContent,
  type ModelTurn,
  type ToolCall
} from './llm'
import { classifyLLMError, isLocallyRetryableLLMError } from './llm-error-classifier'
import type { AgentLoopConfig, AgentLoopResult, AgentTool, AgentToolResult, ReplyPresentationEvent } from './types'
import { contentText, imageSummaryBlock, modelImageAdaptation, responseImageUnavailableText } from './vision'

const EMPTY_AFTER_TOOL_NUDGE_TEXT =
  'You just executed tool calls but returned an empty response. Please process the tool results above and continue with the task.'
const MODEL_ITERATION_LIMIT_SYNTHESIS_TEXT =
  "You've reached the maximum number of tool-calling iterations allowed. Please provide a final response summarizing what you've found and accomplished so far, without calling any more tools."
const TOOL_ERROR_RECOVERY_HINT = 'Analyze the error above and try a different approach.'
const VOLATILE_TOOL_ARGUMENT_KEYS = new Set([
  'idempotency_key',
  'nonce',
  'request_id',
  'timestamp',
  'tool_call_id',
  'uuid'
])

/**
 * Runs the model/tool loop until the model returns a final assistant message.
 *
 * Stateful turns keep only the current round's local messages in the worker.
 * Tool outputs are recorded through AIGateway and then continued from the new
 * response id, which avoids replaying local transcripts into a stateful store.
 */
export async function runAgentLoop(config: AgentLoopConfig): Promise<AgentLoopResult> {
  let pendingMessages: Message[] = [...config.messages]
  let latestAssistant: AssistantMessage | undefined
  let latestResponseID: string | undefined
  let outcome: AgentLoopResult['outcome'] = 'loop_finished'
  let modelIterations = 0
  let sawToolResults = false
  let nudgedEmptyAfterTools = false
  let repairedFinalResponse = false
  const repeatedFailureState: RepeatedToolFailureState = { count: 0 }
  const maxModelIterations = config.maxModelIterations
  const toolByName = config.tools?.length ? agentToolMap(config.tools) : undefined
  const emitPresentationEvent = presentationEmitter(config)
  const modelTurn = createModelTurn(config.model, {
    stateful: config.stateful,
    abortSignal: config.abortSignal,
    onActivity: config.onActivity,
    onTextDelta: delta => {
      config.onActivity?.('model_text_delta')
      config.onTextDelta?.(delta)
    }
  })

  try {
    await emitPresentationEvent({
      kind: 'turn.phase',
      payload: {
        operation_id: 'turn',
        state: 'working',
        label: '正在理解请求'
      }
    })

    while (true) {
      if (modelIterations >= maxModelIterations) {
        const synthesized = await synthesizeAfterModelIterationLimit({
          config,
          maxModelIterations,
          modelTurn
        })
        latestAssistant = synthesized.message
        latestResponseID = requiredResponseID(synthesized.responseID)
        outcome = 'iteration_exhausted'
        break
      }

      // Build tool definitions each round so the abort signal and local config
      // stay turn-scoped even though the schema objects are reusable.
      const tools = toolByName
        ? Object.fromEntries(
            Array.from(toolByName.values()).map(t => [
              toolIdentity(t.namespace, t.name),
              {
                name: t.name,
                description: t.description,
                parameters: t.schema,
                ...(t.inputFormat ? { inputFormat: t.inputFormat } : {}),
                ...(t.jsonSchema ? { jsonSchema: t.jsonSchema } : {}),
                ...(t.namespace ? { namespace: t.namespace } : {}),
                ...(t.namespaceDescription !== undefined ? { namespaceDescription: t.namespaceDescription } : {}),
                ...(t.deferLoading ? { deferLoading: true } : {}),
                ...(t.toolSearchText ? { toolSearchText: t.toolSearchText } : {}),
                allowedCallers: programmaticCallers(t),
                execute: async (args: unknown, opts: { toolCallID: string }) => {
                  return t.execute(opts.toolCallID, args as never, config.abortSignal)
                }
              }
            ])
          )
        : undefined

      // Call the model.
      modelIterations += 1
      let modelAttempt = 0
      const result = await withRetry(
        async () => {
          modelAttempt += 1
          const startedAt = Date.now()
          const requestFields = modelCallFields(config, modelIterations, modelAttempt, pendingMessages, tools)
          config.logger?.info('worker.model_call_started', 'worker model call started', requestFields)
          config.onActivity?.('model_call_start')
          try {
            const result = await modelTurn.call({
              instructions: config.systemPrompt,
              messages: pendingMessages,
              tools: tools as never,
              hostedTools: config.hostedTools,
              programmaticToolCalling: true,
              maxOutputTokens: config.maxTokens,
              temperature: config.temperature,
              text: config.text
            })
            config.onActivity?.('model_call_done')
            const terminalError = terminalModelError(result.message)
            if (terminalError) throw terminalError
            config.logger?.info('worker.model_call_completed', 'worker model call completed', {
              ...requestFields,
              duration_ms: Date.now() - startedAt,
              response_id: result.responseID,
              stop_reason: result.message.stopReason
            })
            return result
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
        {
          maxAttempts: 3,
          signal: config.abortSignal,
          isRetryable: isLocallyRetryableLLMError
        }
      )

      latestAssistant = result.message
      latestResponseID = requiredResponseID(result.responseID)

      // A tool-call-shaped item is executable only when the provider also
      // proved a successful tool-use terminal. Partial/error/length responses
      // may retain diagnostic call fragments, but they never cross this gate.
      if (latestAssistant.stopReason !== 'toolUse') {
        if (shouldNudgeEmptyAfterTools(latestAssistant, sawToolResults, nudgedEmptyAfterTools)) {
          nudgedEmptyAfterTools = true
          pendingMessages = [{ role: 'user', content: EMPTY_AFTER_TOOL_NUDGE_TEXT }]
          continue
        }

        if (!repairedFinalResponse && latestAssistant.stopReason === 'stop') {
          const repairMessage = config.repairFinalResponse?.(latestAssistant)
          if (repairMessage) {
            repairedFinalResponse = true
            pendingMessages = [repairMessage]
            continue
          }
        }

        break
      }

      if (!result.hasToolCalls || !latestAssistant.toolCalls?.length) {
        throw new Error('LLM provider returned toolUse without a completed tool call')
      }

      const toolCalls = latestAssistant.toolCalls
      const executedToolCalls = config.withActivitySuspended
        ? await config.withActivitySuspended('tool_execution', () =>
            executeToolCalls(toolCalls, toolByName, config, emitPresentationEvent)
          )
        : await executeToolCalls(toolCalls, toolByName, config, emitPresentationEvent)
      const turnTerminated = executedToolCalls.some(result => result.terminate && !result.failure)
      const toolResults = executedToolCalls.map(result => result.resultMsg)
      const completeActorEventIDs = [...new Set(executedToolCalls.flatMap(result => result.completeActorEventIDs))]
      const toolFollowUpMessages = [
        ...executedToolCalls.flatMap(result => result.followUpMessages),
        ...repeatedToolFailureNudges(executedToolCalls, repeatedFailureState)
      ]

      const toolJournalMessages: Message[] = [...toolResults, ...toolFollowUpMessages]
      if (toolJournalMessages.length > 0) {
        sawToolResults = true
        nudgedEmptyAfterTools = false
      }
      let nextMessages: Message[] = toolJournalMessages

      // In stateful mode, tool results become a stored AIGateway response. The
      // next model call should anchor to that response id instead of sending the
      // same tool output messages again.
      if (toolJournalMessages.length > 0) {
        let recordAttempt = 0
        const recorded = await withRetry(
          async () => {
            recordAttempt += 1
            const startedAt = Date.now()
            const recordFields: JSONObject = {
              actor_event_id: config.stateful.actorEventID,
              attempt: recordAttempt,
              tool_result_count: toolJournalMessages.length,
              complete_actor_event_count: completeActorEventIDs.length
            }

            config.logger?.info(
              'worker.tool_results_record_started',
              'worker tool results record started',
              recordFields
            )
            config.onActivity?.('tool_results_record_start')
            try {
              const result = await modelTurn.recordToolResults(toolJournalMessages, { completeActorEventIDs })
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
                ...modelErrorFields(error),
                will_retry: recordAttempt < 3 && retryable && !config.abortSignal?.aborted
              })
              throw error
            } finally {
              config.onActivity?.('tool_results_record_done')
            }
          },
          {
            maxAttempts: 3,
            signal: config.abortSignal,
            isRetryable: isLocallyRetryableLLMError
          }
        )

        latestResponseID = requiredResponseID(recorded.responseID)
        nextMessages = []
      }

      if (turnTerminated) break

      const steeringMessages = config.getSteeringMessages ? await config.getSteeringMessages() : []
      pendingMessages = [...nextMessages, ...steeringMessages]
      await emitPresentationEvent({
        kind: 'turn.phase',
        payload: {
          operation_id: 'turn',
          state: 'working',
          label: '正在整理结果'
        }
      })
    }
  } finally {
    modelTurn.close()
  }

  if (!latestAssistant || !latestResponseID) {
    throw new Error('agent loop completed without a response-backed assistant message')
  }
  return { message: latestAssistant, responseID: latestResponseID, outcome }
}

/**
 * Builds a name-indexed tool map and rejects duplicates before model exposure.
 */
function agentToolMap(tools: AgentTool[]): Map<string, AgentTool> {
  const byName = new Map<string, AgentTool>()

  for (const tool of tools) {
    const identity = toolIdentity(tool.namespace, tool.name)
    if (byName.has(identity)) {
      throw new Error(`duplicate tool name: ${identity}`)
    }

    byName.set(identity, tool)
  }

  return byName
}

function toolIdentity(namespace: string | undefined, name: string): string {
  return namespace ? `${namespace}.${name}` : name
}

function programmaticCallers(tool: AgentTool): Array<'direct' | 'programmatic'> {
  if (tool.allowedCallers) return tool.allowedCallers
  return tool.isReadOnly === true && tool.isDestructive !== true ? ['direct', 'programmatic'] : ['direct']
}

/**
 * Decides whether to nudge once after tools produced output but the model
 * returned an empty final answer.
 *
 * This keeps a flaky provider response from silently swallowing useful tool
 * work, while avoiding an infinite "please continue" loop.
 */
export function shouldNudgeEmptyAfterTools(
  message: AssistantMessage,
  sawToolResults: boolean,
  alreadyNudged: boolean
): boolean {
  return sawToolResults && !alreadyNudged && message.stopReason === 'stop' && assistantText(message).trim().length === 0
}

/**
 * Turns every failed terminal into an exception. The retry wrapper's
 * classifier, not this projection layer, decides whether the same request is
 * safe to issue again.
 */
function terminalModelError(message: AssistantMessage): Error | undefined {
  if (message.stopReason !== 'error' && message.stopReason !== 'aborted') return undefined
  const error = new Error(message.errorMessage || 'LLM provider returned an error')
  error.name = 'LLMProviderTerminalError'
  return error
}

interface ExecutedToolCall {
  toolName: string
  resultMsg: ToolResultMessage
  followUpMessages: UserMessage[]
  completeActorEventIDs: string[]
  terminate: boolean
  failure?: {
    key: string
    toolName: string
  }
}

interface RepeatedToolFailureState {
  key?: string
  count: number
}

interface ModelIterationLimitSynthesisInput {
  config: AgentLoopConfig
  maxModelIterations: number
  modelTurn: ModelTurn
}

/**
 * Mirrors Hermes' max-iteration finalizer: once the main model/API iteration
 * budget is spent, make one final no-tools call asking the model to summarize.
 */
async function synthesizeAfterModelIterationLimit(input: ModelIterationLimitSynthesisInput) {
  const pendingMessages: Message[] = [
    {
      role: 'user' as const,
      content: `${MODEL_ITERATION_LIMIT_SYNTHESIS_TEXT}\nmax_model_iterations=${input.maxModelIterations}`
    }
  ]

  const result = await withRetry(
    () => {
      input.config.onActivity?.('model_iteration_limit_synthesis_start')
      return input.modelTurn
        .call({
          instructions: input.config.systemPrompt,
          messages: pendingMessages,
          maxOutputTokens: input.config.maxTokens,
          temperature: input.config.temperature,
          text: input.config.text
        })
        .finally(() => input.config.onActivity?.('model_iteration_limit_synthesis_done'))
    },
    {
      maxAttempts: 3,
      signal: input.config.abortSignal,
      isRetryable: isLocallyRetryableLLMError
    }
  )

  return result
}

function requiredResponseID(responseID: string | undefined): string {
  if (!responseID?.startsWith('resp_')) {
    throw new Error('AIGateway model call completed without a valid response id')
  }
  return responseID
}

/**
 * Executes the model's requested tool calls in the safest available order.
 *
 * Mixed or side-effecting batches stay sequential so user-visible state changes
 * happen in model order.
 */
async function executeToolCalls(
  toolCalls: ToolCall[],
  toolByName: Map<string, AgentTool> | undefined,
  config: AgentLoopConfig,
  emitPresentationEvent: PresentationEmitter
): Promise<ExecutedToolCall[]> {
  const executeOne = (toolCall: ToolCall) => executeToolCall(toolCall, toolByName, config, emitPresentationEvent)
  if (canExecuteToolCallsInParallel(toolCalls, toolByName)) {
    return Promise.all(toolCalls.map(executeOne))
  }

  const results: ExecutedToolCall[] = []
  for (const toolCall of toolCalls) {
    const result = await executeOne(toolCall)
    results.push(result)
    if (result.terminate && !result.failure) break
  }
  return results
}

/**
 * Allows parallel execution only when every requested tool explicitly declares
 * itself read-only and parallel-safe.
 */
function canExecuteToolCallsInParallel(toolCalls: ToolCall[], toolByName: Map<string, AgentTool> | undefined): boolean {
  return toolCalls.length > 1 && toolCalls.every(toolCall => canExecuteToolCallInParallel(toolCall, toolByName))
}

/**
 * Checks the execution policy for one model-requested tool call.
 */
function canExecuteToolCallInParallel(toolCall: ToolCall, toolByName: Map<string, AgentTool> | undefined): boolean {
  const tool = toolByName?.get(toolIdentity(toolCall.namespace, toolCall.name))
  return tool?.executionMode === 'parallel' && tool.isReadOnly === true && tool.isDestructive !== true
}

/**
 * Executes one tool call and returns the matching Responses output item.
 *
 * Tool lookup, JSON parsing, schema validation, and runtime failures are sent
 * back to the model as tool output because the model must see why its requested
 * action did not happen.
 */
async function executeToolCall(
  toolCall: ToolCall,
  toolByName: Map<string, AgentTool> | undefined,
  config: AgentLoopConfig,
  emitPresentationEvent: PresentationEmitter
): Promise<ExecutedToolCall> {
  const tool = toolByName?.get(toolIdentity(toolCall.namespace, toolCall.name))

  if (!tool) {
    const message = `Unknown tool: ${toolCall.name}`
    config.logger?.warning('worker.tool_call_rejected', 'worker tool call rejected', {
      actor_event_id: config.stateful.actorEventID,
      tool_name: toolCall.name,
      tool_call_id: toolCall.id,
      failure_code: 'unknown_tool'
    })
    return {
      toolName: toolCall.name,
      resultMsg: {
        role: 'tool',
        toolCallID: toolCall.id,
        toolCallType: toolCall.type,
        result: toolOutputForCaller(formatToolError(message), toolCall.caller),
        ...(toolCall.caller ? { caller: toolCall.caller } : {})
      },
      followUpMessages: [],
      completeActorEventIDs: [],
      terminate: false,
      failure: {
        key: toolCallFailureKey(toolCall, 'unknown_tool', toolCall.arguments),
        toolName: toolCall.name
      }
    }
  }

  let parsedArgs: unknown
  try {
    if ((toolCall.type === 'custom') !== Boolean(tool.inputFormat)) {
      throw new Error(`tool input type does not match ${toolCall.name}`)
    }

    if (toolCall.type === 'custom') {
      if (Buffer.byteLength(toolCall.arguments, 'utf8') > MAX_TOOL_ARGUMENT_BYTES) {
        throw new Error(`tool input exceeds the ${MAX_TOOL_ARGUMENT_BYTES}-byte limit`)
      }
      parsedArgs = tool.schema.parse(toolCall.arguments)
    } else {
      const validated = validateToolArgumentsWithRepair(toolCall.arguments, tool.schema)
      parsedArgs = validated.value
      if (validated.repair !== 'none') config.onActivity?.(`tool_arguments_repaired:${validated.repair}`)
    }
  } catch (error) {
    const message = `Invalid arguments for tool ${toolCall.name}: ${errorMessage(error)}`
    config.logger?.warning('worker.tool_call_rejected', 'worker tool call rejected', {
      actor_event_id: config.stateful.actorEventID,
      tool_name: toolCall.name,
      tool_call_id: toolCall.id,
      failure_code: 'invalid_arguments'
    })
    return {
      toolName: toolCall.name,
      resultMsg: {
        role: 'tool',
        toolCallID: toolCall.id,
        toolCallType: toolCall.type,
        result: toolOutputForCaller(formatToolError(message), toolCall.caller),
        ...(toolCall.caller ? { caller: toolCall.caller } : {})
      },
      followUpMessages: [],
      completeActorEventIDs: [],
      terminate: false,
      failure: {
        key: toolCallFailureKey(toolCall, 'invalid_arguments', toolCall.arguments),
        toolName: toolCall.name
      }
    }
  }

  const activity = toolActivity(toolCall, tool, parsedArgs)
  if (activity) {
    await emitPresentationEvent({
      kind: 'tool.activity',
      payload: { ...activity, phase: 'running' }
    })
  }

  let toolResult: AgentToolResult<unknown>
  let resultText = ''
  let followUpMessages: UserMessage[] = []
  let failure: ExecutedToolCall['failure']
  const toolStartedAt = Date.now()

  config.logger?.info('worker.tool_call_started', 'worker tool call started', {
    actor_event_id: config.stateful.actorEventID,
    tool_name: toolCall.name,
    tool_call_id: toolCall.id,
    execution_mode: tool.executionMode,
    read_only: tool.isReadOnly === true,
    destructive: tool.isDestructive === true
  })

  try {
    config.onActivity?.(`tool:${toolCall.name}:start`)
    toolResult = await tool.execute(toolCall.id, parsedArgs as never, config.abortSignal)
    const processed = await processToolResultForModel(toolResult, config)
    resultText = processed.outputText
    followUpMessages = processed.followUpMessages
    for (const event of toolResult.presentation ?? []) {
      await emitPresentationEvent(event)
    }
  } catch (e) {
    const message = `Error: ${errorMessage(e)}`
    toolResult = {
      content: [{ type: 'text', text: message }],
      details: { error: String(e) }
    }
    resultText = formatToolError(message)
    failure = {
      key: toolCallFailureKey(toolCall, 'runtime_error', parsedArgs),
      toolName: toolCall.name
    }
  } finally {
    config.onActivity?.(`tool:${toolCall.name}:done`)
  }

  const toolLogFields: JSONObject = {
    actor_event_id: config.stateful.actorEventID,
    tool_name: toolCall.name,
    tool_call_id: toolCall.id,
    duration_ms: Date.now() - toolStartedAt,
    output_chars: resultText.length,
    terminate: toolResult.terminate === true
  }

  if (failure) {
    config.logger?.warning('worker.tool_call_failed', 'worker tool call failed', {
      ...toolLogFields,
      failure_code: 'runtime_error'
    })
  } else {
    config.logger?.info('worker.tool_call_completed', 'worker tool call completed', toolLogFields)
  }

  if (activity) {
    const completedActivity = failure ? activity : completedToolActivity(activity, tool, parsedArgs, toolResult.details)

    await emitPresentationEvent({
      kind: 'tool.activity',
      payload: { ...completedActivity, phase: failure ? 'failed' : 'completed' }
    })
  }

  return {
    toolName: toolCall.name,
    resultMsg: {
      role: 'tool',
      toolCallID: toolCall.id,
      toolCallType: toolCall.type,
      result: toolOutputForCaller(resultText || safeJSONStringify(toolResult.details), toolCall.caller),
      ...(toolCall.caller ? { caller: toolCall.caller } : {})
    },
    followUpMessages,
    completeActorEventIDs: toolResult.completeActorEventIDs ?? [],
    terminate: toolResult.terminate === true,
    failure
  }
}

function modelCallFields(
  config: AgentLoopConfig,
  modelIteration: number,
  attempt: number,
  messages: Message[],
  tools: Record<string, unknown> | undefined
): JSONObject {
  return {
    actor_event_id: config.stateful.actorEventID,
    model: config.model.name,
    provider: config.model.provider,
    selector: config.model.selector,
    model_iteration: modelIteration,
    attempt,
    input_message_count: messages.length,
    tool_count: tools ? Object.keys(tools).length : 0,
    hosted_tool_count: config.hostedTools?.length ?? 0
  }
}

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

type PresentationEmitter = (event: ReplyPresentationEvent) => Promise<void>

/**
 * Assigns one turn-local monotonic revision and keeps live presentation
 * delivery best-effort. A transport failure must not turn a successful tool
 * execution into a failed Agent turn.
 */
function presentationEmitter(config: AgentLoopConfig): PresentationEmitter {
  let revision = 0

  return async event => {
    if (!config.onPresentationEvent) return

    const next: ReplyPresentationEvent = {
      kind: event.kind,
      payload: { ...event.payload, revision: ++revision }
    }

    try {
      await config.onPresentationEvent(next)
    } catch {
      config.onActivity?.('reply_presentation_event_failed')
    }
  }
}

/**
 * Projects validated tool parameters into a bounded human summary. A tool can
 * suppress its row with `null`; raw arguments remain inside the trace boundary.
 */
function toolActivity(toolCall: ToolCall, tool: AgentTool, parsedArgs: unknown): JSONObject | null {
  let described: string | null | undefined
  try {
    described = tool.describeActivity(parsedArgs)
  } catch {
    described = undefined
  }

  if (described === null) return null
  const label = described?.trim() || '处理请求'

  return {
    operation_id: toolCall.id,
    label,
    consequential: tool.isDestructive === true
  }
}

/**
 * Lets a tool replace its parameter-only label with safe result facts. Summary
 * failures do not change tool execution or remove the original activity.
 */
function completedToolActivity(
  activity: JSONObject,
  tool: AgentTool,
  parsedArgs: unknown,
  details: unknown
): JSONObject {
  if (!tool.describeCompletedActivity) return activity

  try {
    const described = tool.describeCompletedActivity(parsedArgs, details)
    const label = described?.trim()
    return label ? { ...activity, label } : activity
  } catch {
    return activity
  }
}

function formatToolError(message: string): string {
  return `${message}\n${TOOL_ERROR_RECOVERY_HINT}`
}

/**
 * Adds a nonce-bearing trust boundary around tool text before it is stored back
 * into the model transcript. A malicious page/file/command output can include a
 * fake closing delimiter, but it cannot predict the per-call nonce.
 */
function wrapUntrustedToolOutput(text: string): string {
  const nonce = randomBytes(8).toString('hex')
  return `<ankole_untrusted_tool_output nonce="${nonce}">\n${text}\n</ankole_untrusted_tool_output nonce="${nonce}">`
}

function toolOutputForCaller(text: string, caller: ToolCall['caller']): string {
  // AIGateway removes nested program outputs from the model transcript and
  // sends them only to the isolated program runtime. Keep the value decodable.
  return caller?.type === 'program' ? text : wrapUntrustedToolOutput(text)
}

function repeatedToolFailureNudges(results: ExecutedToolCall[], state: RepeatedToolFailureState): UserMessage[] {
  const nudges: UserMessage[] = []
  for (const result of results) {
    if (!result.failure) {
      state.key = undefined
      state.count = 0
      continue
    }

    if (state.key === result.failure.key) {
      state.count += 1
    } else {
      state.key = result.failure.key
      state.count = 1
    }

    if (state.count === 2) {
      nudges.push({
        role: 'user',
        content: repeatedToolFailureWarning(result.failure.toolName, state.count)
      })
    }
  }
  return nudges
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

function toolCallFailureKey(toolCall: ToolCall, kind: string, args: unknown): string {
  const stableInput = {
    kind,
    name: toolCall.name,
    arguments: scrubVolatileToolArguments(parseToolArguments(args))
  }
  return createHash('sha256').update(stableJSON(stableInput)).digest('hex').slice(0, 16)
}

function parseToolArguments(args: unknown): unknown {
  if (typeof args !== 'string') return args
  return safeJSONParse(args).match(
    value => value,
    () => args
  )
}

function scrubVolatileToolArguments(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(scrubVolatileToolArguments)
  if (!value || typeof value !== 'object') return value

  return Object.fromEntries(
    Object.entries(value as JSONObject)
      .filter(([key]) => !VOLATILE_TOOL_ARGUMENT_KEYS.has(key))
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => [key, scrubVolatileToolArguments(entry)])
  )
}

function stableJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`
  if (value && typeof value === 'object') {
    return `{${Object.entries(value as JSONObject)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => `${JSON.stringify(key)}:${stableJSON(entry)}`)
      .join(',')}}`
  }
  return JSON.stringify(value) ?? 'null'
}

/**
 * Converts a tool result into model-visible text and optional follow-up input.
 *
 * Image outputs are special: vision-capable models receive the images directly,
 * text-only models get a fallback summary when configured, and otherwise the
 * model is told that image content was unavailable.
 */
async function processToolResultForModel(
  toolResult: AgentToolResult<unknown>,
  config: AgentLoopConfig
): Promise<{ outputText: string; followUpMessages: UserMessage[] }> {
  const text = contentText(toolResult.content)
  const images = toolResult.content.filter((part): part is ImageContent => part.type === 'image')
  const adaptation = await modelImageAdaptation(
    images,
    { input_modalities: config.modelInputModalities },
    {
      visionFallbackModel: config.visionFallbackModel,
      abortSignal: config.abortSignal
    }
  )

  if (adaptation.kind === 'none') return { outputText: text, followUpMessages: [] }

  if (adaptation.kind === 'direct') {
    return {
      outputText: toolImageOutputText(text, adaptation.images.length),
      followUpMessages: [
        {
          role: 'user',
          content: [{ type: 'text', text: 'Tool returned image content.' }, ...adaptation.images]
        }
      ]
    }
  }

  if (adaptation.kind === 'summary') {
    return {
      outputText: toolImageOutputText(text, images.length),
      followUpMessages: [
        {
          role: 'user',
          content: `${imageSummaryBlock(adaptation.summary, 'tool')}`
        }
      ]
    }
  }

  return {
    outputText: [text, responseImageUnavailableText()].filter(Boolean).join('\n'),
    followUpMessages: []
  }
}

/**
 * Adds a short marker so the tool output records that image content
 * exists even when the binary image travels as a follow-up user message.
 */
function toolImageOutputText(text: string, imageCount: number): string {
  return [text, `[${imageCount} image result${imageCount === 1 ? '' : 's'} attached as follow-up user input]`]
    .filter(Boolean)
    .join('\n')
}
