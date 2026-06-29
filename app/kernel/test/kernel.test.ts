import { describe, expect, it } from 'bun:test'
import { Buffer } from 'node:buffer'
import * as kernel from '../index.js'

const aeadKey = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
const aeadCiphertext = 'vveE4WxRjp0KO8YVx7o09aQ5_q9ZzqX2.gb1S9PmqEp_5UuejAzvKErXrdE4-sQ'

describe('@ankole/kernel', () => {
  it('exports the public Bun API', () => {
    for (const name of [
      'aeadDecrypt',
      'aeadEncrypt',
      'runtimeFabricDecodeEnvelope',
      'runtimeFabricEncodeEnvelope',
      'RuntimeFabricDealer',
      'authzAuthorize',
      'authzAuthorizeAll',
      'authzMatchResourcePattern',
      'authzValidateCondition',
      'authzValidateResourcePattern',
      'signalsGatewayFilterMatch',
      'signalsGatewayValidateFilter',
      'anyAscii',
      'base58Decode',
      'base58Encode',
      'base64UrlSafeDecode',
      'base64UrlSafeEncode',
      'bs58Hash',
      'crc32',
      'crc32Hex',
      'deriveKey',
      'genBase36UUID',
      'generateKey',
      'genericHash',
      'jwtDecodeHeader',
      'jwtSign',
      'jwtVerify',
      'phoneNormalizeE164',
      'genShortUUID',
      'genUUID',
      'genUUIDv7',
      'xxh3_128_hex',
      'xxh3File128Hex',
    ]) {
      expect(kernel[name as keyof typeof kernel]).toBeFunction()
    }
  })

  it('generates TypeScript declarations during build', async () => {
    expect(await Bun.file(new URL('../index.d.ts', import.meta.url)).exists()).toBe(true)
  })

  it('declares RuntimeFabric raw file-transfer methods', () => {
    expect(kernel.RuntimeFabricDealer.prototype.sendFileFrame).toBeFunction()
    expect(kernel.RuntimeFabricDealer.prototype.recvRaw).toBeFunction()
    expect(kernel.RuntimeFabricDealer.prototype.recvRawAsync).toBeFunction()
  })

  it('hashes and derives keys with shared BLAKE3 vectors', () => {
    expect(kernel.genericHash('bullx')).toBe('7f31cabae40697f9404428671c582d3c1f80c8a13d0741f4be8c9b856fcc0706')
    expect(kernel.bs58Hash(Buffer.from('bullx'))).toBe('9ZWpCkNYVXH91wFYb4cygXBxLe2xwsK9rBTVxwPMicWZ')
    expect(kernel.deriveKey('seed', 'tenant-A', 'scope-a')).toBe(
      '0553f445a2fb3dfc0fab4efa1e1ed31ef6a103277286cf63874904e341ee0d20',
    )
  })

  it('encrypts and decrypts AEAD payloads', () => {
    const encrypted = kernel.aeadEncrypt(Buffer.from('secret'), aeadKey)

    expect(encrypted.split('.')).toHaveLength(2)
    expect(encrypted).not.toContain('=')
    expect(Buffer.from(kernel.aeadDecrypt(encrypted, aeadKey)).toString('utf8')).toBe('secret')
    expect(Buffer.from(kernel.aeadDecrypt(aeadCiphertext, aeadKey)).toString('utf8')).toBe('secret')
  })

  it('signs, verifies, and decodes JWT headers', () => {
    const token = kernel.jwtSign(
      {
        iss: 'ankole.control_plane',
        aud: 'ankole.web_console',
        sub: 'human-1',
        exp: 4102444800,
        token_use: 'access',
      },
      'jwt-secret',
      { algorithm: 'HS256', key_id: 'test-key' },
    )

    expect(
      kernel.jwtVerify(token, 'jwt-secret', {
        algorithms: ['HS256'],
        iss: ['ankole.control_plane'],
        aud: ['ankole.web_console'],
        sub: 'human-1',
      }),
    ).toMatchObject({ sub: 'human-1', token_use: 'access' })
    expect(kernel.jwtDecodeHeader(token)).toMatchObject({ algorithm: 'HS256', key_id: 'test-key' })
  })

  it('evaluates SignalsGateway CEL filters through the Bun bridge', () => {
    const context = {
      binding: { name: 'bot', adapter: 'lark' },
      signal: {
        kind: 'entry_received',
        channel: { id: 'lark:chat:group-a', kind: 'im_group', reply_mode: 'entry' },
        entry: {
          id: 'msg-1',
          sender_key: 'lark:user:alice',
          text: 'hello from lark',
          metadata: { repository: 'ankole' },
        },
      },
    }

    expect(kernel.signalsGatewayValidateFilter("signal.channel.id == 'lark:chat:group-a'")).toBe(true)
    expect(
      kernel.signalsGatewayFilterMatch(
        "binding.name == 'bot' && signal.entry.sender_key.startsWith('lark:user:')",
        context,
      ),
    ).toBe(true)
    expect(kernel.signalsGatewayFilterMatch("signal.channel.kind == 'im_dm'", context)).toBe(false)

    expect(() => kernel.signalsGatewayValidateFilter('signal.')).toThrow(/invalid signal filter/)
    expect(() => kernel.signalsGatewayFilterMatch('signal.entry.text', context)).toThrow(/signal filter returned string/)
    expect(() => kernel.signalsGatewayFilterMatch('signal.entry.missing', context)).toThrow(
      /signal filter execution failed/,
    )
    expect(() => kernel.signalsGatewayFilterMatch('true', {})).toThrow(/signal filter context must include binding/)
  })

  it('encodes and decodes RuntimeFabric protobuf envelopes', () => {
    const envelope = {
      protocol_version: 1,
      message_id: 'turn-start-1',
      correlation_id: 'corr-1',
      lane: 'LANE_TURN',
      sent_at_unix_ms: 1782300000000,
      durability: 'CONTROL_REPLAYABLE',
      body: {
        type: 'turn_start',
        turn_start: {
          turn: actorTurnRef(),
          inputs: [
            {
              actor_input_id: 'input-1',
              live_queue_sequence: 1,
              type: 'im.message.addressed',
              ingress_event_id: 'event-1',
              provider_entry_id: 'message-1',
              payload_json: { text: 'PING' },
            },
          ],
        },
      },
    }

    const encoded = kernel.runtimeFabricEncodeEnvelope(envelope)
    expect(Buffer.isBuffer(encoded)).toBe(true)

    const decoded = kernel.runtimeFabricDecodeEnvelope(encoded)
    expect(decoded.body.type).toBe('turn_start')
    expect(decoded.body.turn_start.turn.actor).toEqual({
      agent_uid: 'agent-1',
      session_id: 'signal-channel:lark:dm:1',
    })
    expect(decoded.body.turn_start.inputs[0].payload_json.text).toBe('PING')
  })

  it('encodes and decodes RuntimeFabric mailbox updates with turn inputs', () => {
    const envelope = {
      protocol_version: 1,
      message_id: 'mailbox-updated-1',
      correlation_id: 'mailbox-updated-1',
      lane: 'LANE_TURN',
      durability: 'CONTROL_EPHEMERAL',
      body: {
        type: 'mailbox_updated',
        mailbox_updated: {
          turn: actorTurnRef(),
          reason: 'command.steer',
          inputs: [
            {
              actor_input_id: 'steer-1',
              live_queue_sequence: 2,
              type: 'command.steer',
              ingress_event_id: 'event-steer-1',
              payload_json: { data: { command: { argsText: 'change course' } } },
            },
          ],
        },
      },
    }

    const decoded = kernel.runtimeFabricDecodeEnvelope(kernel.runtimeFabricEncodeEnvelope(envelope))

    expect(decoded.body.type).toBe('mailbox_updated')
    expect(decoded.body.mailbox_updated.turn.llm_turn_id).toBe('11111111-1111-1111-1111-111111111111')
    expect(decoded.body.mailbox_updated.inputs[0].payload_json.data.command.argsText).toBe('change course')
  })

  it('encodes and decodes RuntimeFabric final proposal reply attachments', () => {
    const decoded = kernel.runtimeFabricDecodeEnvelope(
      kernel.runtimeFabricEncodeEnvelope({
        protocol_version: 1,
        message_id: 'turn-final-1',
        correlation_id: 'turn-start-1',
        lane: 'LANE_TURN',
        durability: 'CONTROL_DURABLE',
        body: {
          type: 'turn_final_proposal',
          turn_final_proposal: {
            turn: actorTurnRef(),
            messages: [],
            reply: {
              text: 'Here is the report.',
              content_json: [{ type: 'text', text: 'Here is the report.' }],
              attachments: [
                {
                  agent_computer_path: '/workspace/user-files/reports/a.txt',
                  user_files_relative_path: 'reports/a.txt',
                  name: 'report.txt',
                  mime_type: 'text/plain',
                  size: 16,
                },
              ],
            },
          },
        },
      }),
    )

    expect(decoded.body.turn_final_proposal.reply.attachments[0]).toMatchObject({
      agent_computer_path: '/workspace/user-files/reports/a.txt',
      user_files_relative_path: 'reports/a.txt',
      name: 'report.txt',
      mime_type: 'text/plain',
      size: 16,
    })
  })

  it('encodes and decodes RuntimeFabric silent final proposals without a reply', () => {
    const decoded = kernel.runtimeFabricDecodeEnvelope(
      kernel.runtimeFabricEncodeEnvelope({
        protocol_version: 1,
        message_id: 'turn-final-silent-1',
        correlation_id: 'turn-start-1',
        lane: 'LANE_TURN',
        durability: 'CONTROL_DURABLE',
        body: {
          type: 'turn_final_proposal',
          turn_final_proposal: {
            turn: actorTurnRef(),
            messages: [],
          },
        },
      }),
    )

    expect(decoded.body.type).toBe('turn_final_proposal')
    expect(decoded.body.turn_final_proposal.reply).toBeNull()
  })

  it('rejects profile fields on ActorKey', () => {
    expect(() =>
      kernel.runtimeFabricEncodeEnvelope({
        protocol_version: 1,
        message_id: 'turn-start-profile',
        correlation_id: 'turn-start-profile',
        lane: 'LANE_TURN',
        durability: 'CONTROL_REPLAYABLE',
        body: {
          type: 'turn_start',
          turn_start: {
            turn: {
              ...actorTurnRef(),
              actor: {
                ...actorTurnRef().actor,
                display_name: 'ReleaseBot',
              },
            },
            inputs: [],
          },
        },
      }),
    ).toThrow(/ActorKey must not carry display_name/)
  })

  it('encodes and decodes RuntimeFabric RPC envelopes', () => {
    const encoded = kernel.runtimeFabricEncodeEnvelope({
      protocol_version: 1,
      message_id: 'rpc-conversation-context-1',
      correlation_id: 'rpc-conversation-context-1',
      lane: 'LANE_RPC',
      durability: 'CONTROL_EPHEMERAL',
      body: {
        type: 'rpc_request',
        rpc_request: {
          request_id: 'rpc-conversation-context-1',
          method: 'agent_conversation.context.resolve',
          payload_json: {
            turn: {
              actor: {
                agent_uid: 'agent-1',
                session_id: 'signal-channel:lark:dm:1',
              },
            },
          },
        },
      },
    })

    expect(kernel.runtimeFabricDecodeEnvelope(encoded).body.rpc_request.method).toBe(
      'agent_conversation.context.resolve',
    )
  })

  it('rejects inline steer payloads in actor lane turn_control', () => {
    expect(() =>
      kernel.runtimeFabricEncodeEnvelope({
        protocol_version: 1,
        message_id: 'steer-1',
        correlation_id: 'steer-1',
        lane: 'LANE_CONTROL',
        durability: 'CONTROL_DURABLE',
        body: {
          type: 'turn_control',
          turn_control: {
            turn: actorTurnRef(),
            command: 'steer',
            payload_json: { text: 'inline steer is not allowed' },
          },
        },
      }),
    ).toThrow(/steer payload must be empty/)
  })

  it('rejects actor lane bodies on the wrong lane or durability', () => {
    expect(() =>
      kernel.runtimeFabricEncodeEnvelope({
        protocol_version: 1,
        message_id: 'turn-start-wrong-lane',
        lane: 'LANE_CONTROL',
        durability: 'CONTROL_EPHEMERAL',
        body: {
          type: 'turn_start',
          turn_start: {
            turn: actorTurnRef(),
            inputs: [
              {
                actor_input_id: 'input-1',
                live_queue_sequence: 1,
                type: 'im.message.addressed',
                ingress_event_id: 'event-1',
              },
            ],
          },
        },
      }),
    ).toThrow(/turn_start must use lane LANE_TURN/)
  })

  it('encodes and decodes base58 and base64url payloads', () => {
    expect(kernel.base58Encode('Hello World!')).toBe('2NEpo7TZRRrLZSi2U')
    expect(Buffer.from(kernel.base58Decode('2NEpo7TZRRrLZSi2U')).toString('utf8')).toBe('Hello World!')

    expect(kernel.base64UrlSafeEncode(Buffer.from('bullx'))).toBe('YnVsbHg')
    expect(Buffer.from(kernel.base64UrlSafeDecode('YnVsbHg')).toString('utf8')).toBe('bullx')
  })

  it('authorizes direct grants with the shared AuthZ engine', () => {
    expect(kernel.authzValidateCondition('principal.type == "human"')).toBe(true)
    expect(kernel.authzValidateResourcePattern('workspace:**')).toBe(true)
    expect(kernel.authzMatchResourcePattern('workspace:**', 'workspace:default')).toBe(true)

    const decision = kernel.authzAuthorize({
      principal: {
        uid: 'alice',
        type: 'human',
        status: 'active',
      },
      staticGroupIds: [],
      computedGroups: [],
      grants: [
        {
          id: 'grant-1',
          principalUid: 'alice',
          resourcePattern: 'workspace:**',
          action: 'read',
          condition: 'context.request.source == "test"',
        },
      ],
      resource: 'workspace:default',
      action: 'read',
      context: { source: 'test' },
    })

    expect(decision).toMatchObject({
      status: 'allow',
      diagnostics: [],
      effectiveGroupIds: [],
    })
  })

  it('supports text normalization and crc32 helpers', () => {
    expect(kernel.anyAscii('Björk')).toBe('Bjork')
    expect(kernel.crc32('TestCase😊')).toBe(1198634863)
    expect(kernel.crc32Hex(Buffer.from('TestCase😊'))).toBe('4771b76f')
    expect(kernel.xxh3_128_hex('TestCase')).toBe('7b16fe7c3e492b87d9615265f0856cec')
    expect(kernel.phoneNormalizeE164('+1 415 555 2671')).toBe('+14155552671')
    expect(() => kernel.phoneNormalizeE164('13800000000')).toThrow()
  })

  it('generates uuid variants in the expected formats', () => {
    expect(kernel.generateKey()).toMatch(/^[0-9a-f]{64}$/)
    expect(kernel.genUUID()).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    expect(kernel.genUUIDv7()).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    expect(kernel.genBase36UUID()).toMatch(/^[0-9a-z]+$/)
    expect(kernel.genShortUUID()).toMatch(/^[1-9A-HJ-NP-Za-km-z]+$/)
  })
})

function actorTurnRef() {
  return {
    actor: {
      agent_uid: 'agent-1',
      session_id: 'signal-channel:lark:dm:1',
    },
    activation_uid: 'activation-1',
    actor_epoch: 1,
    llm_turn_id: '11111111-1111-1111-1111-111111111111',
    revision: 0,
  }
}
