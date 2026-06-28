import { describe, expect, it } from 'bun:test'
import { createJsonResponseHandler } from '../src/llm/provider-utils/response-handler'
import type { FlexibleSchema } from '../src/llm/provider-utils/schema'
import { createOpenAI } from '../src/llm/providers/openai'

describe('vendored AI SDK 7.0.4 core upgrade behavior', () => {
  it('defaults OpenAI Responses reasoning summary when reasoning effort is set', async () => {
    const openai = createOpenAI({ apiKey: 'test-key' })
    const model = openai.responses('gpt-5')
    const { args } = await (model as any).getArgs({
      prompt: [{ role: 'user', content: [{ type: 'text', text: 'hello' }] }],
      reasoning: 'medium',
      tools: []
    })

    expect(args.reasoning).toEqual({
      effort: 'medium',
      summary: 'detailed'
    })
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
})
