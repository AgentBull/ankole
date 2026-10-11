import type { Envelope } from './envelope_proto'

/** Error codes of the Worker Channel transport. */
export type RuntimeFabricErrorCode = 'socket_closed' | 'timeout' | 'rejected'

export class RuntimeFabricTransportError extends Error {
  /** A lost connection or an unanswered push is transient; a protocol rejection is not. */
  readonly retryable: boolean

  constructor(
    readonly code: RuntimeFabricErrorCode,
    message: string,
    options?: ErrorOptions & { reason?: string }
  ) {
    super(message, options)
    this.name = 'RuntimeFabricTransportError'
    this.retryable = code === 'socket_closed' || code === 'timeout'
    this.reason = options?.reason
  }

  readonly reason?: string
}

export type RuntimeFabricReceiveOutcome =
  | { kind: 'timeout' }
  | { kind: 'envelope'; envelope: Envelope }
  | { kind: 'disconnected'; connectionID: string; reason: string }

export type EnvelopeSendOptions = {
  signal?: AbortSignal
  /** Reports the connection that actually sends this envelope. */
  onSent?: (connectionID: string) => void
}

/** Resolves when the control plane acknowledged the envelope. */
export type EnvelopeSender = (envelope: Envelope, options?: EnvelopeSendOptions) => Promise<void>

export type RuntimeFabricHost = {
  sendEnvelope: EnvelopeSender
  /** Whether a channel is joined, so a send does not wait for a rejoin. */
  readonly isReady: boolean
  awaitReady(signal?: AbortSignal): Promise<void>
  receive(timeoutMs: number): Promise<RuntimeFabricReceiveOutcome>
  /**
   * The reason that this process must stop serving its Agent: the control
   * plane refused a join with `stale_worker_generation`, or no channel has
   * been joined for `maxDisconnectedMs`. Undefined while the Worker may
   * continue.
   */
  isolationReason(maxDisconnectedMs: number): string | undefined
  stop(): void
}

export function isRuntimeFabricTransportError(
  error: unknown,
  code?: RuntimeFabricErrorCode
): error is RuntimeFabricTransportError {
  return error instanceof RuntimeFabricTransportError && (code === undefined || error.code === code)
}
