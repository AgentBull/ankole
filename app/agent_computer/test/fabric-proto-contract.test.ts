import { describe, expect, it } from 'bun:test'
import { readFileSync } from 'node:fs'
import { decodeEnvelope } from '../src/fabric/envelope_proto'
import { turnStartFromEnvelope } from '../src/lanes/actor_lane'

/**
 * Pins the cross-language golden bytes.
 *
 * Rust (prost-build) and Elixir (protox) derive their codecs at compile time;
 * the kernel-owned golden fixtures prove the three runtimes decode the same
 * wire bytes. The proto generation check owns generated-code staleness.
 */
describe('RuntimeFabric generated codec contract', () => {
  it('decodes the golden turn_start bytes into the worker DTO', () => {
    const envelope = decodeEnvelope(goldenBytes('turn_start.v3.bin'))
    const turnStart = turnStartFromEnvelope(envelope)

    expect(envelope.protocolVersion).toBe(3)
    expect(turnStart.turn).toEqual({
      actor: { agent_uid: 'agent-1', session_id: 'signal-channel:lark:dm:1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '11111111-1111-1111-1111-111111111111',
      revision: 0
    })
    expect(turnStart.actor_event.payload_json).toEqual({ text: 'PING' })
    expect(turnStart.model_ref?.max_completion_tokens).toBe(32_000)
    expect(turnStart.request_context).toEqual({ kind: 'schedule', silent_success_allowed: true })
    expect(turnStart.hosted_tools).toEqual([{ type: 'image_generation' }])
  })

  it('keeps legacy v1 bytes structurally decodable for diagnostics', () => {
    const envelope = decodeEnvelope(goldenBytes('turn_start.pre_max_completion_tokens.v1.bin'))
    const turnStart = turnStartFromEnvelope(envelope)

    expect(envelope.protocolVersion).toBe(1)
    expect(turnStart.model_ref?.max_completion_tokens).toBeUndefined()
    expect(turnStart.model_ref?.model).toBe('openai/gpt-5.4-mini')
  })

  it('decodes the golden worker_ready lifecycle bytes', () => {
    const envelope = decodeEnvelope(goldenBytes('worker_ready.v3.bin'))

    expect(envelope.protocolVersion).toBe(3)
    if (envelope.body.case !== 'workerReady') throw new Error('expected workerReady body')
    expect(envelope.body.value.workerId).toBe('worker-golden')
    expect(envelope.body.value.incarnationId).toBe('incarnation-golden')
    expect(envelope.body.value.maxTurns).toBe(1)
    expect(envelope.body.value.availableTurnSlots).toBe(1)
  })
})

function goldenBytes(name: string): Uint8Array {
  return readFileSync(new URL(`../../kernel/proto/golden/${name}`, import.meta.url))
}
