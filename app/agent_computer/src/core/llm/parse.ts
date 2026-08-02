import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import type {
  ResponseCustomToolCall,
  ResponseFunctionToolCall,
  ResponseOutputItem,
  ResponseOutputMessage,
  Response as OpenAIResponse
} from 'openai/resources/responses/responses'
import type { AssistantMessage, ModelCallResult, ModelUsage, ResponseToolCall, StopReason } from './types'

export class AIGatewayWebSocketError extends Error {
  readonly code?: string
  readonly status?: number
  readonly details?: unknown

  constructor(message: string, opts: { code?: string; status?: number; details?: unknown } = {}) {
    super(message)
    this.name = 'AIGatewayWebSocketError'
    this.code = opts.code
    this.status = opts.status
    this.details = opts.details
  }
}

export function parseResponse(response: OpenAIResponse, modelName: string): ModelCallResult {
  const output = response.output ?? []
  const usage = usageFromResponse(response.usage)
  const terminal = responseTerminalProjection(response)
  const result = parseOutputItems(output, modelName, usage, terminal.status, '', terminal.errorMessage)
  result.responseID = response.id
  return result
}

export function parseOutputItems(
  output: ResponseOutputItem[],
  modelName: string,
  usage: ModelUsage | undefined,
  terminalStatus?: StopReason,
  textFallback = '',
  errorMessage?: string,
  fallbackToolCalls: ResponseToolCall[] = []
): ModelCallResult {
  const observedToolCalls: ResponseToolCall[] = []
  const terminalToolCallKeys = new Set<string>()
  const textParts: string[] = []

  for (const item of output) {
    if (item.type === 'message') {
      const msg = item as ResponseOutputMessage
      for (const part of msg.content ?? []) {
        if (part.type === 'output_text') {
          textParts.push(part.text ?? '')
        }
      }
      continue
    }

    if (item.type === 'function_call' || item.type === 'custom_tool_call') {
      const call = item as ResponseToolCall
      const id = responseToolCallKey(call)
      if (!id) {
        // Preserve unkeyed fragments long enough for the structural terminal
        // check below to turn the response into an error. Silently dropping
        // one here could make a malformed provider terminal look successful.
        observedToolCalls.push(call)
      } else if (!terminalToolCallKeys.has(id)) {
        observedToolCalls.push(call)
        terminalToolCallKeys.add(id)
      }
    }
  }

  // A terminal Response is authoritative. Streamed done items are only a
  // fallback for gateways that omit complete calls from terminal `output`.
  // This prevents an older valid fragment from hiding a failed, malformed,
  // or otherwise changed terminal call with the same caller-scoped identity.
  for (const call of fallbackToolCalls) {
    const id = responseToolCallKey(call)
    if (!id || !terminalToolCallKeys.has(id)) observedToolCalls.push(call)
  }

  const incompleteToolCall = observedToolCalls.some(call => !completedToolCall(call))
  const effectiveTerminalStatus = incompleteToolCall ? 'error' : terminalStatus
  const toolCalls = effectiveTerminalStatus === undefined ? observedToolCalls.filter(completedToolCall) : []
  const text = textParts.join('') || textFallback
  const stopReason = effectiveTerminalStatus ?? (toolCalls.length > 0 ? 'toolUse' : 'stop')
  const effectiveErrorMessage =
    errorMessage ?? (incompleteToolCall ? 'AIGateway response ended with an incomplete tool call' : undefined)
  const message: AssistantMessage = {
    role: 'assistant',
    content: text ? [{ type: 'text', text }] : [],
    toolCalls:
      toolCalls.length > 0
        ? toolCalls.map(call => ({
            id: responseToolCallID(call) || '',
            type: call.type === 'custom_tool_call' ? ('custom' as const) : ('function' as const),
            name: call.name,
            ...(call.namespace ? { namespace: call.namespace } : {}),
            arguments: call.type === 'custom_tool_call' ? call.input : call.arguments,
            ...(call.caller ? { caller: call.caller } : {})
          }))
        : undefined,
    usage,
    stopReason,
    model: modelName,
    ...(effectiveErrorMessage ? { errorMessage: effectiveErrorMessage } : {})
  }

  return { message, toolCalls, hasToolCalls: toolCalls.length > 0 }
}

function responseTerminalProjection(response: OpenAIResponse): {
  status?: StopReason
  errorMessage?: string
} {
  if (response.status === 'failed') {
    return {
      status: 'error',
      errorMessage: terminalErrorMessage(response as unknown as JSONObject, {})
    }
  }

  if (response.status === 'incomplete') {
    const reason = stringValue(recordValue(response.incomplete_details)?.reason)
    if (reason === 'max_output_tokens') return { status: 'length' }
    return {
      status: 'error',
      errorMessage: `LLM response incomplete reason=${reason || 'unknown'}`
    }
  }

  return {}
}

