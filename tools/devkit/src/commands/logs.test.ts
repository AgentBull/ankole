import { describe, expect, test } from 'bun:test'
import { ankolePrettyLogOptions, formatPrettyLogMessage } from './logs'

describe('logs pretty', () => {
  test('uses the Ankole structured log keys', () => {
    expect(ankolePrettyLogOptions()).toMatchObject({
      messageKey: 'message',
      levelKey: 'severity',
      errorLikeObjectKeys: ['error']
    })
  })

  test('formats component, event, duration, and message for local dev display', () => {
    expect(
      formatPrettyLogMessage(
        {
          labels: { component: 'worker' },
          event: 'worker.turn_completed',
          duration_ms: 42,
          message: 'turn completed'
        },
        'message'
      )
    ).toBe('worker worker.turn_completed 42ms: turn completed')
  })


})
