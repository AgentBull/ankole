import { describe, expect, it } from 'bun:test'
import type { JobTurnRef } from '../src/lanes/session_lane'
import { RPCRejectedError, RPCTimeoutError } from '../src/lanes/rpc_lane'
import { abortTurnWithAck } from '../src/worker/turn_completion'

const turn: JobTurnRef = {
  session: { session_id: 'job:1000' },
  job_id: 1000,
  attempt: 1,
  signal_id: 'event-1'
}
const failure = { code: 'worker_turn_failed', message: 'worker failed', details: { retryable: true } }

describe('Job abort acknowledgement', () => {
  it('retries a lost reply until the durable abort is acknowledged', async () => {
    let attempts = 0
    const rpcClient = {
      request: async () => {
        attempts += 1
        if (attempts === 1) throw new RPCTimeoutError('session_turn.abort')
        return {
          $typeName: 'ankole.runtime_fabric.v1.ActorTurnAbortResponse' as const,
          deadLettered: false,
          retryAvailableAt: '2026-08-04T00:00:05Z'
        }
      }
    }
    const result = await abortTurnWithAck(rpcClient, turn, failure, { retryDelayMs: 0, timeoutMs: 10 })
    expect(attempts).toBe(2)
    expect(result.retryAvailableAt).toBe('2026-08-04T00:00:05Z')
  })

  it('does not retry a control-plane rejection', async () => {
    let attempts = 0
    const rpcClient = {
      request: async () => {
        attempts += 1
        return { code: 'job_attempt_mismatch', message: 'stale attempt' }
      }
    }
    await expect(abortTurnWithAck(rpcClient, turn, failure, { retryDelayMs: 0, timeoutMs: 10 })).rejects.toBeInstanceOf(
      RPCRejectedError
    )
    expect(attempts).toBe(1)
  })
})
