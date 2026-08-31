import { create, fromBinary, toBinary } from '@bufbuild/protobuf'
import { describe, expect, test } from 'bun:test'
import type { BrowserRuntime } from '../src/browser-runtime'
import {
  RenderedWebFetchRequestSchema,
  RenderedWebFetchResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { jsonFromBytes, RPCRequestSchema, type Envelope } from '../src/fabric/envelope_proto'
import { handleWorkerRPCRequest, rpcMethods } from '../src/lanes/rpc_lane'
import { createWorkerRPCHandlers } from '../src/worker/rpc_handlers'

describe('rendered web fetch worker RPC', () => {
  test('runs the request through the shared BrowserRuntime and returns its JSON body', async () => {
    const sent: Envelope[] = []
    const calls: unknown[] = []
    const browserRuntime = {
      fetchRendered: async (urls: string[], settings: unknown) => {
        calls.push({ urls, settings })
        return { results: [{ url: urls[0], text: 'rendered page' }] }
      }
    } as BrowserRuntime
    const handlers = createWorkerRPCHandlers({} as never, {} as never, browserRuntime)
    const request = create(RenderedWebFetchRequestSchema, {
      urls: ['https://example.com'],
      workerEnv: { BROWSER_PROFILE_SEED_FINGERPRINT: 'profile-v1' },
      ssrfFilter: false,
      idleTtlMs: 1_800_000n
    })

    await handleWorkerRPCRequest(
      async envelope => {
        sent.push(envelope)
      },
      create(RPCRequestSchema, {
        requestId: 'brain-rendered-fetch',
        method: rpcMethods.renderedWebFetch,
        payload: toBinary(RenderedWebFetchRequestSchema, request)
      }),
      handlers
    )

    expect(calls).toEqual([
      {
        urls: ['https://example.com'],
        settings: {
          workerEnv: { BROWSER_PROFILE_SEED_FINGERPRINT: 'profile-v1' },
          ssrfFilter: false,
          idleTtlMs: 1_800_000
        }
      }
    ])
    const body = sent[0]!.body
    if (body.case !== 'rpcResponse') throw new Error('expected rpcResponse')
    const response = fromBinary(RenderedWebFetchResponseSchema, body.value.payload)
    expect(jsonFromBytes(response.bodyJson)).toEqual({
      results: [{ url: 'https://example.com', text: 'rendered page' }]
    })
  })
})
