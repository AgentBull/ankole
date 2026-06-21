/**
 * Parses a stream of newline-delimited JSON (`application/x-ndjson`) into objects,
 * yielding each as soon as a full line arrives. This is what lets command output be
 * consumed incrementally instead of buffering the whole response.
 *
 * The streaming `TextDecoder` holds a partial trailing multi-byte character across
 * reads, so a UTF-8 sequence split across two network chunks is never corrupted.
 * Lines are buffered until a `\n` is seen; a final line with no trailing newline is
 * still emitted. The abort check runs each loop so a long-lived `follow` stream
 * stops promptly when cancelled.
 */
export async function* readNdjson<T = unknown>(
  stream: ReadableStream<Uint8Array>,
  signal?: AbortSignal
): AsyncGenerator<T> {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  try {
    for (;;) {
      if (signal?.aborted) throw signal.reason ?? new Error('aborted')
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      // Drain every complete line currently in the buffer; the remainder (a partial
      // line) stays buffered for the next chunk. Blank lines are skipped.
      for (;;) {
        const newline = buffer.indexOf('\n')
        if (newline < 0) break
        const line = buffer.slice(0, newline).trim()
        buffer = buffer.slice(newline + 1)
        if (line) yield JSON.parse(line) as T
      }
    }
    // A stream that ends without a final newline still has one last object to emit.
    const tail = buffer.trim()
    if (tail) yield JSON.parse(tail) as T
  } finally {
    reader.releaseLock()
  }
}
