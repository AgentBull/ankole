import { describe, expect, it } from 'bun:test'
import { withCodexHomeSetup } from '../src/core/codex-runner/codex-home-setup'

describe('@ankole/agent-computer Codex Home setup', () => {
  it('serializes one Agent Home without blocking a different Agent', async () => {
    const order: string[] = []
    let releaseFirst = (): void => undefined
    let markFirstStarted = (): void => undefined
    const firstGate = new Promise<void>(resolve => {
      releaseFirst = resolve
    })
    const firstStarted = new Promise<void>(resolve => {
      markFirstStarted = resolve
    })

    const first = withCodexHomeSetup('/agents/alpha/.codex', async () => {
      order.push('alpha-1-start')
      markFirstStarted()
      await firstGate
      order.push('alpha-1-end')
    })
    await firstStarted

    const second = withCodexHomeSetup('/agents/alpha/.codex', async () => {
      order.push('alpha-2')
    })
    await withCodexHomeSetup('/agents/beta/.codex', async () => {
      order.push('beta')
    })
    expect(order).toEqual(['alpha-1-start', 'beta'])

    releaseFirst()
    await Promise.all([first, second])
    expect(order).toEqual(['alpha-1-start', 'beta', 'alpha-1-end', 'alpha-2'])
  })

  it('releases the next setup after a failure', async () => {
    await expect(
      withCodexHomeSetup('/agents/failure/.codex', async () => {
        throw new Error('setup failed')
      })
    ).rejects.toThrow('setup failed')

    await expect(withCodexHomeSetup('/agents/failure/.codex', async () => 'recovered')).resolves.toBe('recovered')
  })

  it('cancels a queued setup without letting the next setup pass the active one', async () => {
    const order: string[] = []
    let releaseFirst = (): void => undefined
    let markFirstStarted = (): void => undefined
    const firstGate = new Promise<void>(resolve => {
      releaseFirst = resolve
    })
    const firstStarted = new Promise<void>(resolve => {
      markFirstStarted = resolve
    })

    const first = withCodexHomeSetup('/agents/cancel/.codex', async () => {
      order.push('first-start')
      markFirstStarted()
      await firstGate
      order.push('first-end')
    })
    await firstStarted

    const controller = new AbortController()
    let cancelledSetupRan = false
    const cancelled = withCodexHomeSetup(
      '/agents/cancel/.codex',
      async () => {
        cancelledSetupRan = true
      },
      controller.signal
    )
    controller.abort(new Error('queued setup cancelled'))

    await expect(cancelled).rejects.toThrow('queued setup cancelled')
    expect(cancelledSetupRan).toBe(false)

    const next = withCodexHomeSetup('/agents/cancel/.codex', async () => {
      order.push('next')
    })
    await Promise.resolve()
    expect(order).toEqual(['first-start'])

    releaseFirst()
    await Promise.all([first, next])
    expect(order).toEqual(['first-start', 'first-end', 'next'])
  })
})
