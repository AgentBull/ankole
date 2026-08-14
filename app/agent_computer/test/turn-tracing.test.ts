import { describe, expect, it } from 'bun:test'
import type { TurnStart } from '../src/lanes/actor_lane'
import {
  configureWorkerTracing,
  finishWorkerSpan,
  forceFlushWorkerTracing,
  startWorkerSpan,
  traceparentFromTurnStart,
  workerTurnTrace
} from '../src/observability/turn-tracing'

describe('worker turn tracing', () => {
  it('creates explicit remote children and exports agent-separated OTLP batches', async () => {
    const exports: Array<{ agentUID: string; payload: Uint8Array }> = []
    configureWorkerTracing(async (payload, agentUID) => {
      exports.push({ agentUID, payload })
    })

    const firstTrace = workerTurnTrace(
      turnStart('agent-1', 'session-1', '00-11111111111111111111111111111111-1111111111111111-01')
    )
    const secondTrace = workerTurnTrace(
      turnStart('agent-2', 'session-2', '00-22222222222222222222222222222222-2222222222222222-01')
    )

    const codexTurn = startWorkerSpan(firstTrace, 'codex.turn')
    const tool = startWorkerSpan(
      firstTrace,
      'tool shell',
      {
        'gen_ai.tool.name': 'shell',
        'gen_ai.tool.call.id': 'call-1'
      },
      codexTurn ? { parent: codexTurn } : {}
    )
    finishWorkerSpan(tool, { attributes: { 'ankole.codex.duration_ms': 12 } })
    finishWorkerSpan(codexTurn)
    finishWorkerSpan(startWorkerSpan(secondTrace, 'tool web_search'))

    await forceFlushWorkerTracing()

    expect(exports.map(entry => entry.agentUID).sort()).toEqual(['agent-1', 'agent-2'])
    for (const entry of exports) {
      expect(entry.payload.byteLength).toBeGreaterThan(0)
      const wireText = new TextDecoder().decode(entry.payload)
      expect(wireText).toContain('ankole-worker')
      expect(wireText).toContain('user.id')
      expect(wireText).toContain('session.id')
    }
  })

  it('rejects invalid or absent traceparent values without initializing a trace', () => {
    const invalid = turnStart('agent-1', 'session-1', 'invalid')
    expect(traceparentFromTurnStart(invalid)).toBeUndefined()
    expect(workerTurnTrace(invalid)).toBeUndefined()

    const missing = turnStart('agent-1', 'session-1')
    expect(traceparentFromTurnStart(missing)).toBeUndefined()
    expect(workerTurnTrace(missing)).toBeUndefined()
  })

  it('does not fail worker shutdown when the control-plane exporter rejects a batch', async () => {
    configureWorkerTracing(async () => {
      throw new Error('control plane unavailable')
    })

    const turnTrace = workerTurnTrace(
      turnStart('agent-shutdown', 'session-shutdown', '00-33333333333333333333333333333333-3333333333333333-01')
    )
    finishWorkerSpan(startWorkerSpan(turnTrace, 'tool shutdown'))

    await expect(forceFlushWorkerTracing()).resolves.toBeUndefined()
  })
})

function turnStart(agentUID: string, sessionID: string, traceparent?: string): TurnStart {
  return {
    workspace_id: 10_000,
    turn: {
      actor: { agent_uid: agentUID, session_id: sessionID },
      activation_uid: `activation-${agentUID}`,
      actor_epoch: 1,
      actor_event_id: `event-${agentUID}`,
      revision: 0
    },
    actor_event: {
      actor_event_id: `event-${agentUID}`,
      queue_sequence: 1,
      type: 'im.message',
      source_event_id: `source-${agentUID}`,
      payload_json: {}
    },
    request_context: traceparent ? { traceparent } : {}
  }
}
