import { ms } from '@agentbull/active-support'
import { errorMessage } from '../common/errors'
import {
  create,
  fromBinary,
  toBinary,
  type DescMessage,
  type MessageInitShape,
  type MessageShape
} from '@bufbuild/protobuf'
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
import {
  FilesCommitRequestSchema,
  FilesCommitResponseSchema,
  FilesGetRequestSchema,
  FilesGetResponseSchema,
  FilesListRequestSchema,
  FilesListResponseSchema,
  AIGatewayAPIKeyRequestSchema,
  AIGatewayAPIKeyResponseSchema,
  ActorTurnAbortRequestSchema,
  ActorTurnAbortResponseSchema,
  AutomationJobCreateRequestSchema,
  AutomationJobEmitRequestSchema,
  AutomationJobEmitResponseSchema,
  AutomationJobListRequestSchema,
  AutomationJobRunRequestSchema,
  AutomationJobRunResponseSchema,
  AutomationJobShowRequestSchema,
  AutomationJobTargetRequestSchema,
  BackgroundAgentJobGetRequestSchema,
  BackgroundAgentJobResponseSchema,
  BackgroundAgentJobStatusUpdateRequestSchema,
  BackgroundAgentJobTurnItemsListRequestSchema,
  BackgroundAgentJobTurnItemsListResponseSchema,
  BackgroundAgentJobTurnUpsertRequestSchema,
  BackgroundAgentJobTurnUpsertResponseSchema,
  JSONPassthroughResponseSchema,
  ObservabilitySpansExportRequestSchema,
  ObservabilitySpansExportResponseSchema,
  ReadToolRequestSchema,
  WebhookEndpointCreateRequestSchema,
  WebhookEndpointListRequestSchema,
  WebhookEndpointTargetRequestSchema,
  WorkerEnvResolveRequestSchema,
  WorkerEnvResolveResponseSchema,
  WorkerFileTransferRequestSchema,
  WorkerFileTransferResponseSchema
} from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { FileTransferError } from './file/errors'

/**
 * The operation table owns method names, authorization and payload schemas.
 * Add messages and generate proto, add a row and generate rpc_methods.json,
 * then add the control-plane broker mapping and its function clause.
 */
type RPCOperation =
  | { scope: 'worker_agent'; request: DescMessage; response: DescMessage }
  | { scope: 'turn'; effect: 'read' | 'write' | 'complete'; request: DescMessage; response: DescMessage }
  | { owner: 'worker'; handler: keyof WorkerRPCHandlers; request: DescMessage; response: DescMessage }

