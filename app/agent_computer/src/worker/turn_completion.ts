import type { JobTurnRef } from '../lanes/session_lane'
import { isRuntimeFabricTransportError } from '../fabric/fabric'
import { jsonBytes } from '../fabric/envelope_proto'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import {
  RPCRejectedError,
  RPCTimeoutError,
  type RPCCallOptions,
  type RPCRejection,
  type RPCRequestInit,
  type RPCResponseOf
} from '../lanes/rpc_lane'

/** These aliases keep each terminal RPC method as a literal requester type. */
const abortMethod = 'session_turn.abort'
export type TurnAbortRequester = {
  request(
    method: typeof abortMethod,
    payload: RPCRequestInit<typeof abortMethod>,
    frame: { jobTurn: JobTurnRef },
    options?: RPCCallOptions
  ): Promise<RPCResponseOf<typeof abortMethod> | RPCRejection>
}

export class TurnTerminalRejectedError extends RPCRejectedError {
  constructor(method: typeof abortMethod, rejection: RPCRejection) {
    super(method, rejection)
    this.name = 'TurnTerminalRejectedError'
  }
}

type CompletionRetryOptions = {
  timeoutMs?: number
  retryDelayMs?: number
  onRetry?: (attempt: number, error: unknown) => void
}

export type TurnAbortFailure = {
  code: string
  message: string
  details: JSONObject
}

export async function abortTurnWithAck(
  rpcClient: TurnAbortRequester,
  turn: JobTurnRef,
  failure: TurnAbortFailure,
  options: CompletionRetryOptions = {}
): Promise<RPCResponseOf<typeof abortMethod>> {
  const payload = { code: failure.code, message: failure.message, detailsJson: jsonBytes(failure.details) }
  let attempt = 0

  for (;;) {
    attempt += 1

    try {
      const response = await rpcClient.request(
        abortMethod,
        payload,
        { jobTurn: turn },
        {
          timeoutMs: options.timeoutMs ?? 2_000
        }
      )

      if (!('$typeName' in response)) {
        throw new TurnTerminalRejectedError(abortMethod, response)
      }

      return response
    } catch (error) {
      if (!retryableCompletionError(error)) throw error

      options.onRetry?.(attempt, error)
      await Bun.sleep(options.retryDelayMs ?? 100)
    }
  }
}

// The transport waits out flow control itself and never throws it.
function retryableCompletionError(error: unknown): boolean {
  return error instanceof RPCTimeoutError || (isRuntimeFabricTransportError(error) && error.retryable)
}