function completedToolCall(call: ResponseToolCall): boolean {
  const value = call as unknown as JSONObject
  const status = stringValue(value.status)
  return (
    (status === undefined || status === 'completed') &&
    typeof value.call_id === 'string' &&
    value.call_id.length > 0 &&
    typeof value.name === 'string' &&
    value.name.length > 0 &&
    validToolCaller(value.caller) &&
    (call.type === 'custom_tool_call' ? typeof value.input === 'string' : typeof value.arguments === 'string')
  )
}

function validToolCaller(value: unknown): boolean {
  if (value === undefined || value === null) return true
  const caller = recordValue(value)
  if (!caller) return false
  if (caller.type === 'direct') return Object.keys(caller).length === 1
  return (
    caller.type === 'program' &&
    typeof caller.caller_id === 'string' &&
    caller.caller_id.length > 0 &&
    Object.keys(caller).length === 2
  )
}

export function rememberToolCall(calls: Map<string, ResponseToolCall>, item: JSONObject): void {
  if (item.type !== 'function_call' && item.type !== 'custom_tool_call') return
  const call = item as unknown as ResponseToolCall
  const callID = responseToolCallKey(call)
  if (callID) calls.set(callID, call)
}

export function responseToolCallKey(
  call: Pick<ResponseFunctionToolCall | ResponseCustomToolCall, 'call_id' | 'id'>
): string | undefined {
  const id = responseToolCallID(call)
  if (!id) return undefined

  const value = call as unknown as JSONObject
  const caller = recordValue(value.caller)
  const scope =
    caller?.type === 'program' && typeof caller.caller_id === 'string' && caller.caller_id.length > 0
      ? `program:${caller.caller_id}`
      : 'direct'

  return `${scope}\0${id}`
}

function responseToolCallID(
  call: Pick<ResponseFunctionToolCall | ResponseCustomToolCall, 'call_id' | 'id'>
): string | undefined {
  return call.call_id || call.id
}

export function usageFromResponse(usage: unknown): ModelUsage | undefined {
  const value = recordValue(usage)
  if (!value) return undefined

  const outputDetails = recordValue(value.output_tokens_details)
  const inputDetails = recordValue(value.input_tokens_details)

  return {
    inputTokens: numberValue(value.input_tokens) ?? 0,
    outputTokens: numberValue(value.output_tokens) ?? 0,
    reasoningTokens: numberValue(outputDetails?.reasoning_tokens) ?? numberValue(outputDetails?.reasoning),
    cachedInputTokens: numberValue(inputDetails?.cached_tokens) ?? numberValue(inputDetails?.cached)
  }
}

export function terminalErrorMessage(response: JSONObject | undefined, frame: JSONObject): string | undefined {
  const error = recordValue(response?.error) ?? recordValue(frame.error)
  const status =
    numberValue(error?.provider_status) ??
    numberValue(error?.status) ??
    numberValue(error?.status_code) ??
    numberValue(error?.http_status) ??
    numberValue(frame.status)
  const code = stringValue(error?.code) ?? stringValue(frame.code)
  const message = stringValue(error?.message)

  if (status !== undefined || code || message) {
    return [
      'AIGateway response failed',
      status !== undefined ? `status=${status}` : undefined,
      code ? `code=${code}` : undefined,
      message
    ]
      .filter(Boolean)
      .join(' ')
  }

  const incomplete = recordValue(response?.incomplete_details)
  if (typeof incomplete?.reason === 'string') return incomplete.reason
  return undefined
}

export function aigatewayErrorFromFrame(frame: JSONObject): AIGatewayWebSocketError {
  const error = recordValue(frame.error)

  return new AIGatewayWebSocketError(errorFrameMessage(frame), {
    code: stringValue(error?.code) ?? stringValue(frame.code),
    status: numberValue(frame.status) ?? numberValue(error?.status),
    details:
      recordValue(error?.details_json) ??
      recordValue(error?.details) ??
      recordValue(frame.details_json) ??
      recordValue(frame.details)
  })
}

export function webSocketTransportError(
  message: string,
  stage: string,
  localRetryable: boolean
): AIGatewayWebSocketError {
  return new AIGatewayWebSocketError(message, {
    code: `aigateway_websocket_${stage}`,
    details: {
      stage,
      retryable: true,
      local_retryable: localRetryable
    }
  })
}

export function shouldRefreshAuthorizationAfterWebSocketOpenFailure(error: unknown): boolean {
  if (!(error instanceof AIGatewayWebSocketError)) return false
  const details = recordValue(error.details)
  const stage = stringValue(details?.stage)
  return details?.local_retryable === true && stage !== undefined && stage.endsWith('_before_open')
}

function errorFrameMessage(frame: JSONObject): string {
  const error = recordValue(frame.error)
  if (typeof error?.message === 'string') return error.message
  if (typeof frame.message === 'string') return frame.message
  return 'AIGateway WebSocket returned an error frame'
}

export function arrayValue(value: unknown): unknown[] | undefined {
  return Array.isArray(value) ? value : undefined
}

export function numberValue(value: unknown): number | undefined {
  return typeof value === 'number' ? value : undefined
}

export function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}
