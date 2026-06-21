import { describe, expect, it } from 'bun:test'
import { GenerationStallWatchdog } from './generation-watchdog'

// Covers the two stall signatures and, crucially, the cases that must NOT count
// as a stall: streaming gaps under budget, and tool execution (disarmed) silence.
describe('GenerationStallWatchdog', () => {
  // Wedge before any content: the generous first-token budget eventually fires,
  // and only once even though the check keeps ticking.
  it('fires onStall exactly once after sustained silence on an armed call', async () => {
    let stalls = 0
    const watchdog = new GenerationStallWatchdog({
      stallTimeoutMs: 40,
      checkIntervalMs: 5,
      onStall: () => {
        stalls += 1
      }
    })
    watchdog.arm()
    await Bun.sleep(150)
    expect(stalls).toBe(1)
    watchdog.stop()
  })

  // Each chunk resets the clock, so a steadily-streaming model never trips; the
  // stall only lands once the chunks stop for longer than the budget.
  it('stays quiet while content streams, then fires once it stops', async () => {
    let stalls = 0
    const watchdog = new GenerationStallWatchdog({
      stallTimeoutMs: 80,
      checkIntervalMs: 5,
      onStall: () => {
        stalls += 1
      }
    })
    watchdog.arm()
    for (let i = 0; i < 6; i++) {
      await Bun.sleep(20)
      watchdog.touchContent()
    }
    expect(stalls).toBe(0)
    await Bun.sleep(200)
    expect(stalls).toBe(1)
    watchdog.stop()
  })

  it('applies the tight gap budget once content streams', async () => {
    const stalls: string[] = []
    const watchdog = new GenerationStallWatchdog({
      stallTimeoutMs: 500,
      streamGapTimeoutMs: 40,
      checkIntervalMs: 5,
      onStall: (_silentForMs, phase) => {
        stalls.push(phase)
      }
    })
    watchdog.arm()
    // Awaiting first content: generous budget, no stall yet.
    await Bun.sleep(100)
    expect(stalls).toHaveLength(0)
    // Content starts streaming, then the pipe dies: tight budget fires.
    watchdog.touchContent()
    await Bun.sleep(150)
    expect(stalls).toEqual(['streaming'])
    watchdog.stop()
  })

  it('does not stall during tool execution: disarm stops the clock past the budget', async () => {
    let stalls = 0
    const watchdog = new GenerationStallWatchdog({
      stallTimeoutMs: 30,
      streamGapTimeoutMs: 30,
      checkIntervalMs: 5,
      onStall: () => {
        stalls += 1
      }
    })
    watchdog.arm()
    watchdog.touchContent()
    // The LLM stream ended and a (possibly long) tool call begins; the watchdog
    // must ignore that silence entirely — a slow tool is not an LLM stall.
    watchdog.disarm()
    expect(watchdog.isWatchingLlmStream()).toBe(false)
    expect(watchdog.silentForMs()).toBe(0)
    await Bun.sleep(120)
    expect(stalls).toBe(0)
    watchdog.stop()
  })

  // The watchdog is per-call, not per-run: after a tool pause (disarm) the next
  // call re-arms and is watched again on its own budget.
  it('re-arms for the next call after a tool pause', async () => {
    let stalls = 0
    const watchdog = new GenerationStallWatchdog({
      stallTimeoutMs: 40,
      checkIntervalMs: 5,
      onStall: () => {
        stalls += 1
      }
    })
    watchdog.arm()
    watchdog.disarm() // first call finished, tool ran
    watchdog.arm() // next call's stream opened — watched again
    await Bun.sleep(150)
    expect(stalls).toBe(1)
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
    watchdog.arm()
    watchdog.stop()
    await Bun.sleep(100)
    expect(stalls).toBe(0)
  })
})
