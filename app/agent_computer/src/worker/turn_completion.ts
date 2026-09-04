import type { ActorTurnRef } from '../lanes/actor_lane'
import { isRuntimeFabricTransportError } from '../fabric/fabric'
import { jsonBytes } from '../fabric/envelope_proto'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import {
  RPCRejectedError,
  RPCTimeoutError,
  rpcMethods,
  type RPCFrame,
  type RPCRejection,
  type RPCRequestInit,
  type RPCResponseOf
} from '../lanes/rpc_lane'

/** These aliases keep each terminal RPC method as a literal requester type. */
const completionMethod = rpcMethods.actorTurnComplete
const noopMethod = rpcMethods.actorTurnNoop
const abortMethod = rpcMethods.actorTurnAbort

type TerminalMethod = typeof completionMethod | typeof noopMethod | typeof abortMethod

type TurnTerminalRequester<M extends TerminalMethod> = {
  request(
    method: M,
    payload: RPCRequestInit<M>,
    frame: RPCFrame<M>,
    options?: { timeoutMs?: number }
  ): Promise<RPCResponseOf<M> | RPCRejection>
}

export type TurnCompletionRequester = TurnTerminalRequester<typeof completionMethod>
export type TurnNoopRequester = TurnTerminalRequester<typeof noopMethod>
export type TurnAbortRequester = TurnTerminalRequester<typeof abortMethod>

export type TurnCompletionOutcome = 'loop_finished' | 'iteration_exhausted'

export class TurnCompletionRejectedError extends RPCRejectedError {
  constructor(rejection: RPCRejection) {
    super(completionMethod, rejection)
    this.name = 'TurnCompletionRejectedError'
  }
}

export class TurnTerminalRejectedError extends RPCRejectedError {
  constructor(method: typeof noopMethod | typeof abortMethod, rejection: RPCRejection) {
    super(method, rejection)
    this.name = 'TurnTerminalRejectedError'
  }
}

type CompletionRetryOptions = {
  timeoutMs?: number
  retryDelayMs?: number
  onRetry?: (attempt: number, error: unknown) => void
}

export async function completeTurnWithAck(
  rpcClient: TurnCompletionRequester,
  turn: ActorTurnRef,
  finalResponseID: string,
  outcome: TurnCompletionOutcome,
  options: CompletionRetryOptions = {}
): Promise<RPCResponseOf<typeof completionMethod>> {
  return terminalTurnWithAck(
    rpcClient,
    completionMethod,
    turn,
    { finalResponseId: finalResponseID, outcome },
    options,
    rejection => new TurnCompletionRejectedError(rejection)
  )
}

export type TurnNoop = {
  reason: string
  finalResponseID?: string
}

export async function noopTurnWithAck(
  rpcClient: TurnNoopRequester,
  turn: ActorTurnRef,
  noop: TurnNoop,
  options: CompletionRetryOptions = {}
): Promise<RPCResponseOf<typeof noopMethod>> {
  return terminalTurnWithAck(
    rpcClient,
    noopMethod,
    turn,
    { reason: noop.reason, finalResponseId: noop.finalResponseID ?? '' },
    options,
    rejection => new TurnTerminalRejectedError(noopMethod, rejection)
  )
}

export type TurnAbortFailure = {
  code: string
  message: string
  details: JSONObject
}

export async function abortTurnWithAck(
  rpcClient: TurnAbortRequester,
  turn: ActorTurnRef,
  failure: TurnAbortFailure,
  options: CompletionRetryOptions = {}
): Promise<RPCResponseOf<typeof abortMethod>> {
  return terminalTurnWithAck(
    rpcClient,
    abortMethod,
    turn,
    { code: failure.code, message: failure.message, detailsJson: jsonBytes(failure.details) },
    options,
    rejection => new TurnTerminalRejectedError(abortMethod, rejection)
  )
}

/**
 * Retries a terminal RPC until the control plane confirms its durable commit.
 * Complete, no-op, and abort operations are idempotent. A lost reply is safe
 * to retry, but a semantic rejection is terminal.
 */
async function terminalTurnWithAck<M extends TerminalMethod>(
  rpcClient: TurnTerminalRequester<M>,
  method: M,
  turn: ActorTurnRef,
  payload: RPCRequestInit<M>,
  options: CompletionRetryOptions,
  rejectedError: (rejection: RPCRejection) => RPCRejectedError
): Promise<RPCResponseOf<M>> {
  let attempt = 0

  for (;;) {
    attempt += 1

    try {
      const response = await rpcClient.request(method, payload, { turn } as RPCFrame<M>, {
        timeoutMs: options.timeoutMs ?? 2_000
      })

      if (isRejection(response)) {
        throw rejectedError(response)
      }

      return response
    } catch (error) {
      if (!retryableCompletionError(error)) throw error

      options.onRetry?.(attempt, error)
      await Bun.sleep(options.retryDelayMs ?? 100)
    }
  }
}

function isRejection<M extends TerminalMethod>(response: RPCResponseOf<M> | RPCRejection): response is RPCRejection {
  return !('$typeName' in response)
}

function retryableCompletionError(error: unknown): boolean {
  if (error instanceof RPCTimeoutError) return true
  if (!isRuntimeFabricTransportError(error)) return false

  return ['unknown_route', 'backpressure', 'timeout', 'zmq', 'native_error'].includes(error.code)
}
