import { describe, expect, mock, test } from 'bun:test'
import { enterRunsRowAction } from './brain-entry-editors'

describe('Brain entry editor keyboard actions', () => {
  test('does not run or consume Enter while an input method is composing', () => {
    const action = mock(() => {})
    const preventDefault = mock(() => {})
    const handler = enterRunsRowAction(action, true)

    handler({ key: 'Enter', nativeEvent: { isComposing: true }, preventDefault } as never)

    expect(action).not.toHaveBeenCalled()
    expect(preventDefault).not.toHaveBeenCalled()
  })

  test('runs a ready row action on a normal Enter', () => {
    const action = mock(() => {})
    const preventDefault = mock(() => {})
    const handler = enterRunsRowAction(action, true)

    handler({ key: 'Enter', nativeEvent: { isComposing: false }, preventDefault } as never)

    expect(action).toHaveBeenCalledTimes(1)
    expect(preventDefault).toHaveBeenCalledTimes(1)
  })
})
