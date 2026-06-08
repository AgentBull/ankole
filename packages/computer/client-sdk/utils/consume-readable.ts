/** Fully drain a byte stream into a single Buffer. */
export async function readableToBuffer(stream: ReadableStream<Uint8Array>): Promise<Buffer> {
  const chunks: Uint8Array[] = []
  const reader = stream.getReader()
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      if (value) chunks.push(value)
    }
  } finally {
    reader.releaseLock()
  }
  return Buffer.concat(chunks)
}

export async function readableToString(stream: ReadableStream<Uint8Array>): Promise<string> {
  return (await readableToBuffer(stream)).toString('utf-8')
}
