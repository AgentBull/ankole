import { describe, expect, test } from 'bun:test'
import type { WorkerEnvItem } from '../api/generated/types.gen'
import { workerEnvValueText } from './worker-env-visibility'

function item(overrides: Partial<WorkerEnvItem>): WorkerEnvItem {
  return {
    editable: true,
    kind: 'custom',
    name: 'EXAMPLE',
    present: true,
    secret: false,
    source: 'global',
    ...overrides
  }
}

describe('workerEnvValueText', () => {
  test('masks present values even when they were stored without encryption', () => {
    expect(workerEnvValueText(item({ value: 'credential-shaped-value' }))).toBe('••••••')
  })

  test('does not imply a value exists when the variable is unset', () => {
    expect(workerEnvValueText(item({ present: false, value: undefined }))).toBe('')
  })
})
