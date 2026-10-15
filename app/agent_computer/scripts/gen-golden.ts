import { create, toBinary } from '@bufbuild/protobuf'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { EnvelopeSchema, ProtocolVersion } from '../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { ReadToolRequestSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

// Each sender generates its own fixtures with its production codec.
const dir = new URL('../../kernel/proto/golden/', import.meta.url)
mkdirSync(dir, { recursive: true })
const run = { session: { sessionId: 'job:1000' }, signalId: 'input-1' }
const envelope = (messageId: string, body: Parameters<typeof create<typeof EnvelopeSchema>>[1]['body']) =>
  create(EnvelopeSchema, { protocolVersion: ProtocolVersion.CURRENT, messageId, body })
const fixtures = [
  ['workspace_ready', envelope('workspace_ready.v10.bin', { case: 'workspaceReady', value: { run, reason: 1 } })],
  [
    'tool_status',
    envelope('tool_status.v10.bin', {
      case: 'toolStatus',
      value: { run, responseId: 'response-1', callId: 'call-1', state: 'unknown' }
    })
  ],
  [
    'tool_result',
    envelope('tool_result.v10.bin', {
      case: 'toolResult',
      value: {
        run,
        responseId: 'response-1',
        callId: 'call-1',
        contentJson: new TextEncoder().encode('[{"type":"text","text":"done"}]'),
        images: [readFileSync(new URL('../../control_plane/test/fixtures/sessions/rgba.png', import.meta.url))],
        detailsJson: new TextEncoder().encode('{}')
      }
    })
  ],
  [
    'rpc_read_tool_request',
    envelope('golden-rpc-read-tool-request-1', {
      case: 'rpcRequest',
      value: {
        requestId: 'golden-rpc-read-tool-1',
        method: 'tools.read',
        deadlineUnixMs: 1782300001000n,
        jobTurn: { jobId: 1000n, attempt: 1, signalId: '00000000-0000-0000-0000-000000000001' },
        payload: toBinary(
          ReadToolRequestSchema,
          create(ReadToolRequestSchema, {
            name: 'skill_view',
            argumentsJson: new TextEncoder().encode('{"name":"pdf"}')
          })
        )
      }
    })
  ]
] as const
for (const [name, value] of fixtures) {
  writeFileSync(new URL(`${name}.v${ProtocolVersion.CURRENT}.bin`, dir), toBinary(EnvelopeSchema, value))
}
