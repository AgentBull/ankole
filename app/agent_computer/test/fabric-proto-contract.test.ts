import { describe, expect, it } from 'bun:test'
import { readFileSync } from 'node:fs'
import { committedFingerprint, generationFingerprint } from '../scripts/gen-proto'
import { decodeEnvelope } from '../src/fabric/envelope_proto'
import { turnStartFromEnvelope } from '../src/lanes/actor_lane'

/**
 * Pins the committed generated codec and the cross-language golden bytes.
 *
 * Rust (prost-build) and Elixir (protox) derive their codecs at compile time;
 * TypeScript checks generated output in, so the sidecar hash is the staleness
 * anchor and the kernel-owned golden fixtures prove the three runtimes decode
 * the same wire bytes.
 */
describe('RuntimeFabric generated codec contract', () => {
  it('keeps the committed generated codec in sync with envelope.proto', () => {
    expect(committedFingerprint()).toBe(generationFingerprint())
  })

  it('decodes the golden turn_start bytes into the worker DTO', () => {
    const turnStart = turnStartFromEnvelope(decodeEnvelope(goldenBytes('turn_start.v1.bin')))

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

  it('decodes pre-max_completion_tokens v1 bytes for rolling deploys', () => {
    const turnStart = turnStartFromEnvelope(decodeEnvelope(goldenBytes('turn_start.pre_max_completion_tokens.v1.bin')))

    expect(turnStart.model_ref?.max_completion_tokens).toBeUndefined()
    expect(turnStart.model_ref?.model).toBe('openai/gpt-5.4-mini')
  })

  it('decodes the golden worker_ready lifecycle bytes', () => {
    const envelope = decodeEnvelope(goldenBytes('worker_ready.v1.bin'))

    if (envelope.body.case !== 'workerReady') throw new Error('expected workerReady body')
    expect(envelope.body.value.workerId).toBe('worker-golden')
    expect(envelope.body.value.incarnationId).toBe('incarnation-golden')
  })
})

function goldenBytes(name: string): Uint8Array {
  return readFileSync(new URL(`../../kernel/proto/golden/${name}`, import.meta.url))
}
