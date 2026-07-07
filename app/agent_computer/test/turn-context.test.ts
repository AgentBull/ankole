import { describe, expect, it } from 'bun:test'
import type { TurnStart } from '../src/lanes/actor_lane'
import { resolveAgentConversationContext } from '../src/core/turns/turn_context'
import type { TextTurnLoopOptions } from '../src/core/turns/turn_options'

describe('@ankole/agent-computer turn context', () => {
  it('returns injected context without requesting runtime context', async () => {
    const turnStart = turnStartFor('agent-direct-context')
    const opts: TextTurnLoopOptions = {
      workspaceRoot: '/workspace',
      requestAIGatewayApiKey: async () => {
        throw new Error('not used')
      },
      requestAgentConversationContext: async () => {
        throw new Error('not used')
      },
      agentConversationContext: {
        request_id: 'context-1',
        agent_uid: 'agent-direct-context',
        session_id: 'session-1',
        turn: turnStart.turn,
        skills: []
      }
    }

    await expect(resolveAgentConversationContext(turnStart, opts)).resolves.toMatchObject({
      request_id: 'context-1'
    })
  })
})

function turnStartFor(agentUid: string): TurnStart {
  return {
    turn: {
      actor: {
        agent_uid: agentUid,
        session_id: 'session-1'
      },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000901',
      revision: 0
    },
    actor_event: {
      actor_event_id: '00000000-0000-0000-0000-000000000901',
      queue_sequence: 1,
      type: 'im.message.received',
      source_event_id: 'source-1',
      payload_json: {}
    }
  }
}
