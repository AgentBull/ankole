import { HostedTool } from '../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { fromBinary } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { readFileSync } from 'node:fs'
import { decodeEnvelope, ProtocolVersion } from '../src/fabric/envelope_proto'
import {
  SkillOverlayResolveRequestSchema,
  SkillOverlayResolveResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { turnStartFromEnvelope } from '../src/lanes/actor_lane'

/**
 * Pins the cross-language golden bytes.
 *
 * Protox and protobuf-es generate the fixtures through their actual sender
 * codecs. Both hosts decode the shared wire bytes. The proto generation
 * check owns generated-code staleness.
 */
describe('RuntimeFabric generated codec contract', () => {
  it('decodes the golden turn_start bytes into the worker DTO', () => {
    const envelope = decodeEnvelope(goldenBytes('turn_start.v9.bin'))
    const turnStart = turnStartFromEnvelope(envelope)

    expect(envelope.protocolVersion).toBe(ProtocolVersion.CURRENT)
    expect(turnStart.mode).toBe('start')
    expect(turnStart.fetch_runtime_config).toEqual({ ssrfFilter: true, renderedFetchIdleTtlMs: 60000 })
    expect(turnStart.turn).toEqual({
      actor: { session_id: 'job:1000' },
      job_id: 1000,
      attempt: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000001'
    })
    expect(turnStart.actor_event.type).toBe('cron.fire')
    expect(turnStart.actor_event.payload_json).toEqual({
      data: { wake_payload: { cron_schedule_name: 'golden', payload: {} } }
    })
    expect(turnStart.request_context).toEqual({
      schedule_origin: { cron_schedule_name: 'golden', payload: {} },
      silent_success_allowed: true
    })
    expect(turnStart.hosted_tools).toEqual([HostedTool.IMAGE_GENERATION])
    expect(turnStart.agent_context).toMatchObject({
      conversation: { timezone: 'Asia/Shanghai' },
      soul: 'Agent instructions',
      mission: 'Mission instructions',
      design: 'Design instructions',
      confidentialityPolicy: 'Keep operator facts private',
      skillsPrompt: '    - design-md: Design documents',
      skills: [
        {
          skillName: 'design-md',
          description: 'Design documents',
          sourceKind: 'builtin',
          skillRoot: 'library',
          relativePath: 'skills/design-md'
        }
      ],
      agentPlugins: [{ id: 'research', skills: [{ catalogName: 'deep-research' }] }]
    })
    expect(JSON.parse(new TextDecoder().decode(turnStart.agent_context!.skills[0]!.metadataJson))).toEqual({
      'ankole-runtime': 'any'
    })
  })

  it('decodes conversation and Job adoption identities from the shared golden bytes', () => {
    for (const [name, body] of [
      ['workspace_open', 'workspaceOpen'],
      ['workspace_ready', 'workspaceReady'],
      ['tool_call', 'toolCall'],
      ['tool_status', 'toolStatus'],
      ['tool_result', 'toolResult']
    ] as const) {
      const envelope = decodeEnvelope(goldenBytes(`${name}.v9.bin`))
      expect(envelope.protocolVersion).toBe(ProtocolVersion.CURRENT)
      if (envelope.body.case !== body) throw new Error(`expected ${body}`)
      expect(envelope.body.value.run).toEqual({
        $typeName: 'ankole.runtime_fabric.v1.RunRef',
        actor: { $typeName: 'ankole.runtime_fabric.v1.ActorKey', sessionId: 'job:1000' },
        actorEventId: 'input-1'
      })
    }
    const open = decodeEnvelope(goldenBytes('workspace_open.v9.bin'))
    if (open.body.case !== 'workspaceOpen') throw new Error('expected workspaceOpen')
    expect(open.body.value.agentContext?.soul).toBe('Agent instructions')
    expect(open.body.value.agentContext?.skills).toMatchObject([
      { skillName: 'design-md', skillRoot: 'library', relativePath: 'skills/design-md' }
    ])
    const ready = decodeEnvelope(goldenBytes('workspace_ready.v9.bin'))
    if (ready.body.case !== 'workspaceReady') throw new Error('expected workspaceReady')
    expect(ready.body.value.reason).toBe(1)
    const call = decodeEnvelope(goldenBytes('tool_call.v9.bin'))
    if (call.body.case !== 'toolCall') throw new Error('expected toolCall')
    expect(call.body.value).toMatchObject({ responseId: 'response-1', callId: 'call-1', mode: 'probe' })
    const status = decodeEnvelope(goldenBytes('tool_status.v9.bin'))
    if (status.body.case !== 'toolStatus') throw new Error('expected toolStatus')
    expect(status.body.value.state).toBe('unknown')
    const result = decodeEnvelope(goldenBytes('tool_result.v9.bin'))
    if (result.body.case !== 'toolResult') throw new Error('expected toolResult')
    expect(result.body.value.images).toHaveLength(1)
    expect(result.body.value.images[0]).toEqual(
      new Uint8Array(
        Buffer.from(
          'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAYAAACzzX7wAAAAEklEQVR4nGOQCFjQgA8z0F4BAIq4MQHaWyp/AAAAAElFTkSuQmCC',
          'base64'
        )
      )
    )
    expect(JSON.parse(new TextDecoder().decode(result.body.value.contentJson))).toEqual([
      { type: 'text', text: 'done' }
    ])
    expect(turnStartFromEnvelope(decodeEnvelope(goldenBytes('turn_adopt.v9.bin'))).mode).toBe('adopt')
  })

  it('decodes the golden Skill overlay typed RPC request and response', () => {
    const requestEnvelope = decodeEnvelope(goldenBytes('rpc_skill_overlay_resolve_request.v9.bin'))

    expect(requestEnvelope.protocolVersion).toBe(ProtocolVersion.CURRENT)
    if (requestEnvelope.body.case !== 'rpcRequest') throw new Error('expected rpcRequest body')
    expect(requestEnvelope.body.value).toMatchObject({
      requestId: 'golden-rpc-skill-overlay-resolve-1',
      method: 'skills.overlay.resolve'
    })
    const request = fromBinary(SkillOverlayResolveRequestSchema, requestEnvelope.body.value.payload)
    expect(request.skillNames).toEqual(['pdf', 'xlsx'])

    const responseEnvelope = decodeEnvelope(goldenBytes('rpc_skill_overlay_resolve_response.v9.bin'))

    expect(responseEnvelope.protocolVersion).toBe(ProtocolVersion.CURRENT)
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
