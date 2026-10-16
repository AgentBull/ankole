import {
  rpcOperations,
  type RPCMethod,
  type RPCRequestInit,
  type RPCResponseOf,
  type WorkerOwnedRPCMethod,
  type ControlPlaneOwnedRPCMethod,
  type WorkerRPCHandler,
  type WorkerRPCHandlers
} from './rpc_contract'
import { ms } from '@agentbull/active-support'
import { errorMessage } from '../common/errors'
import { create, fromBinary, toBinary, type DescMessage, type MessageInitShape } from '@bufbuild/protobuf'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { RuntimeFabricTransportError, isRuntimeFabricTransportError, type EnvelopeSender } from '../fabric/fabric'
import type { JobTurnRef } from './session_lane'
import { runRefToProto, jobTurnRefToProto } from './session_lane'
import {
  createEnvelope,
  envelopeHeader,
  jsonBytes,
  jsonObjectFromBytes,
  RPCErrorSchema,
  RPCRequestSchema,
  RPCResponseSchema,
  type RPCErrorMessage,
  type RPCRequestMessage,
  type RPCResponseMessage
} from '../fabric/envelope_proto'

import { FileTransferError } from './file/errors'

/** Turn fence of a turn-scoped call. */
export type TurnRPCFrame = { run: import('./session_lane').RunRef } | { jobTurn: JobTurnRef }
export type RPCCallOptions = {
  timeoutMs?: number
  signal?: AbortSignal
  /** Only a safe-read or proven idempotent owner may repeat a sent request. */
  retryOnDisconnect?: boolean
}

/**
 * Frame of one call, enforced per operation scope. A turn method names its
 * turn fence. A worker-agent method has no frame: the control plane takes the
 * Agent from the connection, so the argument is omitted.
 */
export type RPCFrame<M extends ControlPlaneOwnedRPCMethod> = (typeof rpcOperations)[M] extends { scope: 'turn' }
  ? TurnRPCFrame
  : void

/**
 * Shape of the injected RPC caller every turn capability goes through. It
 * generates request ids, converts control-plane rejections into thrown
 * `RPCRejectedError`s, and never applies local fallback behavior.
 */
export type RPCRequester = <M extends ControlPlaneOwnedRPCMethod>(
  method: M,
  payload: RPCRequestInit<M>,
  frame: RPCFrame<M>,
  options?: RPCCallOptions
) => Promise<RPCResponseOf<M>>

/** Control-plane rejection frame of one RPC call. */
export type RPCRejection = {
  retryable?: boolean
  code: string
  message?: string
  details?: JSONObject
}

export function rpcRejectionFromError(error: RPCErrorMessage): RPCRejection {
  return {
    code: error.code,
    retryable: error.retryable,
    ...(error.message ? { message: error.message } : {}),
    ...(() => {
      const details = jsonObjectFromBytes(error.detailsJson, 'rpc_error.details_json')
      return details ? { details } : {}
    })()
  }
}

export function rpcRejectedMessage(label: string, rejection: { code: string; message?: string }): string {
  return `${label}: ${rejection.code} ${rejection.message ?? ''}`.trim()
}

/**
 * Thrown when the control plane rejects an RPC operation. Carries the
 * rejection frame so callers that map rejection codes onto domain errors keep
 * typed access instead of parsing the message.
 */
export class RPCRejectedError extends Error {
  /** Whether the control plane marked the rejection safe to retry. */
  readonly retryable: boolean

  constructor(
    label: string,
    readonly rejection: RPCRejection
  ) {
    super(rpcRejectedMessage(label, rejection))
    this.name = 'RPCRejectedError'
    this.retryable = rejection.retryable === true
  }
}

export class RPCTimeoutError extends Error {
  readonly retryable = true
  readonly code = 'runtime_rpc_timeout'

  constructor(
    readonly method: RPCMethod,
    sent = false
  ) {
    super(
      `RPC request timed out: ${method}${sent ? '; it may already have completed. Verify its durable result before repeating it' : ''}`
    )
    this.name = 'RPCTimeoutError'
  }
}

const defaultRPCTimeoutMs = ms('5m')

type RPCWaiter = {
  resolve: (reply: RPCResponseMessage | RPCErrorMessage) => void
  reject: (error: Error) => void
  method: RPCMethod
  connectionID?: string
}

/**
 * Generates the wire request id for one RPC call. The id is an opaque
 * correlation token; the method-derived prefix only aids log reading.
 */
function rpcRequestID(method: RPCMethod): string {
  return `${method.replaceAll(/[^a-zA-Z0-9]+/g, '-')}-${crypto.randomUUID()}`
}

