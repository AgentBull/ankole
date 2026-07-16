import { afterEach, describe, expect, it } from 'bun:test'
import OpenAI from 'openai'
import { ResponsesWS } from 'openai/resources/responses/ws'

const imageBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB'

function completedResponse(id: string, imageID: string) {
  return {
    id,
    object: 'response' as const,
    created_at: 1_753_000_000,
    status: 'completed' as const,
    model: 'primary',
    output: [
      {
        id: imageID,
        type: 'image_generation_call' as const,
        status: 'completed' as const,
        result: imageBase64,
        revised_prompt: 'A moonlit mountain lake'
      }
    ],
    usage: {
      input_tokens: 12,
      output_tokens: 4,
      total_tokens: 16,
      input_tokens_details: { cached_tokens: 0 },
      output_tokens_details: { reasoning_tokens: 0 }
    }
  }
}

function responseEvents(id: string, imageID: string) {
  const response = completedResponse(id, imageID)
  const createdResponse = {
    ...response,
    status: 'in_progress' as const,
    completed_at: null,
    output: [],
    usage: null
  }
  const inProgressItem = { ...response.output[0], status: 'in_progress', result: null }
  delete (inProgressItem as { revised_prompt?: string }).revised_prompt

  return [
    { type: 'response.created', sequence_number: 0, response: createdResponse },
    { type: 'response.in_progress', sequence_number: 1, response: createdResponse },
    {
      type: 'response.output_item.added',
      sequence_number: 2,
      output_index: 0,
      item: inProgressItem
    },
    {
      type: 'response.image_generation_call.in_progress',
      sequence_number: 3,
      output_index: 0,
      item_id: imageID
    },
    {
      type: 'response.image_generation_call.generating',
      sequence_number: 4,
      output_index: 0,
      item_id: imageID
    },
    {
      type: 'response.image_generation_call.partial_image',
      sequence_number: 5,
      output_index: 0,
      item_id: imageID,
      partial_image_index: 0,
      partial_image_b64: imageBase64.slice(0, 16)
    },
    {
      type: 'response.image_generation_call.completed',
      sequence_number: 6,
      output_index: 0,
      item_id: imageID
    },
    {
      type: 'response.output_item.done',
      sequence_number: 7,
      output_index: 0,
      item: response.output[0]
    },
    { type: 'response.completed', sequence_number: 8, response }
  ]
}

