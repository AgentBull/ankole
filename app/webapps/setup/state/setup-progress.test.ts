import { describe, expect, test } from 'bun:test'
import { setupStepState } from './setup-progress'

describe('setupStepState', () => {
  test('locks configuration until bootstrap is authenticated', () => {
    expect(setupStepState('bootstrap', 'bootstrap', false, false)).toBe('current')
    expect(setupStepState('plugins', 'bootstrap', false, false)).toBe('locked')
    expect(setupStepState('identity', 'bootstrap', false, false)).toBe('locked')
  })

  test('advances through completed plugin selection to identity', () => {
    expect(setupStepState('bootstrap', 'plugins', true, false)).toBe('completed')
    expect(setupStepState('plugins', 'plugins', true, false)).toBe('current')
    expect(setupStepState('plugins', 'identity', true, true)).toBe('completed')
    expect(setupStepState('identity', 'identity', true, true)).toBe('current')
  })

  test('keeps identity available after returning to plugins', () => {
    expect(setupStepState('plugins', 'plugins', true, true)).toBe('current')
    expect(setupStepState('identity', 'plugins', true, true)).toBe('available')
  })
})
