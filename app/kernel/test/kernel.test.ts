import { describe, expect, it } from 'bun:test'
import { Buffer } from 'node:buffer'
import { readFileSync } from 'node:fs'
import * as kernel from '../index.js'

describe('@ankole/kernel', () => {
  it('exports the public Bun API', () => {
    for (const name of [
      'runtimeFabricValidateEnvelope',
      'RuntimeFabricDealer',
      'authzAuthorize',
      'authzAuthorizeAll',
      'authzMatchResourcePattern',
      'authzValidateCondition',
      'authzValidateResourcePattern',
      'estimateO200kBaseTokens',
      'genericHash',
      'signalsGatewayFilterMatch',
      'signalsGatewayValidateFilter',
      'unifiedTextDiff',
      'webURLFacts',
      'xxh3File128Hex',
      'xxh3String128Hex',
      'zstdCompressBlock',
      'zstdDecompressBlock'
    ]) {
      expect(kernel[name as keyof typeof kernel]).toBeFunction()
    }
  })

  it('parses and classifies web URLs through the shared kernel classifier', () => {
    expect(kernel.webURLFacts('https://Example.COM/page')).toEqual({
      scheme: 'https',
      host: 'example.com',
      hostClass: 'public'
    })
    expect(kernel.webURLFacts('https://10.0.0.8/internal').hostClass).toBe('private')
    expect(kernel.webURLFacts('https://0x7f000001/').host).toBe('127.0.0.1')
    expect(kernel.webURLFacts('https://[::ffff:10.0.0.1]/').hostClass).toBe('private')
    expect(kernel.webURLFacts('https://169.254.169.254/latest/').hostClass).toBe('metadata')
    expect(kernel.webURLFacts('https://[fe80::1]/').hostClass).toBe('metadata')
    expect(kernel.webURLFacts('data:text/plain,hi').scheme).toBe('data')
    expect(kernel.webURLFacts('data:text/plain,hi').hostClass).toBeNil()
    expect(() => kernel.webURLFacts('not a url')).toThrow('invalid web url')
  })

  it('generates the narrowed RuntimeFabric TypeScript declarations during build', async () => {
    const declarations = Bun.file(new URL('../index.d.ts', import.meta.url))
    expect(await declarations.exists()).toBe(true)

    const source = await declarations.text()
    expect(source).toContain('sendEnvelope(envelope: Buffer): void')
    expect(source).toContain('sendFileFrame(frames: Buffer[]): void')
    expect(source).toContain('recvRawAsync(timeoutMs: number): Promise<Buffer[] | null>')
    expect(source).toContain('stop(): void')
    expect(source).not.toContain('recvRaw(timeoutMs')
  })

  it('computes string XXH3 fingerprints through the Bun bridge', () => {
    expect(kernel.xxh3String128Hex('TestCase')).toBe('7b16fe7c3e492b87d9615265f0856cec')
  })

  it('hashes binary data through the shared generic hash contract', () => {
    expect(kernel.genericHash(Buffer.from('bullx'))).toBe(
      '7f31cabae40697f9404428671c582d3c1f80c8a13d0741f4be8c9b856fcc0706'
    )
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

  it('surfaces RuntimeFabric validate failures and void dealer stop through the native binding', () => {
    expect(() => kernel.runtimeFabricValidateEnvelope(Buffer.from('not-protobuf'))).toThrow()

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
        dealer.sendEnvelope(goldenWorkerReadyBytes())
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

  it('validates host-encoded envelope bytes as the single semantic checker', () => {
    kernel.runtimeFabricValidateEnvelope(goldenBytes('turn_start.v2.bin'))
    kernel.runtimeFabricValidateEnvelope(goldenBytes('worker_ready.v2.bin'))

    expect(() => kernel.runtimeFabricValidateEnvelope(goldenBytes('turn_start.v1.bin'))).toThrow(
      /unsupported runtime fabric protocol version: 1/
    )
    expect(() => kernel.runtimeFabricValidateEnvelope(goldenBytes('worker_ready.v1.bin'))).toThrow(
      /unsupported runtime fabric protocol version: 1/
    )

    expect(() => kernel.runtimeFabricValidateEnvelope(Buffer.from([0xff, 0xff, 0xff]))).toThrow(
      /failed to decode runtime fabric envelope/
    )
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
      staticGroupIDs: [],
      computedGroups: [],
      grants: [
        {
          id: 'grant-1',
          principalUID: 'alice',
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
      effectiveGroupIDs: []
    })
  })
})

function goldenBytes(name: string): Buffer {
  return Buffer.from(readFileSync(new URL(`../proto/golden/${name}`, import.meta.url)))
}

function goldenWorkerReadyBytes(): Buffer {
  return goldenBytes('worker_ready.v2.bin')
}
