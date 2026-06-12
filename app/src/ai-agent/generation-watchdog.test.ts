import { describe, expect, it } from 'bun:test'
import { GenerationStallWatchdog } from './generation-watchdog'

describe('GenerationStallWatchdog', () => {
  it('fires onStall exactly once after sustained silence', async () => {
    let stalls = 0
    const watchdog = new GenerationStallWatchdog({
      stallTimeoutMs: 40,
      checkIntervalMs: 5,
      onStall: () => {
        stalls += 1
      }
    })
    watchdog.start()
    await Bun.sleep(150)
    expect(stalls).toBe(1)
    watchdog.stop()
  })

  it('stays quiet while events flow, then fires once they stop', async () => {
    let stalls = 0
    const watchdog = new GenerationStallWatchdog({
      stallTimeoutMs: 80,
      checkIntervalMs: 5,
      onStall: () => {
        stalls += 1
      }
    })
    watchdog.start()
    for (let i = 0; i < 6; i++) {
      await Bun.sleep(20)
      watchdog.touch()
    }
    expect(stalls).toBe(0)
    await Bun.sleep(200)
    expect(stalls).toBe(1)
    watchdog.stop()
  })

  it('applies the tight gap budget once content streams, and resets at boundaries', async () => {
    const stalls: string[] = []
    const watchdog = new GenerationStallWatchdog({
      stallTimeoutMs: 500,
      streamGapTimeoutMs: 40,
      checkIntervalMs: 5,
      onStall: (_silentForMs, phase) => {
        stalls.push(phase)
      }
    })
    watchdog.start()
    // Boundary-only silence stays under the generous budget.
    await Bun.sleep(100)
    expect(stalls).toHaveLength(0)
    // Content starts streaming, then the pipe dies: tight budget fires.
    watchdog.touchContent()
    await Bun.sleep(150)
    expect(stalls).toEqual(['streaming'])
    watchdog.stop()
  })

  it('a boundary event after content returns to the generous budget', async () => {
    let stalls = 0
    const watchdog = new GenerationStallWatchdog({
      stallTimeoutMs: 400,
      streamGapTimeoutMs: 30,
      checkIntervalMs: 5,
      onStall: () => {
        stalls += 1
      }
    })
    watchdog.start()
    watchdog.touchContent()
    watchdog.touch() // turn ended / tool started: silent tool work is allowed again
    await Bun.sleep(120)
    expect(stalls).toBe(0)
    watchdog.stop()
  })

  it('never stalls after stop', async () => {
    let stalls = 0
    const watchdog = new GenerationStallWatchdog({
      stallTimeoutMs: 30,
      checkIntervalMs: 5,
      onStall: () => {
        stalls += 1
      }
    })
    watchdog.start()
    watchdog.stop()
    await Bun.sleep(100)
    expect(stalls).toBe(0)
  })
})
