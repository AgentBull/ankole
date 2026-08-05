import { describe, expect, it } from 'bun:test'
import { readFileSync } from 'node:fs'
import { runtimeFabricProtocolVersion } from '@ankole/kernel'
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
  it('keeps deployment version pins aligned with the Rust kernel owner', () => {
    // The kernel constant is the only code copy: it stamps every sealed
    // envelope, and both hosts read it through their kernel bindings. The
    // Dockerfile ARGs stay as deployment pins on the same source line.
    const kernelVersion = sourceVersion(
      new URL('../../kernel/src/runtime_fabric/mod.rs', import.meta.url),
      /^pub const PROTOCOL_VERSION: u32 = (\d+);$/m
    )

    expect(runtimeFabricProtocolVersion()).toBe(kernelVersion)

    for (const dockerfile of [
      new URL('../Dockerfile', import.meta.url),
      new URL('../../control_plane/Dockerfile', import.meta.url)
    ]) {
      expect(sourceVersion(dockerfile, /^ARG ANKOLE_RUNTIME_FABRIC_PROTOCOL_VERSION=(\d+)$/m)).toBe(kernelVersion)
    }
  })

  it('decodes the golden turn_start bytes into the worker DTO', () => {
    const envelope = decodeEnvelope(goldenBytes('turn_start.v4.bin'))
    const turnStart = turnStartFromEnvelope(envelope)

    expect(envelope.protocolVersion).toBe(4)
    expect(turnStart.workspace_id).toBe(10_000)
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

    expect(envelope.protocolVersion).toBe(1)
    if (envelope.body.case !== 'turnStart') throw new Error('expected turnStart body')
    expect(envelope.body.value.workspaceId).toBe(0n)
    expect(envelope.body.value.modelRef?.maxCompletionTokens).toBeUndefined()
    expect(envelope.body.value.modelRef?.model).toBe('openai/gpt-5.4-mini')
  })

  it('decodes the golden worker_ready lifecycle bytes', () => {
    const envelope = decodeEnvelope(goldenBytes('worker_ready.v4.bin'))

    expect(envelope.protocolVersion).toBe(4)
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

function sourceVersion(sourceURL: URL, pattern: RegExp): number {
  const source = readFileSync(sourceURL, 'utf8')
  const version = source.match(pattern)?.[1]
  if (!version) throw new Error(`RuntimeFabric protocol version is missing from ${sourceURL.pathname}`)
  return Number(version)
}
