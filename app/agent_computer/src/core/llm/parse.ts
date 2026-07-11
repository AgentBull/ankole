import { recordValue, type JsonObject as JSONObject } from '@pleisto/active-support'
import type {
  ResponseFunctionToolCall,
  ResponseOutputItem,
  ResponseOutputMessage,
  Response as OpenAIResponse
} from 'openai/resources/responses/responses'
import type { AssistantMessage, ModelCallResult, ModelUsage, StopReason } from './types'

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
  const result = parseOutputItems(output, modelName, usage, response.status === 'failed' ? 'error' : undefined)
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
  fallbackFunctionCalls: ResponseFunctionToolCall[] = []
): ModelCallResult {
  const functionCalls: ResponseFunctionToolCall[] = [...fallbackFunctionCalls]
  const seenFunctionCallIDs = new Set(functionCalls.map(responseFunctionCallKey).filter(Boolean))
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

    if (item.type === 'function_call') {
      const call = item as ResponseFunctionToolCall
      const id = responseFunctionCallKey(call)
      if (id && !seenFunctionCallIDs.has(id)) {
        functionCalls.push(call)
        seenFunctionCallIDs.add(id)
      }
    }
  }

  const text = textParts.join('') || textFallback
  const stopReason = terminalStatus ?? (functionCalls.length > 0 ? 'toolUse' : 'stop')
  const message: AssistantMessage = {
    role: 'assistant',
    content: text ? [{ type: 'text', text }] : [],
    toolCalls:
      functionCalls.length > 0
        ? functionCalls.map(fc => ({
            id: responseFunctionCallKey(fc) || '',
            type: 'function' as const,
            name: fc.name,
            arguments: fc.arguments
          }))
        : undefined,
    usage,
    stopReason,
    model: modelName,
    ...(errorMessage ? { errorMessage } : {})
  }

  return { message, functionCalls, hasToolCalls: functionCalls.length > 0 }
}

export function rememberFunctionCall(calls: Map<string, ResponseFunctionToolCall>, item: JSONObject): void {
  if (item.type !== 'function_call') return
  const call = item as unknown as ResponseFunctionToolCall
  const callID = responseFunctionCallKey(call)
  if (callID) calls.set(callID, call)
}

export function responseFunctionCallKey(call: Pick<ResponseFunctionToolCall, 'call_id' | 'id'>): string | undefined {
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
