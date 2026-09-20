import * as kernel from '../../../kernel'
import { Buffer } from 'node:buffer'
import { errorMessage, toError } from '../common/errors'
import { workerLogger } from '../worker/logging'
import { decodeEnvelope, encodeEnvelope, type Envelope } from './envelope_proto'
import {
  RuntimeFabricTransportError,
  type RuntimeFabricConnectionOptions,
  type RuntimeFabricErrorCode,
  type RuntimeFabricHost,
  type RuntimeFabricReceiveOutcome
} from './fabric'

/**
 * ZeroMQ DEALER host for a Worker that has not switched to the Channel.
 *
 * The kernel owns the socket; this adapter retries bounded backpressure,
 * converts native errors, and validates received envelopes through the
 * kernel. ZeroMQ has no per-message acknowledgement: `sendEnvelope` resolves
 * when the frame is queued on the socket. `stream` and `transport_seq` stay
 * zero on this transport. The control plane admits the Worker on the
 * `worker_ready` envelope, which this host sends once at start.
 */

export type RuntimeFabricPhysicalTransport = {
  sendEnvelope(envelope: Buffer): void
  recvRawAsync(timeoutMs: number): Promise<Buffer[] | null>
  stop(): void
}

export type RuntimeFabricRetryOptions = {
  maxAttempts?: number
  initialDelayMs?: number
  maxDelayMs?: number
}

export type ZeroMQConnectionConfig = {
  endpoint: string
  workerID: string
  workerAuthKey: string
}

const defaultMaxAttempts = 30
const defaultInitialDelayMs = 25
const defaultMaxDelayMs = 250
const nativeErrorCodes = new Set<RuntimeFabricErrorCode>([
  'unknown_route',
  'backpressure',
  'timeout',
  'socket_closed',
  'invalid_config',
  'invalid_envelope',
  'invalid_frame',
  'zmq'
])

export function connectZeroMQTransport(
  config: ZeroMQConnectionConfig,
  options: RuntimeFabricConnectionOptions
): RuntimeFabricHost {
  let host: RuntimeFabricHost
  try {
    host = createRuntimeFabricHost(
      new kernel.RuntimeFabricDealer(config.endpoint, config.workerID, config.workerID, config.workerAuthKey)
    )
  } catch (error) {
    throw runtimeFabricTransportError(error)
  }

  const readyEnvelope = options.readyEnvelope
  if (!readyEnvelope) return host

  host
    .sendEnvelope(readyEnvelope())
    .then(() => {
      workerLogger.notice('worker.ready_sent', 'worker ready sent', {
        endpoint: config.endpoint,
        worker_id: config.workerID
      })
    })
    .catch(error => {
      workerLogger.error('worker.fabric_ready_failed', 'worker ready could not be sent', { error: toError(error) })
    })

  return host
}

export function createRuntimeFabricHost(
  transport: RuntimeFabricPhysicalTransport,
  options: RuntimeFabricRetryOptions = {}
): RuntimeFabricHost {
  let stopped = false
  const ensureOpen = (): void => {
    if (stopped) {
      throw new RuntimeFabricTransportError('socket_closed', 'socket_closed')
    }
  }
  const sendWithRetry = async (send: () => void): Promise<void> => {
    const maxAttempts = options.maxAttempts ?? defaultMaxAttempts
    const initialDelayMs = options.initialDelayMs ?? defaultInitialDelayMs
    const maxDelayMs = options.maxDelayMs ?? defaultMaxDelayMs
    let delayMs = initialDelayMs

    for (let attempt = 1; ; attempt += 1) {
      try {
        ensureOpen()
        send()
        return
      } catch (error) {
        const transportError = runtimeFabricTransportError(error)
        if (transportError.code !== 'backpressure' || attempt >= maxAttempts) {
          throw transportError
        }

        await Bun.sleep(delayMs)
        delayMs = Math.min(maxDelayMs, delayMs * 2)
      }
    }
  }

  return {
    sendEnvelope: envelope => sendWithRetry(() => transport.sendEnvelope(encodeEnvelope(envelope))),
    async receive(timeoutMs): Promise<RuntimeFabricReceiveOutcome> {
      ensureOpen()
      let frames: Buffer[] | null
      try {
        frames = await transport.recvRawAsync(timeoutMs)
      } catch (error) {
        throw runtimeFabricTransportError(error)
      }

      if (!frames) return { kind: 'timeout' }
      if (!frames[0]) {
        throw new RuntimeFabricTransportError('invalid_frame', 'invalid_frame: received an empty frame set')
      }
      if (frames.length !== 1) {
        throw new RuntimeFabricTransportError(
          'invalid_frame',
          'invalid_frame: envelope receive must contain exactly one frame'
        )
      }

      try {
        // The kernel stays the single semantic checker for received envelopes;
        // structural decoding uses the codec generated from envelope.proto.
        kernel.runtimeFabricValidateEnvelope(frames[0])
        return {
          kind: 'envelope',
          envelope: decodeEnvelope(frames[0])
        }
      } catch (error) {
        const message = errorMessage(error)
        throw new RuntimeFabricTransportError('decode_failed', `decode_failed: ${message}`, { cause: error })
      }
    },
    stop() {
      if (stopped) return
      stopped = true
      try {
        transport.stop()
      } catch (error) {
        throw runtimeFabricTransportError(error)
      }
    }
  }
}

function runtimeFabricTransportError(error: unknown): RuntimeFabricTransportError {
  if (error instanceof RuntimeFabricTransportError) return error

  const message = errorMessage(error)
  const candidate = message.split(':', 1)[0]?.trim() as RuntimeFabricErrorCode | undefined
  const code = candidate && nativeErrorCodes.has(candidate) ? candidate : 'native_error'
  return new RuntimeFabricTransportError(code, message, { cause: error })
}
