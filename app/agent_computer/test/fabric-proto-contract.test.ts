import { fromBinary } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { readFileSync } from 'node:fs'
import { decodeEnvelope, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import {
  BrainRequestSchema,
  JSONPassthroughResponseSchema,
  SkillOverlayResolveRequestSchema,
  SkillOverlayResolveResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
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
    const envelope = decodeEnvelope(goldenBytes('turn_start.v5.bin'))
    const turnStart = turnStartFromEnvelope(envelope)

    expect(envelope.protocolVersion).toBe(5)
    expect(turnStart.workspace_id).toBe(10_000)
    expect(turnStart.turn).toEqual({
      actor: { agent_uid: 'agent-1', session_id: 'signal-channel:lark:dm:1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '11111111-1111-1111-1111-111111111111',
      revision: 0
    })
    expect(turnStart.actor_event.type).toBe('cron.fire')
    expect(turnStart.actor_event.payload_json).toEqual({
      data: { wake_payload: { cron_schedule_name: 'golden', payload: {} } }
    })
    expect(turnStart.model_ref?.max_completion_tokens).toBe(32_000)
    expect(turnStart.request_context).toEqual({
      schedule_origin: { cron_schedule_name: 'golden', payload: {} },
      silent_success_allowed: true
    })
    expect(turnStart.hosted_tools).toEqual([{ type: 'image_generation' }])
  })

  it('decodes the golden worker_ready lifecycle bytes', () => {
    const envelope = decodeEnvelope(goldenBytes('worker_ready.v5.bin'))

    expect(envelope.protocolVersion).toBe(5)
    if (envelope.body.case !== 'workerReady') throw new Error('expected workerReady body')
    expect(envelope.body.value.workerId).toBe('worker-golden')
    expect(envelope.body.value.incarnationId).toBe('incarnation-golden')
    expect(envelope.body.value.maxTurns).toBe(1)
    expect(envelope.body.value.availableTurnSlots).toBe(1)
  })

  it('decodes the golden Brain recall RPC request and passthrough response', () => {
    const requestEnvelope = decodeEnvelope(goldenBytes('rpc_brain_recall_request.v5.bin'))

    expect(requestEnvelope.protocolVersion).toBe(5)
    expect(requestEnvelope.correlationId).toBe('golden-rpc-brain-recall-1')
    if (requestEnvelope.body.case !== 'rpcRequest') throw new Error('expected rpcRequest body')
    expect(requestEnvelope.body.value).toMatchObject({
      requestId: 'golden-rpc-brain-recall-1',
      method: 'brain.recall'
    })
    expect(requestEnvelope.body.value.turn?.actor?.agentUid).toBe('agent-1')
    const request = fromBinary(BrainRequestSchema, requestEnvelope.body.value.payload)
    expect(jsonObjectFromBytes(request.paramsJson, 'brain_request.params_json')).toEqual({
      budget_tokens: 512,
      query: 'golden memory'
    })

    const responseEnvelope = decodeEnvelope(goldenBytes('rpc_brain_recall_response.v5.bin'))

    expect(responseEnvelope.protocolVersion).toBe(5)
    expect(responseEnvelope.correlationId).toBe('golden-rpc-brain-recall-1')
    if (responseEnvelope.body.case !== 'rpcResponse') throw new Error('expected rpcResponse body')
    expect(responseEnvelope.body.value.requestId).toBe('golden-rpc-brain-recall-1')
    const response = fromBinary(JSONPassthroughResponseSchema, responseEnvelope.body.value.payload)
    expect(jsonObjectFromBytes(response.bodyJson, 'json_passthrough_response.body_json')).toEqual({
      chunks: [{ object_slug: 'concepts/golden', text: 'Golden memory.' }]
    })
  })

  it('decodes the golden Skill overlay typed RPC request and response', () => {
    const requestEnvelope = decodeEnvelope(goldenBytes('rpc_skill_overlay_resolve_request.v5.bin'))

    expect(requestEnvelope.protocolVersion).toBe(5)
    expect(requestEnvelope.correlationId).toBe('golden-rpc-skill-overlay-resolve-1')
    if (requestEnvelope.body.case !== 'rpcRequest') throw new Error('expected rpcRequest body')
    expect(requestEnvelope.body.value).toMatchObject({
      requestId: 'golden-rpc-skill-overlay-resolve-1',
      method: 'skills.overlay.resolve'
    })
    const request = fromBinary(SkillOverlayResolveRequestSchema, requestEnvelope.body.value.payload)
    expect(request.skillNames).toEqual(['pdf', 'xlsx'])

    const responseEnvelope = decodeEnvelope(goldenBytes('rpc_skill_overlay_resolve_response.v5.bin'))

    expect(responseEnvelope.protocolVersion).toBe(5)
    expect(responseEnvelope.correlationId).toBe('golden-rpc-skill-overlay-resolve-1')
    if (responseEnvelope.body.case !== 'rpcResponse') throw new Error('expected rpcResponse body')
    expect(responseEnvelope.body.value.requestId).toBe('golden-rpc-skill-overlay-resolve-1')
    const response = fromBinary(SkillOverlayResolveResponseSchema, responseEnvelope.body.value.payload)
    expect(response.overlays).toMatchObject([
      {
        skillName: 'pdf',
        hasOverlay: true,
        text: 'Prefer page-by-page verification.',
        contentHash: 'overlay-hash-pdf'
      },
      {
        skillName: 'xlsx',
        hasOverlay: false,
        text: '',
        contentHash: 'overlay-hash-xlsx'
      }
    ])
  })
})

function goldenBytes(name: string): Uint8Array {
  return readFileSync(new URL(`../../kernel/proto/golden/${name}`, import.meta.url))
}
