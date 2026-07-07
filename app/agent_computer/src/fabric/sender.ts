import type { RuntimeFabricEnvelope } from './fabric'
import type { Buffer } from 'node:buffer'

export type EnvelopeTransport = (envelope: RuntimeFabricEnvelope) => void

export type ReliableEnvelopeSender = (envelope: RuntimeFabricEnvelope) => Promise<void>

export type FileFrameTransport = (frames: Buffer[]) => void

export type ReliableFileFrameSender = (frames: Buffer[]) => Promise<void>

type RetryOptions = {
  maxAttempts?: number
  initialDelayMs?: number
  maxDelayMs?: number
}

const defaultMaxAttempts = 30
const defaultInitialDelayMs = 25
const defaultMaxDelayMs = 250

/**
 * Wraps the synchronous RuntimeFabric DEALER send with a bounded retry loop.
 *
 * ZeroMQ may report `EAGAIN` as `backpressure` during the short window where a
 * DEALER has been created but the ROUTER connection is not yet writable. That
 * should not kill the worker before it can announce readiness; persistent
 * backpressure still bubbles up so the actor runtime can rely on lease recovery.
 */
export function reliableEnvelopeSender(
  transport: EnvelopeTransport,
  options: RetryOptions = {}
): ReliableEnvelopeSender {
  return reliableRuntimeFabricSender(transport, options)
}

export function reliableFileFrameSender(
  transport: FileFrameTransport,
  options: RetryOptions = {}
): ReliableFileFrameSender {
  return reliableRuntimeFabricSender(transport, options)
}

function reliableRuntimeFabricSender<T>(
  transport: (payload: T) => void,
  options: RetryOptions = {}
): (payload: T) => Promise<void> {
  const maxAttempts = options.maxAttempts ?? defaultMaxAttempts
  const initialDelayMs = options.initialDelayMs ?? defaultInitialDelayMs
  const maxDelayMs = options.maxDelayMs ?? defaultMaxDelayMs

  return async payload => {
    let delayMs = initialDelayMs

    for (let attempt = 1; ; attempt += 1) {
      try {
        transport(payload)
        return
      } catch (error) {
        if (!isRuntimeFabricBackpressure(error) || attempt >= maxAttempts) {
          throw error
        }

        await Bun.sleep(delayMs)
        delayMs = Math.min(maxDelayMs, delayMs * 2)
      }
    }
  }
}

/**
 * Detects the kernel's RuntimeFabric backpressure error string.
 */
export function isRuntimeFabricBackpressure(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error)
  return message.trim() === 'backpressure'
}
