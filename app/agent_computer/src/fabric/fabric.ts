import { createChannelTransport } from './channel_transport'
import type { Envelope } from './envelope_proto'
import { connectZeroMQTransport } from './zmq_transport'
import type { RuntimeFabricTransport } from '../worker/config'

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

export type RuntimeFabricConnectionConfig = {
  endpoint: string
  /** Defaults to the endpoint scheme: `tcp://` is ZeroMQ, anything else the Channel. */
  transport?: RuntimeFabricTransport
  workerID: string
  incarnationID?: string
  workerAuthKey: string
}

export type RuntimeFabricConnectionOptions = {
  /**
   * Builds the `worker_ready` envelope: sent after every Channel join, once at
   * ZeroMQ start. A ZeroMQ host without it leaves admission to the caller.
   */
  readyEnvelope?: () => Envelope
}

export function isRuntimeFabricTransportError(
  error: unknown,
  code?: RuntimeFabricErrorCode
): error is RuntimeFabricTransportError {
  return error instanceof RuntimeFabricTransportError && (code === undefined || error.code === code)
}

/**
 * Opens the Worker's RuntimeFabric connection to the control plane.
 *
 * The endpoint scheme selects one physical transport for this process: a
 * ZeroMQ DEALER (`tcp://`) or a Phoenix Channel over one WebSocket (`ws://`,
 * `wss://`). The control plane accepts both while the migration lasts.
 */
export function connectRuntimeFabric(
  config: RuntimeFabricConnectionConfig,
  options: RuntimeFabricConnectionOptions = {}
): RuntimeFabricHost {
  const transport = config.transport ?? (config.endpoint.startsWith('tcp://') ? 'zmq' : 'channel')
  switch (transport) {
    case 'zmq':
      return connectZeroMQTransport(config, options)
    case 'channel': {
      const { readyEnvelope } = options
      if (!readyEnvelope) throw new Error('the Channel transport needs a readyEnvelope for admission')
      return createChannelTransport({ ...config, incarnationID: config.incarnationID ?? '' }, { readyEnvelope })
    }
  }
}
