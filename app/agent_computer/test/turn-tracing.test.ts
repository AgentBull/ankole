import { describe, expect, it } from 'bun:test'
import type { TurnStart } from '../src/lanes/actor_lane'
import {
  configureWorkerTracing,
  finishWorkerSpan,
  forceFlushWorkerTracing,
  startWorkerSpan,
  traceparentFromTurnStart,
  turnTracePropagationFromTurnStart,
  workerTurnTrace
} from '../src/observability/turn-tracing'

describe('worker turn tracing', () => {
  it('creates explicit remote children and exports agent-separated OTLP batches', async () => {
    const exports: Array<{ agentUID: string; payload: Uint8Array }> = []
    const sharedChannelUserID = 'channel:lark:oc_shared'
    configureWorkerTracing(async (payload, agentUID) => {
      exports.push({ agentUID, payload })
    })

    const firstTrace = workerTurnTrace(
      turnStart('agent-1', 'session-1', '00-11111111111111111111111111111111-1111111111111111-01', sharedChannelUserID)
    )
    const secondTrace = workerTurnTrace(
      turnStart('agent-2', 'session-2', '00-22222222222222222222222222222222-2222222222222222-01', sharedChannelUserID)
    )
    const unattributedTrace = workerTurnTrace(
      turnStart('agent-3', 'session-3', '00-44444444444444444444444444444444-4444444444444444-01')
    )

    expect(firstTrace?.attributes).toEqual({
      'ankole.principal.uid': 'agent-1',
      'ankole.principal.type': 'agent',
      'user.id': sharedChannelUserID,
      'session.id': 'session-1'
    })
    expect(unattributedTrace?.attributes).toEqual({
      'ankole.principal.uid': 'agent-3',
      'ankole.principal.type': 'agent',
      'session.id': 'session-3'
    })

    const codexTurn = startWorkerSpan(firstTrace, 'codex.turn', {
      'ankole.principal.uid': 'spoofed-agent',
      'user.id': 'principal:spoofed-user'
    })
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
    finishWorkerSpan(codexTurn, {
      attributes: {
        'ankole.principal.uid': 'finish-spoofed-agent',
        'ankole.principal.type': 'human',
        'user.id': 'principal:finish-spoofed-user',
        'session.id': 'finish-spoofed-session'
      }
    })
    finishWorkerSpan(startWorkerSpan(secondTrace, 'tool web_search'))
    finishWorkerSpan(startWorkerSpan(unattributedTrace, 'tool internal'))

    await forceFlushWorkerTracing()

    expect(exports.map(entry => entry.agentUID).sort()).toEqual(['agent-1', 'agent-2', 'agent-3'])
    const expectedIdentities: Record<string, { sessionID: string; userID?: string }> = {
      'agent-1': { sessionID: 'session-1', userID: sharedChannelUserID },
      'agent-2': { sessionID: 'session-2', userID: sharedChannelUserID },
      'agent-3': { sessionID: 'session-3' }
    }

    for (const entry of exports) {
      expect(entry.payload.byteLength).toBeGreaterThan(0)
      const wireText = new TextDecoder().decode(entry.payload)
      const expected = expectedIdentities[entry.agentUID]!
      expect(wireText).toContain('ankole-worker')
      expect(wireText).toContain('ankole.principal.uid')
      expect(wireText).toContain(entry.agentUID)
      expect(wireText).toContain('session.id')
      expect(wireText).toContain(expected.sessionID)
      if (expected.userID) {
        expect(wireText).toContain('user.id')
        expect(wireText).toContain(expected.userID)
      } else {
        expect(wireText).not.toContain('user.id')
      }
      expect(wireText).not.toContain('spoofed-agent')
      expect(wireText).not.toContain('spoofed-user')
      expect(wireText).not.toContain('spoofed-session')
    }
  })

  it('rejects invalid traceparents and normalizes observability user boundaries', () => {
    configureWorkerTracing(async () => {})
    const validTraceparent = '00-11111111111111111111111111111111-1111111111111111-01'
    expect(workerTurnTrace(turnStart('agent-valid', 'session-valid', validTraceparent))).toBeDefined()

    const invalid = turnStart('agent-1', 'session-1', 'invalid')
    expect(traceparentFromTurnStart(invalid)).toBeUndefined()
    expect(workerTurnTrace(invalid)).toBeUndefined()

    const missing = turnStart('agent-1', 'session-1')
    expect(traceparentFromTurnStart(missing)).toBeUndefined()
    expect(workerTurnTrace(missing)).toBeUndefined()

    const zeroTraceID = turnStart('agent-1', 'session-1', '00-00000000000000000000000000000000-1111111111111111-01')
    expect(traceparentFromTurnStart(zeroTraceID)).toBeUndefined()

    const zeroSpanID = turnStart('agent-1', 'session-1', '00-11111111111111111111111111111111-0000000000000000-01')
    expect(traceparentFromTurnStart(zeroSpanID)).toBeUndefined()

    const forbiddenVersion = turnStart(
      'agent-1',
      'session-1',
      'ff-11111111111111111111111111111111-1111111111111111-01'
    )
    expect(traceparentFromTurnStart(forbiddenVersion)).toBeUndefined()

    for (const invalidUserID of [
      '',
      'principal:',
      'channel:',
      'agent-1',
      ' principal:human-1',
      'principal:human-1 ',
      'principal:human-1\r\nchannel:forged',
      'none'
    ]) {
      expect(
        turnTracePropagationFromTurnStart(turnStart('agent-1', 'session-1', validTraceparent, invalidUserID))
      ).toEqual({
        traceparent: validTraceparent,
        observabilityUserID: null
      })
    }

    expect(turnTracePropagationFromTurnStart(turnStart('agent-1', 'session-1', validTraceparent))).toEqual({
      traceparent: validTraceparent,
      observabilityUserID: null
    })

    const nonStringUserID = turnStart('agent-1', 'session-1', validTraceparent) as any
    nonStringUserID.request_context.observability_user_id = 42
    expect(turnTracePropagationFromTurnStart(nonStringUserID)).toEqual({
      traceparent: validTraceparent,
      observabilityUserID: null
    })

    const explicitNullUserID = turnStart('agent-1', 'session-1', validTraceparent) as any
    explicitNullUserID.request_context.observability_user_id = null
    expect(turnTracePropagationFromTurnStart(explicitNullUserID)).toEqual({
      traceparent: validTraceparent,
      observabilityUserID: null
    })

    expect(
      turnTracePropagationFromTurnStart(turnStart('agent-1', 'session-1', validTraceparent, 'principal:human-1'))
    ).toEqual({ traceparent: validTraceparent, observabilityUserID: 'principal:human-1' })

    const exactCharacterLimit = `channel:${'界'.repeat(192)}`
    expect([...exactCharacterLimit]).toHaveLength(200)
    expect(new TextEncoder().encode(exactCharacterLimit).byteLength).toBeGreaterThan(200)
    expect(
      turnTracePropagationFromTurnStart(turnStart('agent-1', 'session-1', validTraceparent, exactCharacterLimit))
    ).toEqual({ traceparent: validTraceparent, observabilityUserID: exactCharacterLimit })

    const overCharacterLimit = `${exactCharacterLimit}a`
    expect([...overCharacterLimit]).toHaveLength(201)
    expect(
      turnTracePropagationFromTurnStart(turnStart('agent-1', 'session-1', validTraceparent, overCharacterLimit))
    ).toEqual({ traceparent: validTraceparent, observabilityUserID: null })
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

function turnStart(agentUID: string, sessionID: string, traceparent?: string, observabilityUserID?: string): TurnStart {
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
    request_context: {
      ...(traceparent ? { traceparent } : {}),
      ...(observabilityUserID === undefined ? {} : { observability_user_id: observabilityUserID })
    }
  }
}
