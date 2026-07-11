import type { JsonObject } from '@pleisto/active-support'
import { toError } from '../../common/errors'
import {
  isRpcRejected,
  rpcRejectedMessage,
  type SubagentDelegationAuditEvent,
  type SubagentDelegationEventAppendRequest
} from '../../lanes/rpc_lane'
import type { ActorTurnRef } from '../../lanes/actor_lane'

type AuditAppender = (request: SubagentDelegationEventAppendRequest) => Promise<unknown>

const flushIntervalMs = 1_000
const maxBatchSize = 20
const appendMaxAttempts = 3
const appendRetryInitialDelayMs = 50
const appendRetryMaxDelayMs = 200

export class SubagentAuditBuffer {
  private seq: number
  private pending: SubagentDelegationAuditEvent[] = []
  private tail: Promise<void> = Promise.resolve()
  private timer?: ReturnType<typeof setTimeout>
  private failureError?: Error

  constructor(
    private readonly input: {
      delegationId: string
      turn: ActorTurnRef
      append?: AuditAppender
      nextSeq?: number
      attempt: number
    }
  ) {
    this.seq = input.nextSeq ?? 0
  }

  get failure(): Error | undefined {
    return this.failureError
  }

  enqueue(direction: SubagentDelegationAuditEvent['direction'], eventType: string, payload: JsonObject): void {
    if (this.failureError) return

    this.pending.push({
      seq: this.seq++,
      direction,
      event_type: eventType,
      payload: { ...payload, attempt: this.input.attempt },
      occurred_at: new Date().toISOString()
    })

    if (this.pending.length >= maxBatchSize) {
      this.scheduleFlush(0)
    } else if (!this.timer) {
      this.scheduleFlush(flushIntervalMs)
    }
  }

  async record(
    direction: SubagentDelegationAuditEvent['direction'],
    eventType: string,
    payload: JsonObject
  ): Promise<void> {
    this.enqueue(direction, eventType, payload)
    await this.flush()
    this.throwIfFailed()
  }

  async flush(): Promise<void> {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = undefined
    }

    if (this.failureError) {
      this.pending = []
      return
    }

    const batch = this.pending.splice(0, maxBatchSize)
    if (batch.length > 0) this.appendBatch(batch)
    await this.tail

    if (this.failureError) {
      this.pending = []
      return
    }

    if (this.pending.length > 0) await this.flush()
  }

  throwIfFailed(): void {
    if (this.failureError) throw new SubagentAuditPersistenceError(this.failureError)
  }

  private scheduleFlush(delayMs: number): void {
    if (this.timer) clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.timer = undefined
      void this.flush().catch(error => this.recordError(error))
    }, delayMs)
    this.timer.unref?.()
  }

  private appendBatch(events: SubagentDelegationAuditEvent[]): void {
    const append = this.input.append
    if (!append) {
      this.recordError(new Error('subagent delegation event RPC is not configured'))
      return
    }

    const request: SubagentDelegationEventAppendRequest = {
      request_id: `subagent-events-${crypto.randomUUID()}`,
      turn: this.input.turn,
      delegation_id: this.input.delegationId,
      events
    }

    this.tail = this.tail.then(() => this.appendBatchWithRetry(append, request)).catch(error => this.recordError(error))
  }

  private async appendBatchWithRetry(
    append: AuditAppender,
    request: SubagentDelegationEventAppendRequest
  ): Promise<void> {
    let delayMs = appendRetryInitialDelayMs

    for (let attempt = 1; attempt <= appendMaxAttempts; attempt += 1) {
      try {
        const response = await append(request)
        if (isRpcRejected(response)) {
          throw new AuditBatchRejectedError(rpcRejectedMessage('subagent audit event batch rejected', response))
        }
        return
      } catch (error) {
        if (error instanceof AuditBatchRejectedError || attempt === appendMaxAttempts) throw error
        await Bun.sleep(delayMs)
        delayMs = Math.min(appendRetryMaxDelayMs, delayMs * 2)
      }
    }
  }

  private recordError(error: unknown): void {
    this.failureError ??= toError(error)
  }
}

class AuditBatchRejectedError extends Error {}

export class SubagentAuditPersistenceError extends Error {
  readonly code: 'subagent_audit_persistence_failed' | 'subagent_audit_persistence_rejected'
  readonly retryable: boolean

  constructor(cause: Error) {
    super(`Subagent audit persistence failed: ${cause.message}`, { cause })
    const rejected = cause instanceof AuditBatchRejectedError
    this.code = rejected ? 'subagent_audit_persistence_rejected' : 'subagent_audit_persistence_failed'
    this.retryable = !rejected
    this.name = 'SubagentAuditPersistenceError'
  }
}