export const rpcOperations = {
  'session_turn.abort': {
    scope: 'turn',
    effect: 'complete',
    request: ActorTurnAbortRequestSchema,
    response: ActorTurnAbortResponseSchema
  },
  'ai_gateway.api_key_for.create_or_find_by_agent': {
    scope: 'worker_agent',
    request: AIGatewayAPIKeyRequestSchema,
    response: AIGatewayAPIKeyResponseSchema
  },
  'automation_job.cancel': {
    scope: 'turn',
    effect: 'write',
    request: AutomationJobTargetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'automation_job.create': {
    scope: 'turn',
    effect: 'write',
    request: AutomationJobCreateRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'automation_job.emit': {
    scope: 'worker_agent',
    request: AutomationJobEmitRequestSchema,
    response: AutomationJobEmitResponseSchema
  },
  'automation_job.list': {
    scope: 'turn',
    effect: 'read',
    request: AutomationJobListRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'automation_job.run': {
    owner: 'worker',
    handler: 'runAutomationJob',
    request: AutomationJobRunRequestSchema,
    response: AutomationJobRunResponseSchema
  },
  'automation_job.show': {
    scope: 'turn',
    effect: 'read',
    request: AutomationJobShowRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'background_agent_job.get': {
    scope: 'turn',
    effect: 'read',
    request: BackgroundAgentJobGetRequestSchema,
    response: BackgroundAgentJobResponseSchema
  },
  'background_agent_job.status.update': {
    scope: 'turn',
    effect: 'complete',
    request: BackgroundAgentJobStatusUpdateRequestSchema,
    response: BackgroundAgentJobResponseSchema
  },
  'background_agent_job.turn.upsert': {
    scope: 'turn',
    effect: 'write',
    request: BackgroundAgentJobTurnUpsertRequestSchema,
    response: BackgroundAgentJobTurnUpsertResponseSchema
  },
  'background_agent_job.turn_items.list': {
    scope: 'turn',
    effect: 'read',
    request: BackgroundAgentJobTurnItemsListRequestSchema,
    response: BackgroundAgentJobTurnItemsListResponseSchema
  },
  'files.commit': { scope: 'worker_agent', request: FilesCommitRequestSchema, response: FilesCommitResponseSchema },
  'files.get': { scope: 'worker_agent', request: FilesGetRequestSchema, response: FilesGetResponseSchema },
  'files.list': { scope: 'worker_agent', request: FilesListRequestSchema, response: FilesListResponseSchema },
  'observability.spans.export': {
    scope: 'worker_agent',
    request: ObservabilitySpansExportRequestSchema,
    response: ObservabilitySpansExportResponseSchema
  },
  'tools.read': {
    scope: 'turn',
    effect: 'read',
    request: ReadToolRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'webhook.endpoint.cancel': {
    scope: 'turn',
    effect: 'write',
    request: WebhookEndpointTargetRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'webhook.endpoint.create': {
    scope: 'turn',
    effect: 'write',
    request: WebhookEndpointCreateRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'webhook.endpoint.list': {
    scope: 'turn',
    effect: 'read',
    request: WebhookEndpointListRequestSchema,
    response: JSONPassthroughResponseSchema
  },
  'worker_env.resolve': {
    scope: 'worker_agent',
    request: WorkerEnvResolveRequestSchema,
    response: WorkerEnvResolveResponseSchema
  },
  'worker_files.pull': {
    owner: 'worker',
    handler: 'pullWorkerFile',
    request: WorkerFileTransferRequestSchema,
    response: WorkerFileTransferResponseSchema
  },
  'worker_files.push': {
    owner: 'worker',
    handler: 'pushWorkerFile',
    request: WorkerFileTransferRequestSchema,
    response: WorkerFileTransferResponseSchema
  }
} as const satisfies Record<string, RPCOperation>
export type RPCMethod = keyof typeof rpcOperations

export type RPCRequestInit<M extends RPCMethod> = MessageInitShape<(typeof rpcOperations)[M]['request']>
export type RPCResponseOf<M extends RPCMethod> = MessageShape<(typeof rpcOperations)[M]['response']>
export type WorkerOwnedRPCMethod = {
  [M in RPCMethod]: (typeof rpcOperations)[M] extends { owner: 'worker' } ? M : never
}[RPCMethod]
export type ControlPlaneOwnedRPCMethod = Exclude<RPCMethod, WorkerOwnedRPCMethod>

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

export type WebhookRPCMethod = Extract<RPCMethod, `webhook.${string}`>
export type AutomationJobManagementRPCMethod =
  | 'automation_job.create'
  | 'automation_job.list'
  | 'automation_job.show'
  | 'automation_job.cancel'

/**
 * Family-scoped requesters injected into schedule tools. The turn fence is
 * bound at construction; responses in these families are model-facing
 * passthrough JSON.
 */

export type WebhookRPCRequester = <M extends WebhookRPCMethod>(
  method: M,
  payload: RPCRequestInit<M>
) => Promise<JSONObject>

export type AutomationJobRPCRequester = <M extends AutomationJobManagementRPCMethod>(
  method: M,
  payload: RPCRequestInit<M>
) => Promise<JSONObject>

export function webhookRPCRequester(
  rpc: RPCRequester,
  turn: JobTurnRef | import('./session_lane').RunRef
): WebhookRPCRequester {
  // Every webhook method is turn-scoped; same discharge limit as above.
  return async (method, payload) =>
    passthroughJSON(
      await rpc(method, payload, rpcScope(turn) as RPCFrame<typeof method>, {
        retryOnDisconnect: method === 'webhook.endpoint.list'
      }),
      method
    )
}

export function automationJobRPCRequester(
  rpc: RPCRequester,
  turn: JobTurnRef | import('./session_lane').RunRef
): AutomationJobRPCRequester {
  return async (method, payload) =>
    passthroughJSON(
      await rpc(method, payload, rpcScope(turn) as RPCFrame<typeof method>, {
        retryOnDisconnect: method === 'automation_job.list' || method === 'automation_job.show'
      }),
      method
    )
}

function passthroughJSON(response: { bodyJson: Uint8Array }, method: string): JSONObject {
  return jsonObjectFromBytes(response.bodyJson, `${method} body_json`) ?? {}
}

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

/** One worker-owned operation: the handler that runs it and how its result is reported. */
type WorkerRPCHandler<M extends WorkerOwnedRPCMethod> = (
  request: MessageShape<(typeof rpcOperations)[M]['request']>
) => Promise<MessageInitShape<(typeof rpcOperations)[M]['response']>>

export type WorkerRPCHandlers = {
  runAutomationJob?: WorkerRPCHandler<'automation_job.run'>
  pullWorkerFile?: WorkerRPCHandler<'worker_files.pull'>
  pushWorkerFile?: WorkerRPCHandler<'worker_files.push'>
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
export type {
  AgentConversationContextResponse,
  AgentPluginCatalogEntry,
  AIGatewayAPIKeyResponse,
  AutomationJobRunRequest,
  AutomationJobRunResponse,
  BackgroundAgentJobResponse,
  BackgroundAgentJobTurnUpsertResponse,
  RuntimeSkillSummary
} from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

function rpcScope(ref: JobTurnRef | import('./session_lane').RunRef): TurnRPCFrame {
  return 'job_id' in ref ? { jobTurn: ref } : { run: ref }
}
