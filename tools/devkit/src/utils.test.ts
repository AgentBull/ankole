import { describe, expect, test } from 'bun:test'

import { runChildCaptured } from './utils'

describe('runChildCaptured', () => {
  // The worker-bootstrap timeout branch identifies a killed child by
  // status null without an error. This pins that spawn timeout shape.
  test('reports a timed-out child as status null without an error', async () => {
    const result = await runChildCaptured('sleep', ['30'], { timeout: 300, killSignal: 'SIGKILL' })

    expect(result).toEqual({ status: null, stdout: '', stderr: '' })
  })
})
