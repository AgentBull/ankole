import { describe, expect, test } from 'bun:test'
import { formatJSONDraft, inspectJSONDraft, parseJSONObjectDraft, serializeJSONObjectDraft } from './json-editor'

describe('JSON editor helpers', () => {
  test('formats valid drafts without changing their value', () => {
    expect(formatJSONDraft('{"enabled":true,"items":[1,2]}')).toBe(
      '{\n  "enabled": true,\n  "items": [\n    1,\n    2\n  ]\n}'
    )
  })

  test('keeps blank drafts neutral and rejects malformed JSON', () => {
    expect(inspectJSONDraft('   ')).toEqual({ kind: 'empty' })
    expect(inspectJSONDraft('{"enabled":}')).toMatchObject({ kind: 'invalid' })
    expect(formatJSONDraft('{"enabled":}')).toBeUndefined()
  })

  test('reports a line and column when the runtime exposes a parse offset', () => {
    const state = inspectJSONDraft('{\n  "enabled": true,\n  broken\n}', () => {
      throw new SyntaxError('Unexpected token at position 23')
    })
    expect(state.kind).toBe('invalid')
    if (state.kind === 'invalid') expect(state.error).toContain('line 3, column 3')
  })

  test('parses and serializes JSON object drafts without accepting other root types', () => {
    expect(parseJSONObjectDraft('{"enabled":true}')).toEqual({ enabled: true })
    expect(parseJSONObjectDraft('["one"]')).toBeUndefined()
    expect(parseJSONObjectDraft('null')).toBeUndefined()
    expect(serializeJSONObjectDraft({ enabled: true })).toBe('{\n  "enabled": true\n}')
    expect(serializeJSONObjectDraft(['one'])).toBeUndefined()
  })
})
