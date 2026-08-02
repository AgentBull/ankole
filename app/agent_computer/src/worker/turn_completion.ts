import type { ActorTurnRef } from '../lanes/actor_lane'
import { isRuntimeFabricTransportError } from '../fabric/fabric'
import {
  RPCRejectedError,
  RPCTimeoutError,
  rpcMethods,
  type RPCFrame,
  type RPCRejection,
  type RPCRequestInit,
  type RPCResponseOf
} from '../lanes/rpc_lane'

const completionMethod = rpcMethods.actorTurnComplete

export type TurnCompletionRequester = {
  request(
    method: typeof completionMethod,
    payload: RPCRequestInit<typeof completionMethod>,
    frame: RPCFrame<typeof completionMethod>,
    options?: { timeoutMs?: number }
  ): Promise<RPCResponseOf<typeof completionMethod> | RPCRejection>
}

export type TurnCompletionOutcome = 'loop_finished' | 'iteration_exhausted'

export class TurnCompletionRejectedError extends RPCRejectedError {
  constructor(rejection: RPCRejection) {
    super(completionMethod, rejection)
    this.name = 'TurnCompletionRejectedError'
  }
}

type CompletionRetryOptions = {
  timeoutMs?: number
  retryDelayMs?: number
  onRetry?: (attempt: number, error: unknown) => void
}

/**
 * Repeats the terminal completion RPC until the control plane acknowledges its
 * durable commit. The completion anchor is idempotent, so a response lost
 * after commit returns `already_completed` instead of starting another turn.
 */
export async function completeTurnWithAck(
  rpcClient: TurnCompletionRequester,
  turn: ActorTurnRef,
  finalResponseID: string,
  outcome: TurnCompletionOutcome,
  options: CompletionRetryOptions = {}
): Promise<RPCResponseOf<typeof completionMethod>> {
  let attempt = 0

  for (;;) {
    attempt += 1

    try {
      const response = await rpcClient.request(
        completionMethod,
        { finalResponseId: finalResponseID, outcome },
        { turn },
        { timeoutMs: options.timeoutMs ?? 2_000 }
      )

      if (isRejection(response)) {
        throw new TurnCompletionRejectedError(response)
      }

      return response
    } catch (error) {
      if (!retryableCompletionError(error)) throw error

      options.onRetry?.(attempt, error)
      await Bun.sleep(options.retryDelayMs ?? 100)
    }
  }
}

function isRejection(response: RPCResponseOf<typeof completionMethod> | RPCRejection): response is RPCRejection {
  return !('$typeName' in response)
}

function retryableCompletionError(error: unknown): boolean {
  if (error instanceof RPCTimeoutError) return true
  if (!isRuntimeFabricTransportError(error)) return false

  return ['unknown_route', 'backpressure', 'timeout', 'zmq', 'native_error'].includes(error.code)
}
