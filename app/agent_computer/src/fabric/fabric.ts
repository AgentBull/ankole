import * as kernel from '../../../kernel'
import { decodeEnvelope, encodeEnvelope, type Envelope } from './envelope_proto'
import { Buffer } from 'node:buffer'
import { errorMessage } from '../common/errors'

export const runtimeFabricFileProtocol = Buffer.from('ANKOLE_FILE/1')

export type RuntimeFabricErrorCode =
  | 'unknown_route'
  | 'backpressure'
  | 'timeout'
  | 'socket_closed'
  | 'invalid_config'
  | 'invalid_envelope'
  | 'invalid_frame'
  | 'zmq'
  | 'decode_failed'
  | 'native_error'

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

export type RuntimeFabricReceiveOutcome =
  | { kind: 'timeout' }
  | { kind: 'envelope'; envelope: Envelope }
  | { kind: 'worker_file'; frames: Buffer[] }

export type EnvelopeSender = (envelope: Envelope) => Promise<void>

export type FileFrameSender = (frames: Buffer[]) => Promise<void>

export type RuntimeFabricHost = {
  sendEnvelope: EnvelopeSender
  sendFileFrame: FileFrameSender
  receive(timeoutMs: number): Promise<RuntimeFabricReceiveOutcome>
  stop(): void
}

export type RuntimeFabricPhysicalTransport = {
  sendEnvelope(envelope: Buffer): void
  sendFileFrame(frames: Buffer[]): void
  recvRawAsync(timeoutMs: number): Promise<Buffer[] | null>
  stop(): void
}

export type RuntimeFabricRetryOptions = {
  maxAttempts?: number
  initialDelayMs?: number
  maxDelayMs?: number
}

export type RuntimeFabricConnectionConfig = {
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

export function connectRuntimeFabric(config: RuntimeFabricConnectionConfig): RuntimeFabricHost {
  try {
    return createRuntimeFabricHost(
      new kernel.RuntimeFabricDealer(config.endpoint, config.workerID, config.workerID, config.workerAuthKey)
    )
  } catch (error) {
    throw runtimeFabricTransportError(error)
  }
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
    sendFileFrame: frames => sendWithRetry(() => transport.sendFileFrame(frames)),
    async receive(timeoutMs) {
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
      if (frames[0].equals(runtimeFabricFileProtocol)) {
        return { kind: 'worker_file', frames }
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

export function isRuntimeFabricTransportError(
  error: unknown,
  code?: RuntimeFabricErrorCode
): error is RuntimeFabricTransportError {
  return error instanceof RuntimeFabricTransportError && (code === undefined || error.code === code)
}

function runtimeFabricTransportError(error: unknown): RuntimeFabricTransportError {
  if (error instanceof RuntimeFabricTransportError) return error

  const message = errorMessage(error)
  const candidate = message.split(':', 1)[0]?.trim() as RuntimeFabricErrorCode | undefined
  const code = candidate && nativeErrorCodes.has(candidate) ? candidate : 'native_error'
  return new RuntimeFabricTransportError(code, message, { cause: error })
}
