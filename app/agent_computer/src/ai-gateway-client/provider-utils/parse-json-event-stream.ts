import { EventSourceParserStream, type EventSourceMessage } from 'eventsource-parser/stream'
import { safeParseJSON, type ParseResult } from './parse-json'
import type { FlexibleSchema } from './schema'

/**
 * Parses a JSON event stream into a stream of parsed JSON objects.
 */
export function parseJsonEventStream<T>({
  stream,
  schema,
  abortSignal
}: {
  stream: ReadableStream<Uint8Array>
  schema: FlexibleSchema<T>
  abortSignal?: AbortSignal
}): ReadableStream<ParseResult<T>> {
  const pipeOptions = abortSignal ? { signal: abortSignal } : undefined

  const decoder = new TextDecoder()
  const textDecoderStream = new TransformStream<Uint8Array, string>({
    transform(chunk, controller) {
      controller.enqueue(decoder.decode(chunk, { stream: true }))
    },
    flush(controller) {
      const remaining = decoder.decode()
      if (remaining !== '') {
        controller.enqueue(remaining)
      }
    }
  })

  return stream
    .pipeThrough(textDecoderStream, pipeOptions)
    .pipeThrough(new EventSourceParserStream(), pipeOptions)
    .pipeThrough(
      new TransformStream<EventSourceMessage, ParseResult<T>>({
        async transform({ data }, controller) {
          // ignore the 'DONE' event that e.g. OpenAI sends:
          if (data === '[DONE]') {
            return
          }

          controller.enqueue(await safeParseJSON({ text: data, schema }))
        }
      }),
      pipeOptions
    )
}
