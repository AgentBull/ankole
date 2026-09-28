import type { Envelope } from './envelope_proto'

/**
 * Transport error codes. `socket_closed | timeout | rejected | flow_control |
 * invalid_envelope | decode_failed | native_error` come from either
 * transport; `unknown_route | backpressure | zmq | invalid_config |
 * invalid_frame` are native ZeroMQ outcomes.
 */
export type RuntimeFabricErrorCode =
  | 'socket_closed'
  | 'timeout'
  | 'rejected'
  | 'flow_control'
  | 'invalid_envelope'
  | 'decode_failed'
  | 'native_error'
  | 'unknown_route'
  | 'backpressure'
  | 'zmq'
  | 'invalid_config'
  | 'invalid_frame'

export class RuntimeFabricTransportError extends Error {
  constructor(
    readonly code: RuntimeFabricErrorCode,
    message: string,
    options?: ErrorOptions
  ) {
    super(message, options)
    this.name = 'RuntimeFabricTransportError'
  }
}

export type RuntimeFabricReceiveOutcome = { kind: 'timeout' } | { kind: 'envelope'; envelope: Envelope }

/** Resolves when the control plane acknowledged the envelope. */
export type EnvelopeSender = (envelope: Envelope) => Promise<void>

export type RuntimeFabricHost = {
  sendEnvelope: EnvelopeSender
  receive(timeoutMs: number): Promise<RuntimeFabricReceiveOutcome>
  stop(): void
}

export function isRuntimeFabricTransportError(
  error: unknown,
  code?: RuntimeFabricErrorCode
): error is RuntimeFabricTransportError {
  return error instanceof RuntimeFabricTransportError && (code === undefined || error.code === code)
}
