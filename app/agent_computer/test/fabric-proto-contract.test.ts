import { HostedTool } from '../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { fromBinary } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { readFileSync } from 'node:fs'
import { decodeEnvelope, ProtocolVersion } from '../src/fabric/envelope_proto'
import {
  ReadToolRequestSchema,
  FilesGetRequestSchema,
  FilesGetResponseSchema,
  ConversationInfoSchema,
  JSONPassthroughResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { turnStartFromEnvelope } from '../src/lanes/session_lane'

/**
 * Pins the cross-language golden bytes.
 *
 * Protox and protobuf-es generate the fixtures through their actual sender
 * codecs. Both hosts decode the shared wire bytes. The proto generation
 * check owns generated-code staleness.
 */
describe('RuntimeFabric generated codec contract', () => {
  it('decodes Drive node/object references and ignores the retired Pod selector', () => {
    const envelope = decodeEnvelope(goldenBytes('rpc_files_get_request.v11.bin'))
    if (envelope.body.case !== 'rpcRequest') throw new Error('expected request')
    expect(envelope.protocolVersion).toBe(11)
    expect(envelope.body.value.method).toBe('files.get')
    const request = fromBinary(FilesGetRequestSchema, envelope.body.value.payload)
    expect(request.nodeId).toBe('019a0000-0000-7000-8000-000000000001')
    expect(request.homeRelativePath).toBe('downloads/report.txt')
    expect(request).not.toHaveProperty('podDrive')
    expect(fromBinary(FilesGetRequestSchema, new Uint8Array([24, 1])).nodeId).toBe('')
    expect(fromBinary(ConversationInfoSchema, new Uint8Array())).not.toHaveProperty('driveDirectory')
    const reply = decodeEnvelope(goldenBytes('rpc_files_get_response.v11.bin'))
    if (reply.body.case !== 'rpcResponse') throw new Error('expected response')
    const file = fromBinary(FilesGetResponseSchema, reply.body.value.payload).file!
    expect(file.nodeId).toBe(request.nodeId)
    expect(file.objectId).toBe('019a0000-0000-7000-8000-000000000002')
    expect(file.size).toBe(5_000_000_000n)
  })

  it('decodes the golden turn_start bytes into the worker DTO', () => {
    const envelope = decodeEnvelope(goldenBytes('turn_start.v11.bin'))
    const turnStart = turnStartFromEnvelope(envelope)

    expect(envelope.protocolVersion).toBe(ProtocolVersion.CURRENT)
    expect(turnStart.mode).toBe('start')
    expect(turnStart.fetch_runtime_config).toEqual({ ssrfFilter: true, renderedFetchIdleTtlMs: 60000 })
    expect(turnStart.turn).toEqual({
      session: { session_id: 'job:1000' },
      job_id: 1000,
      attempt: 1,
      signal_id: '00000000-0000-0000-0000-000000000001'
    })
    expect(turnStart.signal.type).toBe('cron.fire')
    expect(turnStart.signal.payload_json).toEqual({
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
      const envelope = decodeEnvelope(goldenBytes(`${name}.v11.bin`))
      expect(envelope.protocolVersion).toBe(ProtocolVersion.CURRENT)
      if (envelope.body.case !== body) throw new Error(`expected ${body}`)
      expect(envelope.body.value.run).toEqual({
        $typeName: 'ankole.runtime_fabric.v1.RunRef',
        session: { $typeName: 'ankole.runtime_fabric.v1.SessionKey', sessionId: 'job:1000' },
        signalId: 'input-1'
      })
    }
    const open = decodeEnvelope(goldenBytes('workspace_open.v11.bin'))
    if (open.body.case !== 'workspaceOpen') throw new Error('expected workspaceOpen')
    expect(open.body.value.agentContext?.soul).toBe('Agent instructions')
    expect(open.body.value.agentContext?.skills).toMatchObject([
      { skillName: 'design-md', skillRoot: 'library', relativePath: 'skills/design-md' }
    ])
    const ready = decodeEnvelope(goldenBytes('workspace_ready.v11.bin'))
    if (ready.body.case !== 'workspaceReady') throw new Error('expected workspaceReady')
    expect(ready.body.value.reason).toBe(1)
    const call = decodeEnvelope(goldenBytes('tool_call.v11.bin'))
    if (call.body.case !== 'toolCall') throw new Error('expected toolCall')
    expect(call.body.value).toMatchObject({ responseId: 'response-1', callId: 'call-1', mode: 'probe' })
    const status = decodeEnvelope(goldenBytes('tool_status.v11.bin'))
    if (status.body.case !== 'toolStatus') throw new Error('expected toolStatus')
    expect(status.body.value.state).toBe('unknown')
    const result = decodeEnvelope(goldenBytes('tool_result.v11.bin'))
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
    expect(turnStartFromEnvelope(decodeEnvelope(goldenBytes('turn_adopt.v11.bin'))).mode).toBe('adopt')
  })

  it('decodes the shared read-tool request and owner result golden bytes', () => {
    const requestEnvelope = decodeEnvelope(goldenBytes('rpc_read_tool_request.v11.bin'))
    if (requestEnvelope.body.case !== 'rpcRequest') throw new Error('expected request')
    expect(requestEnvelope.body.value.method).toBe('tools.read')
    const request = fromBinary(ReadToolRequestSchema, requestEnvelope.body.value.payload)
    expect(request.name).toBe('skill_view')
    expect(JSON.parse(new TextDecoder().decode(request.argumentsJson))).toEqual({ name: 'pdf' })
    const responseEnvelope = decodeEnvelope(goldenBytes('rpc_read_tool_response.v11.bin'))
    if (responseEnvelope.body.case !== 'rpcResponse') throw new Error('expected response')
    const response = fromBinary(JSONPassthroughResponseSchema, responseEnvelope.body.value.payload)
    expect(JSON.parse(new TextDecoder().decode(response.bodyJson))).toEqual({
      output: 'Prefer page-by-page verification.',
      details: { name: 'pdf' }
    })
  })
})

function goldenBytes(name: string): Uint8Array {
  return readFileSync(new URL(`../../kernel/proto/golden/${name}`, import.meta.url))
}
