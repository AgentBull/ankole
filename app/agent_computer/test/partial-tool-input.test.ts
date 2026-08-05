import { describe, expect, it } from 'bun:test'
import { describeTruncatedToolCalls, readTruncatedToolCall } from '../src/core/llm/partial-tool-input'

function read(args: string) {
  return readTruncatedToolCall({ name: 'tool', arguments: args })
}

describe('readTruncatedToolCall', () => {
  it('measures how much of the cut field arrived', () => {
    const call = readTruncatedToolCall({
      name: 'write_file',
      arguments: '{"path": "a.ts", "content": "hello\\nworld'
    })

    expect(call).toEqual({
      name: 'write_file',
      argumentsComplete: false,
      argumentChars: 41,
      completedFields: ['path'],
      cutField: 'content',
      cutFieldChars: 11
    })
  })

  it('names a cut field it cannot measure', () => {
    const call = readTruncatedToolCall({ name: 'wait', arguments: '{"seconds": 12' })

    expect(call.cutField).toBe('seconds')
    expect(call.cutFieldChars).toBeUndefined()
  })

  it('keeps the namespace when the tool has one', () => {
    const call = readTruncatedToolCall({
      name: 'send',
      namespace: 'lark',
      arguments: '{"body": "hi'
    })

    expect(call.namespace).toBe('lark')
    expect(call.completedFields).toEqual([])
  })

  it('reports completed fields and the field the input stopped inside', () => {
    const call = read('{"path": "a.ts", "mode": "write", "content": "hel')

    expect(call.completedFields).toEqual(['path', 'mode'])
    expect(call.cutField).toBe('content')
    expect(call.cutFieldChars).toBe(3)
    expect(call.argumentsComplete).toBe(false)
  })

  it('counts decoded characters of the cut field, not raw characters', () => {
    const call = read('{"content": "line\\nnext\\u0041')

    expect(call.cutField).toBe('content')
    expect(call.cutFieldChars).toBe(10)
  })

  it('decodes an escaped key', () => {
    const call = read('{"a\\u0042c": 1, "next": "x')

    expect(call.completedFields).toEqual(['aBc'])
    expect(call.cutField).toBe('next')
  })

  it('skips nested containers and strings that hold braces', () => {
    const call = read('{"opts": {"a": [1, 2], "b": "}"}, "text": "tail')

    expect(call.completedFields).toEqual(['opts'])
    expect(call.cutField).toBe('text')
  })

  it('treats a closed object as complete with no cut field', () => {
    const call = read('{"path": "a.ts", "count": 3}')

    expect(call.argumentsComplete).toBe(true)
    expect(call.cutField).toBeUndefined()
    expect(call.completedFields).toEqual(['path', 'count'])
  })

  it('reports an empty object and an input that stopped inside a key', () => {
    expect(read('{}').argumentsComplete).toBe(true)
    expect(read('{}').completedFields).toEqual([])

    const midKey = read('{"path": "a.ts", "cont')
    expect(midKey.completedFields).toEqual(['path'])
    expect(midKey.cutField).toBeUndefined()
  })

  it('stops inside a value that is not a string', () => {
    const call = read('{"path": "a.ts", "count": 12')

    expect(call.completedFields).toEqual(['path'])
    expect(call.cutField).toBe('count')
  })

  it('reports input that is not a JSON object without inventing fields', () => {
    const array = read('["a"]')
    expect(array.argumentsComplete).toBe(false)
    expect(array.completedFields).toEqual([])
    expect(array.cutField).toBeUndefined()

    const badColon = read('{"a" 1}')
    expect(badColon.argumentsComplete).toBe(false)
    expect(badColon.completedFields).toEqual([])

    const badKeyEscape = read('{"a\\q": 1}')
    expect(badKeyEscape.argumentsComplete).toBe(false)
    expect(badKeyEscape.completedFields).toEqual([])
  })

  it('does not validate a string value it does not decode', () => {
    // Only decoded text is validated. A skipped value that JSON rejects leaves
    // the completed fields empty rather than failing the whole scan.
    const call = read('{"a": "\\q", "b": "tail')

    expect(call.completedFields).toEqual([])
    expect(call.cutField).toBe('b')
    expect(call.cutFieldChars).toBe(4)
  })
})

describe('describeTruncatedToolCalls', () => {
  it('states that nothing took effect and where the arguments stopped', () => {
    const text = describeTruncatedToolCalls([
      readTruncatedToolCall({
        name: 'write_file',
        arguments: '{"path": "a.ts", "content": "hello'
      })
    ])

    expect(text).toContain('did not run')
    expect(text).toContain('nothing took effect')
    expect(text).toContain('`write_file`')
    expect(text).toContain('completed fields: path')
    expect(text).toContain('stopped inside the value of `content` after 5 characters')
    expect(text).toContain('not yet applied')
  })

  it('counts several discarded calls', () => {
    const text = describeTruncatedToolCalls([
      readTruncatedToolCall({ name: 'a', arguments: '{"x": "1' }),
      readTruncatedToolCall({ name: 'b', arguments: '{"y": "2' })
    ])

    expect(text).toContain('Your last 2 tool calls did not run')
    expect(text).toContain('`a`')
    expect(text).toContain('`b`')
  })
})
