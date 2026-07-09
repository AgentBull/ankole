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
    }
  ) {
    this.seq = input.nextSeq ?? 0
  }

  get failure(): Error | undefined {
    return this.failureError
  }

  enqueue(direction: SubagentDelegationAuditEvent['direction'], eventType: string, payload: JsonObject): void {
    this.pending.push({
      seq: this.seq++,
      direction,
      event_type: eventType,
      payload,
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

    const batch = this.pending.splice(0, maxBatchSize)
    if (batch.length > 0) this.appendBatch(batch)
    await this.tail

    if (this.pending.length > 0) await this.flush()
  }

  throwIfFailed(): void {
    if (this.failureError) throw this.failureError
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

    this.tail = this.tail
      .then(async () => {
        const response = await append({
          request_id: `subagent-events-${crypto.randomUUID()}`,
          turn: this.input.turn,
          delegation_id: this.input.delegationId,
          events
        })
        if (isRpcRejected(response)) {
          throw new Error(rpcRejectedMessage('subagent audit event batch rejected', response))
        }
      })
      .catch(error => this.recordError(error))
  }

  private recordError(error: unknown): void {
    this.failureError ??= toError(error)
  }
}
