import type { StreamChunk } from './types'

const STREAM_CHUNK_TYPES = new Set(['markdown_text', 'task_update', 'plan_update'])

/**
 * Normalizes BullX chat output streams.
 *
 * Core accepts plain text chunks and BullX structured chunks. Provider-specific
 * model SDK event streams must be translated before they reach External Gateway, so
 * this function intentionally ignores arbitrary LLM-client event objects.
 */
export async function* normalizeBullXStream(stream: AsyncIterable<unknown>): AsyncIterable<string | StreamChunk> {
  for await (const event of stream) {
    if (typeof event === 'string') {
      yield event
      continue
    }

    if (event === null || typeof event !== 'object' || !('type' in event)) continue

    const typed = event as { type: string }
    if (STREAM_CHUNK_TYPES.has(typed.type)) yield event as StreamChunk
  }
}
