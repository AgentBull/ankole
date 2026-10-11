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

  it('reports the active tasks and the idle time since the last task ended', async () => {
    let finishTask!: () => void
    const task = new Promise<void>(resolve => {
      finishTask = resolve
    })
    const drain = new WorkerDrainState()

    drain.track(task)
    expect(drain.load).toEqual({ activeTasks: 1, idleForMs: 0 })

    finishTask()
    await task
    await Promise.resolve()
    await Bun.sleep(30)

    expect(drain.load.activeTasks).toBe(0)
    expect(drain.load.idleForMs).toBeGreaterThanOrEqual(25)
  })

  it('keeps the first shutdown reason when more signals arrive', () => {
    const drain = new WorkerDrainState()

    expect(drain.begin('sigterm')).toBe(true)
    expect(drain.begin('sigint')).toBe(false)
    expect(drain.reason).toBe('sigterm')
  })
})
