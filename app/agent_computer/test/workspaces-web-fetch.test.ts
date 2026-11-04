import { describe, expect, it } from 'bun:test'
import type { JsonObject } from '@agentbull/active-support'
import { BrowserMaxResponseBytes, successResponse } from '@ankole/browser'
import type { ContentPart } from '../src/core/types'
import { RuntimeFabricTransportError } from '../src/fabric/fabric'
import {
  create,
  decodeEnvelope,
  encodeEnvelope,
  jsonBytes,
  jsonFromBytes,
  ProtocolVersion,
  Stream,
  type Envelope
} from '../src/fabric/envelope_proto'
import { ToolCallSchema, type ToolCall } from '../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import type { RenderedWebFetchBatch } from '../src/tools/web/web-tools'
import { Workspaces } from '../src/worker/workspaces'

type Result = { content: ContentPart[]; details?: unknown; isError?: boolean }

function fixture(fetchBatch: RenderedWebFetchBatch) {
  const sent: Envelope[] = []
  const pending: Promise<void>[] = []
  const space = {
    run: { session: { sessionId: 'conversation:web-fetch' }, signalId: 'input' },
    ready: Promise.resolve(),
    closing: false,
    idleMs: 0,
    calls: new Map<string, { result?: Result }>(),
    materials: { renderedFetch: { fetchBatch } }
  }
  // Only the channel and workspace preparation are unit fakes; call, execution, caching and serialization are real.
  const workspaces = new Workspaces(
    undefined as never,
    undefined as never,
    async envelope => {
      const size =
        encodeEnvelope({
          ...envelope,
          protocolVersion: ProtocolVersion.CURRENT,
          stream: Stream.DURABLE,
          transportSeq: 0n
        }).byteLength + 12
      if (size > 16 * 1024 * 1024 - 1025) {
        throw new RuntimeFabricTransportError('rejected', 'RuntimeFabric request exceeds the frame budget', {
          reason: 'frame_too_large'
        })
      }
      sent.push(envelope)
    },
    undefined as never,
    {
      acceptsTurns: true,
      track(promise: Promise<void>) {
        pending.push(promise)
        return promise
      }
    } as never,
    undefined as never
  ) as unknown as {
    spaces: Map<string, typeof space>
    call(input: ToolCall): void
  }

  return async (urls: string[]) => {
    const input = create(ToolCallSchema, {
      run: space.run,
      responseId: 'response',
      callId: 'fetch',
      name: '__rendered_web_fetch',
      argumentsJson: jsonBytes({ urls })
    })
    workspaces.spaces.set('conversation:web-fetch', space)
    workspaces.call(input)
    expect(pending).toHaveLength(1)
    await pending.shift()
    expect(sent).toHaveLength(1)
    const result = space.calls.values().next().value?.result
    if (!result) throw new Error('Expected the cached workspace result')
    const wire = encodeEnvelope(sent[0]!)
    const envelope = decodeEnvelope(wire)
    if (envelope.body.case !== 'toolResult') throw new Error('Expected the real workspace tool result')
    return {
      result,
      wire,
      content: jsonFromBytes(envelope.body.value.contentJson),
      details: jsonFromBytes(envelope.body.value.detailsJson) as JsonObject
    }
  }
}

describe('foreground rendered web_fetch workspace transport', () => {
  it('returns a bounded cached error when a browser-sized title exceeds the sealed Worker frame', async () => {
    const urls = Array.from({ length: 5 }, (_, index) => `https://example.com/${index}`)
    const text = '\u0001'.repeat(512 * 1024)
    const pages = urls.map(url => ({ url, title: '', text, metadata: { source: 'rendered_fallback' }, warnings: [] }))
    const body = { success: true, source: 'rendered_fallback', results: pages }
    const request = { id: crypto.randomUUID(), route: 'route', session: 'session' }
    const used = Buffer.byteLength(JSON.stringify(successResponse(request, body))) + 1
    pages[0]!.title = 'T'.repeat(BrowserMaxResponseBytes - used)
    expect(Buffer.byteLength(JSON.stringify(successResponse(request, body))) + 1).toBe(BrowserMaxResponseBytes)
    const fetch = fixture(async () => body)
    const result = await fetch(urls)
    expect(result.result.isError).toBe(true)
    expect(result.wire.byteLength).toBeLessThan(16_384)
    expect(result.content).toMatchObject([{ type: 'text', text: expect.stringContaining('too large to transfer') }])
  })

  it('keeps five default-sized escaped pages in one real Worker frame without duplicating their bodies', async () => {
    const urls = Array.from({ length: 5 }, (_, index) => `https://example.com/${index}`)
    const text = '\u0001'.repeat(512 * 1024)
    const pages = urls.map(url => ({ url, title: 'Article', text, metadata: { source: 'rendered_fallback' } }))
    const browser = successResponse({ id: 'fetch', route: 'route', session: 'session' }, { results: pages })
    expect(Buffer.byteLength(JSON.stringify(browser)) + 1).toBeLessThanOrEqual(BrowserMaxResponseBytes)
    const fetch = fixture(async received => {
      expect(received).toEqual(urls)
      return { results: pages }
    })

    const result = await fetch(urls)
    expect(result.wire.byteLength).toBeLessThanOrEqual(16 * 1024 * 1024 - 1025)
    expect(result.content).toEqual([])
    expect(result.result.content).toEqual([])
    expect(result.details).toEqual({ success: true, source: 'rendered_fallback', results: pages })
  })

  it('preserves a single URL failure in details for the control-plane completion', async () => {
    const url = 'https://example.com/failed'
    const fetch = fixture(async () => ({ results: [{ url, error: 'navigation timed out' }] }))
    const result = await fetch([url])
    expect(result.content).toEqual([])
    expect(result.details).toEqual({
      success: false,
      source: 'rendered_fallback',
      results: [{ url, text: '', error: 'navigation timed out', metadata: { source: 'rendered_fallback' } }]
    })
  })

  it('preserves successful siblings and request order in a mixed batch', async () => {
    const urls = ['https://example.com/first', 'https://example.com/failed', 'https://example.com/last']
    const fetch = fixture(async () => ({
      results: [{ text: 'first page' }, { error: 'blocked URL' }, { title: 'Last', text: 'last page' }]
    }))
    const result = await fetch(urls)
    expect(result.content).toEqual([])
    expect(result.details).toEqual({
      success: false,
      source: 'rendered_fallback',
      results: [
        { url: urls[0], text: 'first page', metadata: { source: 'rendered_fallback' } },
        { url: urls[1], text: '', error: 'blocked URL', metadata: { source: 'rendered_fallback' } },
        { url: urls[2], title: 'Last', text: 'last page', metadata: { source: 'rendered_fallback' } }
      ]
    })
  })
})
