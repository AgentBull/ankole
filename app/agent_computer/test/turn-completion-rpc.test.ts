import { describe, expect, it } from 'bun:test'
import type { ActorTurnRef } from '../src/lanes/actor_lane'
import { RPCRejectedError, RPCTimeoutError } from '../src/lanes/rpc_lane'
import { abortTurnWithAck, completeTurnWithAck, noopTurnWithAck } from '../src/worker/turn_completion'

const turn: ActorTurnRef = {
  actor: { agent_uid: 'agent-1', session_id: 'session-1' },
  activation_uid: 'activation-1',
  actor_epoch: 1,
  actor_event_id: 'event-1',
  revision: 0
}

describe('turn completion RPC', () => {
  it('retries a timed-out request until the durable completion is acknowledged', async () => {
    let attempts = 0
    const rpcClient = {
      request: async () => {
        attempts += 1
        if (attempts === 1) throw new RPCTimeoutError('actor_turn.complete')

        return {
          $typeName: 'ankole.runtime_fabric.v1.ActorTurnCompleteResponse' as const,
          status: 'already_completed',
          finalResponseId: 'resp-1',
          outcome: 'loop_finished'
        }
      }
    }

    const result = await completeTurnWithAck(rpcClient, turn, 'resp-1', 'loop_finished', {
      retryDelayMs: 0,
      timeoutMs: 10
    })

    expect(attempts).toBe(2)
    expect(result.status).toBe('already_completed')
  })

  it('does not retry a control-plane rejection', async () => {
    let attempts = 0
    const rpcClient = {
      request: async () => {
        attempts += 1
        return { code: 'actor_turn_completion_conflict', message: 'conflict' }
      }
    }

    await expect(
      completeTurnWithAck(rpcClient, turn, 'resp-2', 'loop_finished', {
        retryDelayMs: 0,
        timeoutMs: 10
      })
    ).rejects.toBeInstanceOf(RPCRejectedError)
    expect(attempts).toBe(1)
  })

  it('waits for a durable no-op acknowledgement', async () => {
    let attempts = 0
    const rpcClient = {
      request: async () => {
        attempts += 1
        if (attempts === 1) throw new RPCTimeoutError('actor_turn.noop')

        return {
          $typeName: 'ankole.runtime_fabric.v1.ActorTurnNoopResponse' as const,
          status: 'already_completed',
          reason: 'ambient_silent'
        }
      }
    }

    const result = await noopTurnWithAck(rpcClient, turn, 'ambient_silent', {
      retryDelayMs: 0,
      timeoutMs: 10
    })

    expect(attempts).toBe(2)
    expect(result.status).toBe('already_completed')
  })

  it('waits for a durable abort acknowledgement', async () => {
    let attempts = 0
    const rpcClient = {
      request: async () => {
        attempts += 1
        if (attempts === 1) throw new RPCTimeoutError('actor_turn.abort')

        return {
          $typeName: 'ankole.runtime_fabric.v1.ActorTurnAbortResponse' as const,
          status: 'already_aborted',
          deadLettered: false,
          retryAvailableAt: '2026-08-04T00:00:05Z'
        }
      }
    }

    const result = await abortTurnWithAck(
      rpcClient,
      turn,
      {
        code: 'worker_turn_failed',
        message: 'worker failed',
        details: { retryable: true }
      },
      { retryDelayMs: 0, timeoutMs: 10 }
    )

    expect(attempts).toBe(2)
    expect(result.status).toBe('already_aborted')
  })
})