/**
 * Tracks worker-originated RuntimeFabric RPC calls until the matching
 * response or error envelope arrives.
 *
 * This is the single codec boundary for RPC payloads on the worker: requests
 * are encoded and responses decoded through the `rpcOperations` registry, so a
 * successful decode is the payload validation. RPC is control-lane traffic,
 * not durable actor truth; the timeout prevents a missing control-plane
 * reply from parking the turn loop forever.
 */
export class RuntimeRPCClient {
  private readonly waiters = new Map<string, RPCWaiter>()
  private readonly timeoutMs: number
  private readonly shutdown = new AbortController()

  constructor(
    private readonly sendEnvelope: EnvelopeSender,
    private readonly options: { timeoutMs?: number; awaitReady?: (signal?: AbortSignal) => Promise<void> } = {}
  ) {
    this.timeoutMs = options.timeoutMs ?? defaultRPCTimeoutMs
  }

  awaitReady(signal?: AbortSignal): Promise<void> {
    signal?.throwIfAborted()
    this.shutdown.signal.throwIfAborted()
    const waiting = signal ? AbortSignal.any([signal, this.shutdown.signal]) : this.shutdown.signal
    return this.options.awaitReady?.(waiting) ?? Promise.resolve()
  }

  /** Sends one request. Only its owner can opt into a safe repeat after disconnect. */
  async request<M extends ControlPlaneOwnedRPCMethod>(
    method: M,
    payload: RPCRequestInit<M>,
    frame: RPCFrame<M>,
    options: RPCCallOptions = {}
  ): Promise<RPCResponseOf<M> | RPCRejection> {
    const deadline = new AbortController()
    const signal = AbortSignal.any([deadline.signal, this.shutdown.signal, ...(options.signal ? [options.signal] : [])])
    let sent = false
    const timer = setTimeout(
      () => deadline.abort(new RPCTimeoutError(method, sent)),
      options.timeoutMs ?? this.timeoutMs
    )
    try {
      for (;;) {
        signal.throwIfAborted()
        try {
          return await this.requestOnce(method, payload, frame, signal, () => {
            sent = true
          })
        } catch (error) {
          if (!options.retryOnDisconnect || !isRuntimeFabricTransportError(error, 'socket_closed')) throw error
          // Keep the original deadline and caller cancellation while waiting for
          // the existing connection owner. There is no fixed retry delay.
          for (;;) {
            signal.throwIfAborted()
            try {
              await this.awaitReady(signal)
              break
            } catch (readyError) {
              if (!isRuntimeFabricTransportError(readyError, 'socket_closed')) throw readyError
            }
          }
        }
      }
    } finally {
      clearTimeout(timer)
    }
  }

  private async requestOnce<M extends ControlPlaneOwnedRPCMethod>(
    method: M,
    payload: RPCRequestInit<M>,
    frame: RPCFrame<M>,
    signal: AbortSignal,
    sent: () => void
  ): Promise<RPCResponseOf<M> | RPCRejection> {
    signal.throwIfAborted()
    const turnFrame = frame as TurnRPCFrame | void
    const requestID = rpcRequestID(method)
    const schema = rpcOperations[method]
    const requestBytes = toBinary(schema.request, create(schema.request, payload as MessageInitShape<DescMessage>))
    const sending = new AbortController()
    const reply = await new Promise<RPCResponseMessage | RPCErrorMessage>((resolve, reject) => {
      const finish = () => {
        this.waiters.delete(requestID)
        signal.removeEventListener('abort', abort)
        // A business reply is authoritative even when its push ACK is missing.
        // Cancel any remaining send wait and consume its detached settlement.
        sending.abort(new DOMException('RPC settled', 'AbortError'))
      }
      const waiter: RPCWaiter = {
        method,
        resolve: response => {
          finish()
          resolve(response)
        },
        reject: error => {
          finish()
          reject(error)
        }
      }
      const abort = () => waiter.reject(signal.reason)
      this.waiters.set(requestID, waiter)
      signal.addEventListener('abort', abort, { once: true })
      void this.sendEnvelope(
        createEnvelope({
          ...envelopeHeader(`rpc-request-${crypto.randomUUID()}`),
          body: {
            case: 'rpcRequest',
            value: create(RPCRequestSchema, {
              requestId: requestID,
              method,
              payload: requestBytes,
              ...(turnFrame && 'run' in turnFrame ? { run: runRefToProto(turnFrame.run) } : {}),
              ...(turnFrame && 'jobTurn' in turnFrame ? { jobTurn: jobTurnRefToProto(turnFrame.jobTurn) } : {})
            })
          }
        }),
        {
          signal: sending.signal,
          onSent: connectionID => {
            waiter.connectionID = connectionID
            sent()
          }
        }
      ).catch(error => {
        if (this.waiters.get(requestID) !== waiter) return
        // Sent requests can receive their business reply before or without a
        // push ACK. Ordered disconnect delivery settles only the lost connection.
        if (waiter.connectionID && isRuntimeFabricTransportError(error) && error.retryable) return
        waiter.reject(error)
      })
    })
    if (reply.$typeName === 'ankole.runtime_fabric.v1.RPCError') return rpcRejectionFromError(reply)
    return fromBinary(schema.response, reply.payload) as RPCResponseOf<M>
  }

