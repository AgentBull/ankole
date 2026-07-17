import { describe, expect, test } from 'bun:test'
import { ActiveBrowserLimiter } from '../src/daemon/active-browser-limiter'

describe('active browser limiter', () => {
  test('queues different sessions until a physical browser slot is released', async () => {
    const limiter = new ActiveBrowserLimiter(1)
    const releaseFirst = await limiter.acquire(Date.now() + 1_000)
    let acquiredSecond = false
    const second = limiter.acquire(Date.now() + 1_000).then(release => {
      acquiredSecond = true
      return release
    })

    await Bun.sleep(10)
    expect(acquiredSecond).toBe(false)
    releaseFirst.release()
    const releaseSecond = await second
    expect(acquiredSecond).toBe(true)
    releaseSecond.release()
  })

  test('honors the queued request deadline', async () => {
    const limiter = new ActiveBrowserLimiter(1)
    const release = await limiter.acquire(Date.now() + 1_000)
    await expect(limiter.acquire(Date.now() + 20)).rejects.toMatchObject({ code: 'timeout' })
    release.release()
  })

  test('reclaims the oldest idle browser before a waiting request times out', async () => {
    const limiter = new ActiveBrowserLimiter(1)
    const first = await limiter.acquire(Date.now() + 1_000)
    let reclaimed = false
    first.markIdle(async () => {
      reclaimed = true
      first.release()
    })

    const second = await limiter.acquire(Date.now() + 1_000)
    expect(reclaimed).toBe(true)
    second.release()
  })
})
