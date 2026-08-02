import { describe, expect, it } from 'bun:test'
import type { ActorTurnRef } from '../src/lanes/actor_lane'
import { RPCRejectedError, RPCTimeoutError } from '../src/lanes/rpc_lane'
import { completeTurnWithAck } from '../src/worker/turn_completion'

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
})
