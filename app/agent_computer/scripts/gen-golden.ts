import { create, toBinary } from '@bufbuild/protobuf'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { EnvelopeSchema, ProtocolVersion } from '../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { SkillOverlayResolveRequestSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

// Each sender generates its own fixtures with its production codec.
const dir = new URL('../../kernel/proto/golden/', import.meta.url)
mkdirSync(dir, { recursive: true })
const run = { actor: { sessionId: 'job:1000' }, actorEventId: 'input-1' }
const envelope = (messageId: string, body: Parameters<typeof create<typeof EnvelopeSchema>>[1]['body']) =>
  create(EnvelopeSchema, { protocolVersion: ProtocolVersion.CURRENT, messageId, body })
const fixtures = [
  ['workspace_ready', envelope('workspace_ready.v9.bin', { case: 'workspaceReady', value: { run, reason: 1 } })],
  [
    'tool_status',
    envelope('tool_status.v9.bin', {
      case: 'toolStatus',
      value: { run, responseId: 'response-1', callId: 'call-1', state: 'unknown' }
    })
  ],
  [
    'tool_result',
    envelope('tool_result.v9.bin', {
      case: 'toolResult',
      value: {
        run,
        responseId: 'response-1',
        callId: 'call-1',
        contentJson: new TextEncoder().encode('[{"type":"text","text":"done"}]'),
        images: [readFileSync(new URL('../../control_plane/test/fixtures/conversations/rgba.png', import.meta.url))],
        detailsJson: new TextEncoder().encode('{}')
      }
    })
  ],
  [
    'rpc_skill_overlay_resolve_request',
    envelope('golden-rpc-skill-overlay-resolve-request-1', {
      case: 'rpcRequest',
      value: {
        requestId: 'golden-rpc-skill-overlay-resolve-1',
        method: 'skills.overlay.resolve',
        deadlineUnixMs: 1782300001000n,
        jobTurn: { jobId: 1000n, attempt: 1, actorEventId: '00000000-0000-0000-0000-000000000001' },
        payload: toBinary(
          SkillOverlayResolveRequestSchema,
          create(SkillOverlayResolveRequestSchema, { skillNames: ['pdf', 'xlsx'] })
        )
      }
    })
  ]
] as const
for (const [name, value] of fixtures) {
  writeFileSync(new URL(`${name}.v${ProtocolVersion.CURRENT}.bin`, dir), toBinary(EnvelopeSchema, value))
}
