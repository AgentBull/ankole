import { describe, expect, it } from 'bun:test'
import { MAX_TOOL_ARGUMENT_BYTES, repairToolArgumentsJSON } from '../../src/core/llm/tool-schema'

describe('tool argument JSON repair', () => {
  it('keeps strict JSON unchanged', () => {
    const result = repairToolArgumentsJSON('{"path":"/tmp/report.py"}')

    expect(result).toEqual({
      value: { path: '/tmp/report.py' },
      normalizedArguments: '{"path":"/tmp/report.py"}',
      repair: 'none'
    })
  })

  it('repairs fenced, surrounded, and punctuation-truncated JSON objects', () => {
    expect(repairToolArgumentsJSON('```json\n{"path":"/tmp/a"}\n```').repair).toBe('code_fence')
    expect(repairToolArgumentsJSON('arguments: {"path":"/tmp/b"} thanks').repair).toBe('balanced_object')

    const truncated = repairToolArgumentsJSON('{"path":"/tmp/c",')
    expect(truncated.repair).toBe('incomplete_container')
    expect(truncated.value).toEqual({ path: '/tmp/c' })
    expect(truncated.normalizedArguments).toBe('{"path":"/tmp/c"}')

    const withDanglingUnknownKey = repairToolArgumentsJSON('{"path":"/tmp/a","unexpected":true,')
    expect(withDanglingUnknownKey.repair).toBe('incomplete_container')
    expect(withDanglingUnknownKey.value).toEqual({ path: '/tmp/a', unexpected: true })
  })

  it('never guesses an unterminated string', () => {
    expect(() => repairToolArgumentsJSON('{"path":"/tmp/repor')).toThrow('tool arguments must be valid JSON')
  })

  it('rejects arguments over the execution boundary before parsing or repair', () => {
    const oversized = `{"path":"${'x'.repeat(MAX_TOOL_ARGUMENT_BYTES)}"}`

    expect(() => repairToolArgumentsJSON(oversized)).toThrow(
      `tool arguments exceed the ${MAX_TOOL_ARGUMENT_BYTES}-byte limit`
    )
  })
})
