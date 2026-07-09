import { describe, expect, it } from 'bun:test'
import { Buffer } from 'node:buffer'
import * as kernel from '../index.js'

describe('@ankole/kernel', () => {
  it('exports the public Bun API', () => {
    for (const name of [
      'runtimeFabricDecodeEnvelope',
      'runtimeFabricEncodeEnvelope',
      'RuntimeFabricDealer',
      'authzAuthorize',
      'authzAuthorizeAll',
      'authzMatchResourcePattern',
      'authzValidateCondition',
      'authzValidateResourcePattern',
      'estimateO200kBaseTokens',
      'signalsGatewayFilterMatch',
      'signalsGatewayValidateFilter',
      'unifiedTextDiff',
      'xxh3File128Hex',
      'xxh3String128Hex',
      'zstdCompressBlock',
      'zstdDecompressBlock'
    ]) {
      expect(kernel[name as keyof typeof kernel]).toBeFunction()
    }
  })

  it('generates the narrowed RuntimeFabric TypeScript declarations during build', async () => {
    const declarations = Bun.file(new URL('../index.d.ts', import.meta.url))
    expect(await declarations.exists()).toBe(true)

    const source = await declarations.text()
    expect(source).toContain('sendEnvelope(envelope: any): void')
    expect(source).toContain('sendFileFrame(frames: Buffer[]): void')
    expect(source).toContain('recvRawAsync(timeoutMs: number): Promise<Buffer[] | null>')
    expect(source).toContain('stop(): void')
    expect(source).not.toContain('recvRaw(timeoutMs')
  })

  it('computes string XXH3 fingerprints through the Bun bridge', () => {
    expect(kernel.xxh3String128Hex('TestCase')).toBe('7b16fe7c3e492b87d9615265f0856cec')
  })

  it('estimates model context with the shared o200k_base tokenizer', () => {
    expect(kernel.estimateO200kBaseTokens('Hello world')).toBe(2)
    expect(kernel.estimateO200kBaseTokens('记忆系统')).toBeGreaterThan(0)
  })

  it('computes unified text diff hunks through the Bun bridge', async () => {
    const diff = await kernel.unifiedTextDiff('one\ntwo\nthree\n', 'one\nTWO\nthree\n', 3)

    expect(diff).toContain('@@ -1,3 +1,3 @@')
    expect(diff).toContain('-two\n')
    expect(diff).toContain('+TWO\n')
  })

  it('compresses and bounds zstd worker-file blocks through the Bun bridge', async () => {
    const payload = Buffer.from('worker-file-block'.repeat(128))
    const compressed = await kernel.zstdCompressBlock(payload, 3)
    const decompressed = await kernel.zstdDecompressBlock(compressed, payload.length)

    expect(Buffer.from(decompressed).equals(payload)).toBe(true)
    await expect(kernel.zstdDecompressBlock(compressed, 8)).rejects.toThrow(/decompressed block exceeds max_out/)
  })

  it('keeps the RuntimeFabric dealer surface async and physical', () => {
    expect(kernel.RuntimeFabricDealer.prototype.sendFileFrame).toBeFunction()
    expect(kernel.RuntimeFabricDealer.prototype.recvRawAsync).toBeFunction()
    expect(kernel.RuntimeFabricDealer.prototype.recv).toBeUndefined()
    expect(kernel.RuntimeFabricDealer.prototype.recvRaw).toBeUndefined()
  })

  it('surfaces RuntimeFabric decode failures and void dealer stop through the native binding', () => {
    expect(() => kernel.runtimeFabricDecodeEnvelope(Buffer.from('not-protobuf'))).toThrow()

    const dealer = new kernel.RuntimeFabricDealer(
      'tcp://127.0.0.1:1',
      'worker-binding-test',
      'worker-binding-test',
      'test-secret'
    )

    expect(dealer.stop()).toBeUndefined()
  })

  it('surfaces real native dealer backpressure with a stable error code', () => {
    const dealer = new kernel.RuntimeFabricDealer(
      'tcp://127.0.0.1:1',
      'worker-binding-backpressure',
      'worker-binding-backpressure',
      'test-secret'
    )

    let sendError: unknown
    for (let attempt = 0; attempt < 2_048; attempt += 1) {
      try {
        dealer.sendEnvelope(workerReadyEnvelope(`worker-binding-backpressure-${attempt}`))
      } catch (error) {
        sendError = error
        break
      }
    }

    expect(sendError).toBeInstanceOf(Error)
    expect((sendError as Error).message).toBe('backpressure')
    expect(dealer.stop()).toBeUndefined()
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
          metadata: { repository: 'ankole' }
        }
      }
    }

    expect(kernel.signalsGatewayValidateFilter("signal.channel.id == 'lark:chat:group-a'")).toBe(true)
    expect(
      kernel.signalsGatewayFilterMatch(
        "binding.name == 'bot' && signal.entry.sender_key.startsWith('lark:user:')",
        context
      )
    ).toBe(true)
    expect(kernel.signalsGatewayFilterMatch("signal.channel.kind == 'im_dm'", context)).toBe(false)

    expect(() => kernel.signalsGatewayValidateFilter('signal.')).toThrow(/invalid signal filter/)
    expect(() => kernel.signalsGatewayFilterMatch('signal.entry.text', context)).toThrow(
      /signal filter returned string/
    )
    expect(() => kernel.signalsGatewayFilterMatch('signal.entry.missing', context)).toThrow(
      /signal filter execution failed/
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
          actor_event: actorEventEnvelope(),
          model_ref: {
            profile: 'chat',
            provider_id: 'openrouter-main',
            model: 'openai/gpt-5.4-mini',
            provider_kind: 'openrouter',
            input_modalities: ['text'],
            vision_fallback_model_ref: {
              profile: 'vision_fallback',
              provider_id: 'openai-vision',
              model: 'gpt-5',
              provider_kind: 'openai',
              input_modalities: ['text', 'image']
            }
          },
          request_context: {
            kind: 'schedule',
            silent_success_allowed: true
          }
        }
      }
    }

    const encoded = kernel.runtimeFabricEncodeEnvelope(envelope)
    expect(Buffer.isBuffer(encoded)).toBe(true)

    const decoded = kernel.runtimeFabricDecodeEnvelope(encoded)
    expect(decoded.body.type).toBe('turn_start')
    expect(decoded.body.turn_start.turn.actor).toEqual({
      agent_uid: 'agent-1',
      session_id: 'signal-channel:lark:dm:1'
    })
    expect(decoded.body.turn_start.actor_event.payload_json.text).toBe('PING')
    expect(decoded.body.turn_start.actor_event.binding_name).toBe('lark')
    expect(decoded.body.turn_start.actor_event.signal_channel_id).toBe('lark:chat:group-a')
    expect(decoded.body.turn_start.actor_event.provider_thread_id).toBe('thread-1')
    expect(decoded.body.turn_start.model_ref.provider_kind).toBe('openrouter')
    expect(decoded.body.turn_start.model_ref.input_modalities).toEqual(['text'])
    expect(decoded.body.turn_start.model_ref.vision_fallback_model_ref).toMatchObject({
      profile: 'vision_fallback',
      provider_id: 'openai-vision',
      model: 'gpt-5',
      provider_kind: 'openai',
      input_modalities: ['text', 'image']
    })
    expect(decoded.body.turn_start.request_context.silent_success_allowed).toBe(true)
  })

  it('encodes and decodes RuntimeFabric mailbox updates without inline inputs', () => {
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
          actor_event: {
            actor_event_id: '22222222-2222-2222-2222-222222222222',
            queue_sequence: 2,
            type: 'command.steer',
            source_event_id: 'evt-steer-1',
            source_entry_id: 'msg-steer-1',
            payload_json: { text: 'change course' }
          }
        }
      }
    }

    const decoded = kernel.runtimeFabricDecodeEnvelope(kernel.runtimeFabricEncodeEnvelope(envelope))

    expect(decoded.body.type).toBe('mailbox_updated')
    expect(decoded.body.mailbox_updated.turn.actor_event_id).toBe('11111111-1111-1111-1111-111111111111')
    expect(decoded.body.mailbox_updated.actor_event.payload_json.text).toBe('change course')
    expect(decoded.body.mailbox_updated.inputs).toBeUndefined()
  })

  it('encodes and decodes RuntimeFabric noop turn completions', () => {
    const envelope = {
      protocol_version: 1,
      message_id: 'turn-noop-completed-1',
      correlation_id: 'turn-noop-completed-1',
      lane: 'LANE_TURN',
      durability: 'CONTROL_REPLAYABLE',
      body: {
        type: 'turn_noop_completed',
        turn_noop_completed: {
          turn: actorTurnRef(),
          reason: 'ambient_silent'
        }
      }
    }

    const decoded = kernel.runtimeFabricDecodeEnvelope(kernel.runtimeFabricEncodeEnvelope(envelope))

    expect(decoded.body.type).toBe('turn_noop_completed')
    expect(decoded.body.turn_noop_completed.turn.actor_event_id).toBe('11111111-1111-1111-1111-111111111111')
    expect(decoded.body.turn_noop_completed.reason).toBe('ambient_silent')
  })

  it('requires RuntimeFabric turn_start to carry one actor event', () => {
    expect(() =>
      kernel.runtimeFabricEncodeEnvelope({
        protocol_version: 1,
        message_id: 'turn-start-missing-event',
        correlation_id: 'turn-start-missing-event',
        lane: 'LANE_TURN',
        durability: 'CONTROL_REPLAYABLE',
        body: {
          type: 'turn_start',
          turn_start: {
            turn: actorTurnRef()
          }
        }
      })
    ).toThrow(/turn_start\.actor_event is required/)
  })

  it('requires RuntimeFabric mailbox_updated to carry one actor event', () => {
    expect(() =>
      kernel.runtimeFabricEncodeEnvelope({
        protocol_version: 1,
        message_id: 'mailbox-updated-missing-event',
        correlation_id: 'mailbox-updated-missing-event',
        lane: 'LANE_TURN',
        durability: 'CONTROL_EPHEMERAL',
        body: {
          type: 'mailbox_updated',
          mailbox_updated: {
            turn: actorTurnRef(),
            reason: 'command.steer'
          }
        }
      })
    ).toThrow(/mailbox_updated\.actor_event is required/)
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
                session_id: 'signal-channel:lark:dm:1'
              }
            }
          }
        }
      }
    })

    expect(kernel.runtimeFabricDecodeEnvelope(encoded).body.rpc_request.method).toBe(
      'agent_conversation.context.resolve'
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
            payload_json: { text: 'inline steer is not allowed' }
          }
        }
      })
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
            actor_event: actorEventEnvelope()
          }
        }
      })
    ).toThrow(/turn_start must use lane LANE_TURN/)
  })

  it('authorizes direct grants with the shared AuthZ engine', () => {
    expect(kernel.authzValidateCondition('principal.type == "human"')).toBe(true)
    expect(kernel.authzValidateResourcePattern('workspace:**')).toBe(true)
    expect(kernel.authzMatchResourcePattern('workspace:**', 'workspace:default')).toBe(true)

    const decision = kernel.authzAuthorize({
      principal: {
        uid: 'alice',
        type: 'human',
        status: 'active'
      },
      staticGroupIds: [],
      computedGroups: [],
      grants: [
        {
          id: 'grant-1',
          principalUid: 'alice',
          resourcePattern: 'workspace:**',
          action: 'read',
          condition: 'context.request.source == "test"'
        }
      ],
      resource: 'workspace:default',
      action: 'read',
      context: { source: 'test' }
    })

    expect(decision).toMatchObject({
      status: 'allow',
      diagnostics: [],
      effectiveGroupIds: []
    })
  })
})

function actorTurnRef() {
  return {
    actor: {
      agent_uid: 'agent-1',
      session_id: 'signal-channel:lark:dm:1'
    },
    activation_uid: 'activation-1',
    actor_epoch: 1,
    actor_event_id: '11111111-1111-1111-1111-111111111111',
    revision: 0
  }
}

function actorEventEnvelope() {
  return {
    actor_event_id: '00000000-0000-0000-0000-000000000001',
    queue_sequence: 1,
    type: 'im.message.addressed',
    source_event_id: 'event-1',
    source_entry_id: 'message-1',
    binding_name: 'lark',
    signal_channel_id: 'lark:chat:group-a',
    provider_thread_id: 'thread-1',
    payload_json: { text: 'PING' }
  }
}

function workerReadyEnvelope(workerId: string) {
  return {
    protocol_version: 1,
    message_id: `worker-ready-${workerId}`,
    lane: 'LANE_CONTROL',
    durability: 'CONTROL_EPHEMERAL',
    body: {
      type: 'worker_ready',
      worker_ready: {
        worker_id: workerId,
        runtime: 'bun',
        version: 'test',
        capacity_json: { available_turn_slots: 1 }
      }
    }
  }
}