describe('OpenAI SDK image_generation serialization smoke contract', () => {
  const servers: Bun.Server<unknown>[] = []

  afterEach(() => {
    for (const server of servers.splice(0)) server.stop(true)
  })

  it('serializes official Files and Responses HTTP APIs', async () => {
    const forms: FormData[] = []
    const responseBodies: Record<string, unknown>[] = []
    const server = Bun.serve({
      port: 0,
      async fetch(request) {
        const url = new URL(request.url)
        if (url.pathname === '/api/v1/ai-gateway/files') {
          forms.push(await request.formData())
          return Response.json({
            id: 'file_019f64d0-d4b6-73b2-957a-17f48711ff2e',
            object: 'file',
            bytes: 8,
            created_at: 1_753_000_000,
            expires_at: 1_753_003_600,
            filename: 'source.png',
            purpose: 'vision',
            status: 'processed',
            status_details: null
          })
        }

        if (url.pathname === '/api/v1/ai-gateway/responses') {
          const body = (await request.json()) as Record<string, unknown>
          responseBodies.push(body)
          if (body.stream === true) {
            const payload = responseEvents(
              'resp_019f64d0-d4b6-73b2-957a-17f48711ff2f',
              'ig_019f64d0-d4b6-73b2-957a-17f48711ff30'
            )
              .map(event => `data: ${JSON.stringify(event)}\n\n`)
              .join('')
            return new Response(`${payload}data: [DONE]\n\n`, {
              headers: { 'content-type': 'text/event-stream' }
            })
          }

          return Response.json(
            completedResponse('resp_019f64d0-d4b6-73b2-957a-17f48711ff31', 'ig_019f64d0-d4b6-73b2-957a-17f48711ff32')
          )
        }

        return new Response('not found', { status: 404 })
      }
    })
    servers.push(server)

    const client = new OpenAI({
      apiKey: 'agent-key',
      baseURL: `http://127.0.0.1:${server.port}/api/v1/ai-gateway`
    })
    const uploaded = await client.files.create({
      file: new File(['png-data'], 'source.png', { type: 'image/png' }),
      purpose: 'vision',
      expires_after: { anchor: 'created_at', seconds: 3_600 }
    })

    const response = await client.responses.create({
      model: 'primary',
      input: [
        {
          role: 'user',
          content: [
            { type: 'input_text', text: '把背景改成夜晚' },
            { type: 'input_image', file_id: uploaded.id, detail: 'auto' }
          ]
        }
      ],
      tools: [
        {
          type: 'image_generation',
          action: 'edit',
          background: 'opaque',
          input_fidelity: null,
          input_image_mask: { file_id: uploaded.id },
          model: 'openai/gpt-image-2',
          moderation: 'low',
          output_compression: 80,
          output_format: 'png',
          partial_images: 0,
          quality: 'high',
          size: '1536x1024'
        }
      ],
      tool_choice: { type: 'image_generation' }
    })

    expect(response.output[0]).toMatchObject({
      type: 'image_generation_call',
      status: 'completed',
      result: imageBase64
    })
    const form = forms[0]
    expect(form.get('purpose')).toBe('vision')
    expect(form.get('expires_after[anchor]')).toBe('created_at')
    expect(form.get('expires_after[seconds]')).toBe('3600')
    expect(form.get('file')).toBeInstanceOf(File)
    expect(responseBodies[0]).toMatchObject({
      model: 'primary',
      tools: [
        {
          type: 'image_generation',
          action: 'edit',
          background: 'opaque',
          input_fidelity: null,
          input_image_mask: { file_id: uploaded.id },
          model: 'openai/gpt-image-2',
          moderation: 'low',
          output_compression: 80,
          output_format: 'png',
          partial_images: 0,
          quality: 'high',
          size: '1536x1024'
        }
      ],
      tool_choice: { type: 'image_generation' }
    })

    const stream = await client.responses.create({
      model: 'primary',
      input: '画一座月光下的山',
      stream: true,
      tools: [
        { type: 'image_generation', partial_images: 1 },
        {
          type: 'function',
          name: 'lookup_style',
          description: 'Look up a style reference',
          strict: true,
          parameters: { type: 'object', properties: {}, additionalProperties: false }
        }
      ],
      tool_choice: {
        type: 'allowed_tools',
        mode: 'required',
        tools: [{ type: 'image_generation' }, { type: 'function', name: 'lookup_style' }]
      }
    })
    const eventTypes: string[] = []
    for await (const event of stream) eventTypes.push(event.type)

    expect(eventTypes).toEqual([
      'response.created',
      'response.in_progress',
      'response.output_item.added',
      'response.image_generation_call.in_progress',
      'response.image_generation_call.generating',
      'response.image_generation_call.partial_image',
      'response.image_generation_call.completed',
      'response.output_item.done',
      'response.completed'
    ])
  })

  it('serializes ResponsesWS reuse of an image_generation_call ID for an edit', async () => {
    const requests: Record<string, unknown>[] = []
    const server = Bun.serve({
      port: 0,
      fetch(request, server) {
        if (server.upgrade(request)) return
        return new Response('not found', { status: 404 })
      },
      websocket: {
        message(ws, message) {
          const request = JSON.parse(
            typeof message === 'string' ? message : new TextDecoder().decode(message)
          ) as Record<string, unknown>
          requests.push(request)
          const index = requests.length
          const responseID = `resp_019f64d0-d4b6-73b2-957a-17f48711ff3${index + 2}`
          const imageID =
            index === 1 ? 'ig_019f64d0-d4b6-73b2-957a-17f48711ff35' : 'ig_019f64d0-d4b6-73b2-957a-17f48711ff36'
          for (const event of responseEvents(responseID, imageID)) ws.send(JSON.stringify(event))
        }
      }
    })
    servers.push(server)

    const client = new OpenAI({
      apiKey: 'agent-key',
      baseURL: `http://127.0.0.1:${server.port}/api/v1/ai-gateway`
    })
    const ws = new ResponsesWS(client, { reconnect: null })
    const completed: Array<Promise<unknown>> = []
    const nextCompletion = () =>
      new Promise(resolve => {
        ws.once('response.completed', resolve)
      })

    completed.push(nextCompletion())
    ws.send({
      type: 'response.create',
      model: 'primary',
      input: '生成一张湖景',
      tools: [{ type: 'image_generation' }],
      tool_choice: { type: 'image_generation' }
    })
    await completed[0]

    completed.push(nextCompletion())
    ws.send({
      type: 'response.create',
      model: 'primary',
      input: [
        {
          id: 'ig_019f64d0-d4b6-73b2-957a-17f48711ff35',
          type: 'image_generation_call',
          status: 'completed',
          result: null
        },
        { role: 'user', content: '把天空改成星空' }
      ],
      tools: [{ type: 'image_generation', action: 'edit' }],
      tool_choice: { type: 'image_generation' }
    })
    await completed[1]
    ws.close()

    expect(requests).toHaveLength(2)
    expect(requests[1]).toMatchObject({
      type: 'response.create',
      input: [
        {
          id: 'ig_019f64d0-d4b6-73b2-957a-17f48711ff35',
          type: 'image_generation_call',
          status: 'completed',
          result: null
        },
        { role: 'user', content: '把天空改成星空' }
      ],
      tools: [{ type: 'image_generation', action: 'edit' }]
    })
  })
})
