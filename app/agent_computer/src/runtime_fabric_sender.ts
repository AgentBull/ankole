import type { ActorLaneEnvelope } from './actor_lane'

export type EnvelopeTransport = (envelope: ActorLaneEnvelope) => void

export type ReliableEnvelopeSender = (envelope: ActorLaneEnvelope) => Promise<void>

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
  const maxAttempts = options.maxAttempts ?? defaultMaxAttempts
  const initialDelayMs = options.initialDelayMs ?? defaultInitialDelayMs
  const maxDelayMs = options.maxDelayMs ?? defaultMaxDelayMs

  return async envelope => {
    let delayMs = initialDelayMs

    for (let attempt = 1; ; attempt += 1) {
      try {
        transport(envelope)
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

export function isRuntimeFabricBackpressure(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error)
  return message.trim() === 'backpressure'
}
