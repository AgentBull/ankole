import OpenAI from 'openai'
import { ResponsesWS } from 'openai/resources/responses/ws'
import type { ResponseCompletedEvent } from 'openai/resources/responses/responses'

const baseURL = process.env.ANKOLE_AI_GATEWAY_BASE_URL
const apiKey = process.env.ANKOLE_AI_GATEWAY_API_KEY

if (!baseURL || !apiKey) throw new Error('AIGateway SDK fixture requires base URL and API key')

const imageBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
const imageBytes = Uint8Array.from(atob(imageBase64), character => character.charCodeAt(0))
const client = new OpenAI({ apiKey, baseURL })

const file = await client.files.create({
  file: new File([imageBytes], 'source.png', { type: 'image/png' }),
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
        { type: 'input_image', file_id: file.id, detail: 'auto' }
      ]
    }
  ],
  tools: [{ type: 'image_generation', action: 'edit' }],
  tool_choice: { type: 'image_generation' }
})

const image = response.output.find(item => item.type === 'image_generation_call')
if (!image || image.status !== 'completed' || !image.result) {
  throw new Error('official Responses client did not receive a completed edited image')
}

const stream = await client.responses.create({
  model: 'primary',
  input: '画一座月光下的山',
  stream: true,
  tools: [{ type: 'image_generation', action: 'generate', partial_images: 1 }],
  tool_choice: { type: 'image_generation' }
})
const streamEvents: string[] = []
const streamSequences: number[] = []
for await (const event of stream) {
  streamEvents.push(event.type)
  streamSequences.push(event.sequence_number)
}

const requiredImageEvents = [
  'response.created',
  'response.in_progress',
  'response.output_item.added',
  'response.image_generation_call.in_progress',
  'response.image_generation_call.generating',
  'response.image_generation_call.partial_image',
  'response.image_generation_call.completed',
  'response.output_item.done'
]
if (
  JSON.stringify(streamEvents.slice(0, requiredImageEvents.length)) !== JSON.stringify(requiredImageEvents) ||
  streamEvents.at(-1) !== 'response.completed'
) {
  throw new Error(`unexpected hosted image stream: ${JSON.stringify(streamEvents)}`)
}
if (streamSequences.some((sequence, index) => sequence !== index)) {
  throw new Error(`non-contiguous hosted image stream: ${JSON.stringify(streamSequences)}`)
}

const ws = new ResponsesWS(client, { reconnect: null })
const nextCompleted = () =>
  new Promise<ResponseCompletedEvent>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('ResponsesWS timed out')), 5_000)
    ws.once('response.completed', event => {
      clearTimeout(timer)
      resolve(event)
    })
    ws.once('error', error => {
      clearTimeout(timer)
      reject(error)
    })
  })

const firstCompletion = nextCompleted()
ws.send({
  type: 'response.create',
  model: 'primary',
  input: '生成一张湖景',
  tools: [{ type: 'image_generation', action: 'generate' }],
  tool_choice: { type: 'image_generation' }
})
const firstEvent = await firstCompletion
const firstImage = firstEvent.response.output.find(item => item.type === 'image_generation_call')
if (typeof firstImage?.id !== 'string') throw new Error('ResponsesWS did not return an image ID')

const secondCompletion = nextCompleted()
ws.send({
  type: 'response.create',
  model: 'primary',
  input: [
    {
      id: firstImage.id,
      type: 'image_generation_call',
      status: 'completed',
      result: null
    },
    { role: 'user', content: '把天空改成星空' }
  ],
  tools: [{ type: 'image_generation', action: 'edit' }],
  tool_choice: { type: 'image_generation' }
})
await secondCompletion
const closed = new Promise<void>(resolve => ws.once('close', () => resolve()))
ws.close({ code: 1_000, reason: 'contract complete' })
await Promise.race([
  closed,
  new Promise<never>((_, reject) => setTimeout(() => reject(new Error('ResponsesWS close timed out')), 1_000))
])

process.stdout.write(
  `${JSON.stringify({
    file_id: file.id,
    response_id: response.id,
    image_id: image.id,
    stream_events: streamEvents,
    websocket_reused_image_id: firstImage.id
  })}\n`
)
