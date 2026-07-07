import type { JsonObject } from '@pleisto/active-support'
import { toError } from '../../common/errors'
import { isRpcRejected, rpcRejectedMessage, type CodexDelegationEventAppendRequest } from '../../lanes/rpc_lane'

type AuditAppender = (request: CodexDelegationEventAppendRequest) => Promise<unknown>

export class AuditPipeline {
  private seq = 0
  private tail: Promise<void> = Promise.resolve()
  private failureError?: Error

  constructor(
    private readonly input: {
      delegationId: string
      agentUid: string
      append?: AuditAppender
    }
  ) {}

  get failure(): Error | undefined {
    return this.failureError
  }

  get lastSeq(): number | undefined {
    return this.seq > 0 ? this.seq - 1 : undefined
  }

  enqueue(direction: CodexDelegationEventAppendRequest['direction'], eventType: string, payload: JsonObject): void {
    const append = this.input.append
    if (!append) {
      this.failureError = new Error('Codex delegation event RPC is not configured')
      return
    }

    const seq = this.seq++
    this.tail = this.tail
      .then(async () => {
        const response = await append({
          request_id: `codex-event-${crypto.randomUUID()}`,
          delegation_id: this.input.delegationId,
          agent_uid: this.input.agentUid,
          seq,
          direction,
          event_type: eventType,
          payload,
          occurred_at: new Date().toISOString()
        })
        if (isRpcRejected(response)) throw new Error(rpcRejectedMessage('Codex audit event rejected', response))
      })
      .catch(error => {
        this.recordError(error)
      })
  }

  async record(
    direction: CodexDelegationEventAppendRequest['direction'],
    eventType: string,
    payload: JsonObject
  ): Promise<void> {
    this.enqueue(direction, eventType, payload)
    await this.flush()
    this.throwIfFailed()
  }

  async flush(): Promise<void> {
    await this.tail
  }

  recordError(error: unknown): void {
    this.failureError ??= normalizeError(error)
  }

  throwIfFailed(): void {
    if (this.failureError) throw this.failureError
  }
}

function normalizeError(error: unknown): Error {
  return toError(error)
}
