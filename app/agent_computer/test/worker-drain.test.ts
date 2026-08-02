import { describe, expect, it } from 'bun:test'
import { WorkerDrainState } from '../src/worker/drain'

describe('worker drain state', () => {
  it('rejects new turns but keeps the receive loop alive until active tasks finish', async () => {
    let finishTask!: () => void
    const task = new Promise<void>(resolve => {
      finishTask = resolve
    })
    const drain = new WorkerDrainState()

    drain.track(task)
    expect(drain.acceptsTurns).toBe(true)
    expect(drain.shouldContinue).toBe(true)

    expect(drain.begin('sigterm')).toBe(true)
    expect(drain.reason).toBe('sigterm')
    expect(drain.acceptsTurns).toBe(false)
    expect(drain.shouldContinue).toBe(true)

    finishTask()
    await task
    await Promise.resolve()

    expect(drain.activeTaskCount).toBe(0)
    expect(drain.shouldContinue).toBe(false)
  })

  it('keeps the first shutdown reason when more signals arrive', () => {
    const drain = new WorkerDrainState()

    expect(drain.begin('sigterm')).toBe(true)
    expect(drain.begin('sigint')).toBe(false)
    expect(drain.reason).toBe('sigterm')
  })
})
