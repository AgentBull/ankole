import { describe, expect, it } from 'bun:test'
import { z } from 'zod'
import { MAX_TOOL_ARGUMENT_BYTES, validateToolArgumentsWithRepair } from '../../src/core/llm/tool-schema'

const PathArguments = z.object({ path: z.string() }).strict()

describe('tool argument repair', () => {
  it('keeps strict JSON unchanged', () => {
    const result = validateToolArgumentsWithRepair('{"path":"/tmp/report.py"}', PathArguments)

    expect(result).toEqual({
      value: { path: '/tmp/report.py' },
      normalizedArguments: '{"path":"/tmp/report.py"}',
      repair: 'none'
    })
  })

  it('repairs fenced, surrounded, and punctuation-truncated JSON objects', () => {
    expect(validateToolArgumentsWithRepair('```json\n{"path":"/tmp/a"}\n```', PathArguments).repair).toBe('code_fence')
    expect(validateToolArgumentsWithRepair('arguments: {"path":"/tmp/b"} thanks', PathArguments).repair).toBe(
      'balanced_object'
    )

    const truncated = validateToolArgumentsWithRepair('{"path":"/tmp/c",', PathArguments)
    expect(truncated.repair).toBe('incomplete_container')
    expect(truncated.value).toEqual({ path: '/tmp/c' })
    expect(truncated.normalizedArguments).toBe('{"path":"/tmp/c"}')
  })

  it('never guesses an unterminated string and still validates repaired values against the tool schema', () => {
    expect(() => validateToolArgumentsWithRepair('{"path":"/tmp/repor', PathArguments)).toThrow(
      'tool arguments must be valid JSON'
    )
    expect(() => validateToolArgumentsWithRepair('{"path":"/tmp/a","unexpected":true,', PathArguments)).toThrow()
  })

  it('rejects arguments over the execution boundary before parsing or repair', () => {
    const oversized = `{"path":"${'x'.repeat(MAX_TOOL_ARGUMENT_BYTES)}"}`

    expect(() => validateToolArgumentsWithRepair(oversized, PathArguments)).toThrow(
      `tool arguments exceed the ${MAX_TOOL_ARGUMENT_BYTES}-byte limit`
    )
  })
})
