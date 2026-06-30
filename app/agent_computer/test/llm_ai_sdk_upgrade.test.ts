import { describe, expect, it } from 'bun:test'
import { convertAnkoleMessagesToModelMessages } from '../src/ai-gateway-client/ankole-ai-sdk'
import { createJsonResponseHandler } from '../src/ai-gateway-client/provider-utils/response-handler'
import type { FlexibleSchema } from '../src/ai-gateway-client/provider-utils/schema'
import { OpenResponsesLanguageModel } from '../src/ai-gateway-client/ai-gateway-provider/responses/open-responses-language-model'

describe('vendored AI SDK 7.0.4 core upgrade behavior', () => {
  it('defaults OpenResponses reasoning summary when reasoning effort is set', async () => {
    let sentBody: any
    const model = new OpenResponsesLanguageModel('gpt-5', {
      provider: 'test.responses',
      url: ({ path }) => `https://api.openai.test/v1${path}`,
      headers: () => ({ authorization: 'Bearer test-key' }),
      fetch: (async (_url: string | URL | Request, init?: RequestInit) => {
        sentBody = JSON.parse(String(init?.body))
        return new Response('{}', { headers: { 'content-type': 'application/json' } })
      }) as typeof fetch
    })

    // Drive the real public entrypoint (doGenerate), not the private getArgs helper. Response
    // parsing may reject on the stub body, but the request body is built and sent before that, so
    // the fetch stub captures exactly what would be POSTed to the provider.
    await model
      .doGenerate({
        prompt: [{ role: 'user', content: [{ type: 'text', text: 'hello' }] }],
        reasoning: 'medium',
        tools: []
      } as Parameters<typeof model.doGenerate>[0])
      .catch(() => {})

    expect(sentBody.reasoning).toEqual({ effort: 'medium', summary: 'detailed' })
  })

  it('uses bounded JSON response reads', async () => {
    const handler = createJsonResponseHandler({
      validate: async () => ({ success: true, value: {}, rawValue: {} })
    } as unknown as FlexibleSchema<{}>)
    const response = new Response('{}', {
      headers: {
        'content-length': String(2 * 1024 * 1024 * 1024 + 1)
      }
    })

    await expect(
      handler({
        response,
        url: 'https://example.test/too-large',
        requestBodyValues: {}
      })
    ).rejects.toThrow(/exceeded maximum size/)
  })

  it('maps image tool results to AI SDK multipart content output', () => {
    const [message] = convertAnkoleMessagesToModelMessages([
      {
        role: 'toolResult',
        toolCallId: 'call_screenshot',
        toolName: 'computer_screenshot',
        content: [
          { type: 'text', text: 'Captured current screen.' },
          { type: 'image', data: 'iVBORw0KGgo=', mimeType: 'image/png' }
        ],
        isError: false,
        timestamp: 0
      }
    ])

    expect(message).toEqual({
      role: 'tool',
      content: [
        {
          type: 'tool-result',
          toolCallId: 'call_screenshot',
          toolName: 'computer_screenshot',
          output: {
            type: 'content',
            value: [
              { type: 'text', text: 'Captured current screen.' },
              {
                type: 'file',
                mediaType: 'image/png',
                data: { type: 'data', data: 'iVBORw0KGgo=' }
              }
            ]
          }
        }
      ]
    })
  })

  it('lets the AI SDK Responses adapter send converted image tool results as input_image', async () => {
    let sentBody: any
    const model = new OpenResponsesLanguageModel('gpt-5', {
      provider: 'test.responses',
      url: ({ path }) => `https://api.openai.test/v1${path}`,
      headers: () => ({ authorization: 'Bearer test-key' }),
      fetch: (async (_url: string | URL | Request, init?: RequestInit) => {
        sentBody = JSON.parse(String(init?.body))
        return new Response('{}', { headers: { 'content-type': 'application/json' } })
      }) as typeof fetch
    })

    const prompt = convertAnkoleMessagesToModelMessages([
      {
        role: 'toolResult',
        toolCallId: 'call_screenshot',
        toolName: 'computer_screenshot',
        content: [
          { type: 'text', text: 'Captured current screen.' },
          { type: 'image', data: 'iVBORw0KGgo=', mimeType: 'image/png' }
        ],
        isError: false,
        timestamp: 0
      }
    ])

    await model
      .doGenerate({
        prompt,
        tools: []
      } as Parameters<typeof model.doGenerate>[0])
      .catch(() => {})

    expect(sentBody.input).toEqual([
      {
        type: 'function_call_output',
        call_id: 'call_screenshot',
        output: [
          { type: 'input_text', text: 'Captured current screen.' },
          { type: 'input_image', image_url: 'data:image/png;base64,iVBORw0KGgo=' }
        ]
      }
    ])
  })

  it('keeps error tool results text-only for the AI SDK error output shape', () => {
    const [message] = convertAnkoleMessagesToModelMessages([
      {
        role: 'toolResult',
        toolCallId: 'call_screenshot',
        toolName: 'computer_screenshot',
        content: [
          { type: 'text', text: 'Capture failed after partial image output.' },
          { type: 'image', data: 'iVBORw0KGgo=', mimeType: 'image/png' }
        ],
        isError: true,
        timestamp: 0
      }
    ])

    expect(message).toEqual({
      role: 'tool',
      content: [
        {
          type: 'tool-result',
          toolCallId: 'call_screenshot',
          toolName: 'computer_screenshot',
          output: {
            type: 'error-text',
            value: 'Capture failed after partial image output.\n[image:image/png]'
          }
        }
      ]
    })
  })
})
