import { describe, expect, test } from 'bun:test'
import { setupStepState, readSetupProgress, type SetupStepID } from './setup-progress'

const done = (...steps: SetupStepID[]): ReadonlySet<SetupStepID> => new Set(steps)

describe('setupStepState', () => {
  test('locks configuration until bootstrap is authenticated', () => {
    expect(setupStepState('bootstrap', 'bootstrap', false, done())).toBe('current')
    expect(setupStepState('plugins', 'bootstrap', false, done())).toBe('locked')
    expect(setupStepState('industry', 'bootstrap', false, done())).toBe('locked')
    expect(setupStepState('identity', 'bootstrap', false, done())).toBe('locked')
  })

  test('advances through plugins and industry to identity', () => {
    expect(setupStepState('bootstrap', 'plugins', true, done())).toBe('completed')
    expect(setupStepState('plugins', 'plugins', true, done())).toBe('current')
    expect(setupStepState('industry', 'plugins', true, done())).toBe('locked')
    expect(setupStepState('identity', 'plugins', true, done())).toBe('locked')
    expect(setupStepState('plugins', 'industry', true, done('plugins'))).toBe('completed')
    expect(setupStepState('industry', 'industry', true, done('plugins'))).toBe('current')
    expect(setupStepState('identity', 'industry', true, done('plugins'))).toBe('locked')
    expect(setupStepState('industry', 'identity', true, done('plugins', 'industry'))).toBe('completed')
    expect(setupStepState('identity', 'identity', true, done('plugins', 'industry'))).toBe('current')
  })

  test('keeps later steps available after returning to plugins', () => {
    expect(setupStepState('plugins', 'plugins', true, done('plugins', 'industry'))).toBe('current')
    expect(setupStepState('industry', 'plugins', true, done('plugins', 'industry'))).toBe('available')
    expect(setupStepState('identity', 'plugins', true, done('plugins', 'industry'))).toBe('available')
    expect(setupStepState('identity', 'industry', true, done('plugins'))).toBe('locked')
  })
})

test('refresh restores the setup step and completed navigation', () => {
  const progress = readSetupProgress('?step=industry&completed=plugins,industry')
  expect(progress.step).toBe('industry')
  expect(setupStepState('identity', progress.step, true, progress.completed)).toBe('available')
  expect(readSetupProgress('?step=invalid').step).toBe('plugins')
})