  resolve(reply: RPCResponseMessage | RPCErrorMessage): void {
    this.waiters.get(reply.requestId)?.resolve(reply)
  }

  /** Called after all replies already received on this connection were delivered. */
  disconnected(connectionID: string): void {
    for (const waiter of this.waiters.values()) {
      if (waiter.connectionID !== connectionID) continue
      waiter.reject(
        new RuntimeFabricTransportError(
          'socket_closed',
          `Control plane connection closed after ${waiter.method} was sent; it may already have completed. ` +
            'Verify its durable result before repeating this operation'
        )
      )
    }
  }

  close(): void {
    if (this.shutdown.signal.aborted) return
    this.shutdown.abort(new DOMException('Worker RPC client stopped', 'AbortError'))
    for (const waiter of this.waiters.values()) {
      waiter.reject(this.shutdown.signal.reason)
    }
  }
}

function isWorkerOwnedRPCMethod(method: string): method is WorkerOwnedRPCMethod {
  return method in rpcOperations && 'owner' in rpcOperations[method as RPCMethod]
}

/**
 * Handles a control-plane-originated RPC request through the worker-owned
 * operation table.
 */
export async function handleWorkerRPCRequest(
  sendEnvelope: EnvelopeSender,
  request: RPCRequestMessage,
  handlers?: WorkerRPCHandlers
): Promise<void> {
  const method = request.method
  const handler = isWorkerOwnedRPCMethod(method) ? handlers?.[rpcOperations[method].handler] : undefined
  if (!isWorkerOwnedRPCMethod(method) || !handler) {
    await sendWorkerRPCError(sendEnvelope, request, 'unknown_rpc_method', `unknown worker RPC method: ${method}`, {
      method
    })
    return
  }

  const schema = rpcOperations[method]
  try {
    // The compiler cannot correlate rpcOperations[M] request/response pairs
    // through the method union, so the payload narrowing happens here once.
    const payload = fromBinary(schema.request, request.payload)
    const result = await (handler as WorkerRPCHandler<WorkerOwnedRPCMethod>)(payload as never)
    await sendWorkerRPCResponse(
      sendEnvelope,
      request,
      toBinary(schema.response, create(schema.response, result as MessageInitShape<DescMessage>))
    )
  } catch (error) {
    if (error instanceof FileTransferError) {
      await sendWorkerRPCError(sendEnvelope, request, error.code, error.message, { method })
    } else if (method.startsWith('worker_files.')) {
      await sendWorkerRPCError(sendEnvelope, request, 'operation_failed', errorMessage(error), {
        method
      })
    } else {
      await sendWorkerRPCError(sendEnvelope, request, 'worker_rpc_failed', errorMessage(error), { method })
    }
  }
}

async function sendWorkerRPCResponse(
  sendEnvelope: EnvelopeSender,
  request: RPCRequestMessage,
  payload: Uint8Array
): Promise<void> {
  await sendEnvelope(
    createEnvelope({
      ...envelopeHeader(`rpc-reply-${crypto.randomUUID()}`),
      body: {
        case: 'rpcResponse',
        value: create(RPCResponseSchema, {
          requestId: request.requestId,
          payload
        })
      }
    })
  )
}

async function sendWorkerRPCError(
  sendEnvelope: EnvelopeSender,
  request: RPCRequestMessage,
  code: string,
  message: string,
  details: JSONObject
): Promise<void> {
  await sendEnvelope(
    createEnvelope({
      ...envelopeHeader(`rpc-reply-${crypto.randomUUID()}`),
      body: {
        case: 'rpcError',
        value: create(RPCErrorSchema, {
          requestId: request.requestId,
          code,
          message,
          retryable: false,
          detailsJson: jsonBytes(details)
        })
      }
    })
  )
}
