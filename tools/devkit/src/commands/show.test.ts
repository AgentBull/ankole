import { describe, expect, test } from 'bun:test'
import { parseGetValueResult } from './show'

describe('show command', () => {
  test('parses value JSON after noisy Mix output', () => {
    expect(
      parseGetValueResult(
        ['Compiling 1 file (.ex)', '{"key":"bootstrap-activation-code","completed":false,"value":"ABCDEFGH"}'].join(
          '\n'
        )
      )
    ).toEqual({
      key: 'bootstrap-activation-code',
      value: 'ABCDEFGH',
      completed: false
    })
  })

  test('normalizes completed setup without an active value', () => {
    expect(parseGetValueResult('{"key":"bootstrap-activation-code","completed":true,"value":null}')).toEqual({
      key: 'bootstrap-activation-code',
      value: null,
      completed: true
    })
  })
})
