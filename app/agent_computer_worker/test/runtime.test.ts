import { describe, expect, it } from 'bun:test'
import { encodeEnvelope } from '../src/actor_bus'
import {
  handleActorBusEnvelope,
  parseWorkerEnv,
  workerCapacityEnvelope,
  workerHeartbeatEnvelope,
  workerReadyEnvelope
} from '../src/runtime'

describe('@ankole/agent-computer-worker runtime', () => {
  it('parses worker env without actor-specific startup args', () => {
    expect(
      parseWorkerEnv({
        ANKOLE_ACTOR_BUS_ENDPOINT: 'tcp://127.0.0.1:6010',
        ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN: 'secret',
        ANKOLE_AGENT_COMPUTER_WORKER_ID: 'worker-a',
        ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID: 'worker-a-1',
        ANKOLE_WORKSPACE_ROOT: '/workspace'
      })
    ).toMatchObject({
      workerId: 'worker-a',
      workerInstanceId: 'worker-a-1',
      workspaceRoot: '/workspace'
    })

    expect(() =>
      parseWorkerEnv({
        ANKOLE_ACTOR_BUS_ENDPOINT: 'tcp://127.0.0.1:6010',
        ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN: 'secret',
        ANKOLE_AGENT_COMPUTER_WORKER_ID: 'worker-a',
        ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID: 'worker-a-1',
        ANKOLE_AGENT_UID: 'agent-1'
      })
    ).toThrow(/must not be set/)
  })

  it('emits worker.ready without actor authority fields', () => {
    const config = {
      endpoint: 'tcp://127.0.0.1:6010',
      preAuthToken: 'secret',
      workerId: 'worker-a',
      workerInstanceId: 'worker-a-1',
      workspaceRoot: '/workspace'
    }
    const ready = workerReadyEnvelope(config)
    const heartbeat = workerHeartbeatEnvelope(config, 123)
    const capacity = workerCapacityEnvelope(config)

    expect(ready.body.type).toBe('worker_ready')
    expect(heartbeat.body.type).toBe('worker_heartbeat')
    expect(capacity.body.type).toBe('worker_capacity')
    expect(JSON.stringify(ready)).not.toContain('agent_uid')
    expect(JSON.stringify(ready)).not.toContain('actor_epoch')
    expect(encodeEnvelope(ready)).toBeInstanceOf(Buffer)
    expect(encodeEnvelope(heartbeat)).toBeInstanceOf(Buffer)
    expect(encodeEnvelope(capacity)).toBeInstanceOf(Buffer)
  })

  it('handles turn.start with accepted and PONG final proposal envelopes', () => {
    const responses = handleActorBusEnvelope({
      protocol_version: 1,
      message_id: 'turn-start-1',
      lane: 'LANE_TURN',
      durability: 'CONTROL_REPLAYABLE',
      body: {
        type: 'turn_start',
        turn_start: {
          turn: {
            actor: { agent_uid: 'agent-1', session_id: 'signal-channel:chat-1' },
            activation_uid: 'activation-1',
            actor_epoch: 1,
            llm_turn_id: 'turn-1',
            revision: 0
          },
          inputs: [
            {
              actor_input_id: 'input-1',
              broker_sequence: 1,
              type: 'im.message.addressed',
              ingress_event_id: 'event-1',
              payload_json: {
                data: {
                  entry: {
                    text: 'PING'
                  }
                }
              }
            }
          ]
        }
      }
    })

    expect(responses.map(response => response.body.type)).toEqual(['turn_accepted', 'turn_final_proposal'])
    expect(
      responses[1].body.turn_final_proposal &&
        typeof responses[1].body.turn_final_proposal === 'object' &&
        'reply' in responses[1].body.turn_final_proposal &&
        responses[1].body.turn_final_proposal.reply
    ).toMatchObject({ text: 'PONG' })
    expect(responses.map(response => response.correlation_id)).toEqual(['turn-start-1', 'turn-start-1'])
    expect(responses.map(response => encodeEnvelope(response))).toEqual([expect.any(Buffer), expect.any(Buffer)])
  })
})
