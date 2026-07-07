import { describe, expect, test } from 'bun:test'

import { bootstrapActivationCodeLine, bootstrapActivationCodeStatus } from './bootstrap-activation-code'

describe('bootstrap activation code display', () => {
  test('formats the active setup code line', () => {
    expect(bootstrapActivationCodeLine('ABCDEFGH')).toBe('SETUP ACTIVATION CODE: ABCDEFGH')
    expect(bootstrapActivationCodeStatus({ completed: false, value: 'ABCDEFGH' })).toEqual({
      kind: 'active',
      code: 'ABCDEFGH',
      text: 'SETUP ACTIVATION CODE: ABCDEFGH'
    })
  })

  test('formats terminal setup states', () => {
    expect(bootstrapActivationCodeStatus({ completed: true, value: null })).toEqual({
      kind: 'completed',
      text: 'Setup is already completed. No bootstrap activation code is active.'
    })
    expect(bootstrapActivationCodeStatus({ completed: false, value: null })).toEqual({
      kind: 'missing',
      text: 'Setup is open, but no bootstrap activation code is stored.'
    })
  })
})
