// Tests for the NDJSON line parser. They pin the parsing edge cases that matter for
// reading worker command streams: a final line with no trailing newline, and blank
// lines between records.
import { describe, expect, it } from 'bun:test'
import { readNdjson } from './ndjson'

// Wraps a string as a byte ReadableStream, the shape `readNdjson` consumes.
function streamOf(text: string): ReadableStream<Uint8Array> {
  return new Response(text).body!
}

describe('readNdjson', () => {
  it('parses newline-delimited objects', async () => {
    const out: unknown[] = []
    for await (const obj of readNdjson(streamOf('{"a":1}\n{"b":2}\n'))) out.push(obj)
    expect(out).toEqual([{ a: 1 }, { b: 2 }])
  })

  it('yields a trailing line without a newline', async () => {
    const out: unknown[] = []
    for await (const obj of readNdjson(streamOf('{"x":1}'))) out.push(obj)
    expect(out).toEqual([{ x: 1 }])
  })

  it('skips blank lines', async () => {
    const out: unknown[] = []
    for await (const obj of readNdjson(streamOf('{"a":1}\n\n{"b":2}\n'))) out.push(obj)
    expect(out).toEqual([{ a: 1 }, { b: 2 }])
  })
})
