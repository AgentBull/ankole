import { describe, expect, it } from 'bun:test'
import type { TurnStart } from '../src/lanes/actor_lane'
import {
  configureWorkerTracing,
  finishWorkerSpan,
  forceFlushWorkerTracing,
  startWorkerSpan,
  traceparentFromTurnStart,
  turnTracePropagationFromTurnStart,
  workerObservationInputAttributes,
  workerObservationOutputAttributes,
  workerTurnTrace
} from '../src/observability/turn-tracing'

describe('worker turn tracing', () => {
  it('redacts credentials and excludes private protocol fields without mutating model content', () => {
    const secret = 'sk-private-key-1234567890'
    const value = {
      query: 'visible query',
      accessToken: secret,
      secretKey: 'PRIVATE_SECRET_KEY',
      commandOutput: JSON.stringify({ password: 'PRIVATE_"JSON_PASSWORD', count: 3 }),
      headers: { custom: 'PRIVATE_HEADER' },
      metadata: { note: 'PRIVATE_METADATA' },
      messages: [{ text: `Bearer ${secret}`, encrypted_content: 'PRIVATE_REASONING' }],
      encrypted_function_args: 'PRIVATE_ARGUMENTS',
      __ankole_private: 'PRIVATE_CONTROL',
      media: 'data:image/png;base64,PRIVATE_IMAGE'
    }
    const original = JSON.stringify(value)
    for (const type of ['agent', 'tool'] as const) {
      const attributes = {
        ...workerObservationInputAttributes(type, value),
        ...workerObservationOutputAttributes(type, value)
      }
      const encoded = JSON.stringify(attributes)
      for (const excluded of [
        secret,
        'PRIVATE_SECRET_KEY',
        'JSON_PASSWORD',
        'PRIVATE_HEADER',
        'PRIVATE_METADATA',
        'PRIVATE_REASONING',
        'PRIVATE_ARGUMENTS',
        'PRIVATE_CONTROL',
        'PRIVATE_IMAGE'
      ]) {
        expect(encoded).not.toContain(excluded)
      }
      const contentKey = type === 'agent' ? 'ankole.agent.input' : 'gen_ai.tool.call.arguments'
      expect(JSON.parse(String(attributes[contentKey]))).toEqual({
        query: 'visible query',
        commandOutput: '{"password":"[REDACTED]","count":3}',
        messages: [{ text: 'Bearer [REDACTED]' }],
        media: '[inline media omitted]'
      })
    }
    expect(JSON.stringify(value)).toBe(original)
  })

  it('omits content that cannot be encoded instead of exporting a fallback string', () => {
    const cyclic: { self?: unknown } = {}
    cyclic.self = cyclic
    for (const value of [cyclic, { value: 1n }]) {
      const attributes = workerObservationOutputAttributes('tool', value)
      expect(attributes['gen_ai.tool.call.result']).toBe('{"omitted":"encoding_failed"}')
      expect(attributes['ankole.observability.output_truncated']).toBe(true)
    }
  })

  it('marks oversized observation content instead of exporting the payload', () => {
    const attributes = workerObservationInputAttributes('tool', 'x'.repeat(1_024 * 1_024))

    expect(attributes['gen_ai.operation.name']).toBe('execute_tool')
    expect(attributes['ankole.observability.input_truncated']).toBe(true)
    expect(attributes['gen_ai.tool.call.arguments']).toContain('"omitted":"content_too_large"')
    expect(attributes['gen_ai.tool.call.arguments']).not.toContain('xxxxxxxx')
  })

  it('creates explicit remote children and exports provider-neutral agent and tool facts', async () => {
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
      turnStart('agent-3', 'session-3', '00-44444444444444444444444444444444-4444444444444444-01', undefined)
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
      ...workerObservationInputAttributes('agent', 'inspect the PDF skill'),
      'ankole.principal.uid': 'spoofed-agent',
      'user.id': 'principal:spoofed-user',
      'gen_ai.agent.name': 'codex'
    })
    const tool = startWorkerSpan(
      firstTrace,
      'execute_tool skill_view',
      {
        ...workerObservationInputAttributes('tool', { name: 'pdf' }),
        'gen_ai.tool.name': 'skill_view',
        'gen_ai.tool.call.id': 'call-1'
      },
      codexTurn ? { parent: codexTurn } : {}
    )
    finishWorkerSpan(tool, {
      attributes: {
        ...workerObservationOutputAttributes('tool', 'loaded PDF skill'),
        'ankole.codex.duration_ms': 12
      }
    })
    finishWorkerSpan(codexTurn, {
      attributes: {
        ...workerObservationOutputAttributes('agent', 'skill loaded'),
        'ankole.principal.uid': 'finish-spoofed-agent',
        'ankole.principal.type': 'human',
        'user.id': 'principal:finish-spoofed-user',
        'session.id': 'finish-spoofed-session'
      }
    })
    finishWorkerSpan(
      startWorkerSpan(secondTrace, 'execute_tool web_search', {
        ...workerObservationInputAttributes('tool', { query: 'observability' }),
        'gen_ai.tool.name': 'web_search'
      }),
      { attributes: workerObservationOutputAttributes('tool', ['result']) }
    )
    finishWorkerSpan(
      startWorkerSpan(unattributedTrace, 'execute_tool internal', {
        ...workerObservationInputAttributes('tool', {}),
        'gen_ai.tool.name': 'internal'
      })
    )

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
      expect(wireText).not.toContain('ankole.worker.input')
      expect(wireText).not.toContain('ankole.worker.output')
      expect(wireText).not.toContain('langfuse.')
      expect(wireText).not.toContain('langsmith.')

      if (entry.agentUID === 'agent-1') {
        expect(wireText).toContain('ankole.agent.input')
        expect(wireText).toContain('ankole.agent.output')
        expect(wireText).toContain('gen_ai.tool.call.arguments')
        expect(wireText).toContain('gen_ai.tool.call.result')
        expect(wireText).toContain('skill_view')
        expect(wireText).toContain('"name":"pdf"')
        expect(wireText).toContain('loaded PDF skill')
      } else if (entry.agentUID === 'agent-2') {
        expect(wireText).toContain('gen_ai.operation.name')
        expect(wireText).toContain('gen_ai.tool.call.arguments')
        expect(wireText).toContain('gen_ai.tool.call.result')
      } else {
        expect(wireText).toContain('gen_ai.tool.call.arguments')
      }
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
