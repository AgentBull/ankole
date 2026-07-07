import { describe, expect, it } from 'bun:test'
import { createTurnActivity } from '../../src/core/turns/turn_activity'
import { sleep } from '../support/llm'

describe('@ankole/agent-computer turn activity watchdog', () => {
  it('aborts a pending turn step when the source signal aborts', async () => {
    const source = new AbortController()
    const activity = createTurnActivity({ sourceSignal: source.signal, inactivityTimeoutMs: 0 })

    try {
      const pending = activity.runStep(new Promise<string>(() => {}), 'agent conversation context')

      source.abort('source stopped')

      await expect(pending).rejects.toThrow('agent conversation context aborted: source stopped')
    } finally {
      activity.cleanup()
    }
  })

  it('aborts the turn after inactivity timeout elapses', async () => {
    const activity = createTurnActivity({ inactivityTimeoutMs: 15 })

    try {
      const reason = await waitForAbort(activity.signal)

      expect(reason).toBeInstanceOf(DOMException)
      expect((reason as DOMException).name).toBe('TimeoutError')
      expect((reason as DOMException).message).toContain('Timed out after 15ms without model/provider activity')
    } finally {
      activity.cleanup()
    }
  })

  it('resets the inactivity timeout when activity is observed', async () => {
    const activity = createTurnActivity({ inactivityTimeoutMs: 80 })

    try {
      await sleep(25)
      activity.touch('model:delta')
      await sleep(35)

      expect(activity.signal.aborted).toBe(false)

      await expect(waitForAbort(activity.signal, 120)).resolves.toBeInstanceOf(DOMException)
    } finally {
      activity.cleanup()
    }
  })

  it('suspends inactivity tracking while a turn step is explicitly suspended', async () => {
    const activity = createTurnActivity({ inactivityTimeoutMs: 20 })

    try {
      await activity.withSuspended('tool_execution', async () => {
        await sleep(40)
        expect(activity.signal.aborted).toBe(false)
      })

      await expect(waitForAbort(activity.signal, 80)).resolves.toBeInstanceOf(DOMException)
    } finally {
      activity.cleanup()
    }
  })

  it('cleanup removes pending timers and source abort listeners', async () => {
    const source = new AbortController()
    const activity = createTurnActivity({ sourceSignal: source.signal, inactivityTimeoutMs: 15 })

    activity.cleanup()
    source.abort('after cleanup')
    await sleep(35)

    expect(activity.signal.aborted).toBe(false)
  })
})

function waitForAbort(signal: AbortSignal, timeoutMs = 100): Promise<unknown> {
  if (signal.aborted) return Promise.resolve(signal.reason)

  return new Promise((resolve, reject) => {
    const onAbort = () => {
      clearTimeout(timeout)
      signal.removeEventListener('abort', onAbort)
      resolve(signal.reason)
    }
    const timeout = setTimeout(() => {
      signal.removeEventListener('abort', onAbort)
      reject(new Error('signal did not abort'))
    }, timeoutMs)

    signal.addEventListener('abort', onAbort, { once: true })
  })
}
