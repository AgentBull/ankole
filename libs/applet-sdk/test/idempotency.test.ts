import { AsyncLocalStorage } from 'node:async_hooks'
import { describe, expect, test } from 'bun:test'
import { createIdempotencyExecutor } from '../src/idempotency'
import type { Routes } from '../src/server'

type LedgerRow = {
  status: 'in_flight' | 'done'
  value?: unknown
  ttlSeconds?: number
  expiresAt?: number
}

function createScopedTestLedger(clock = () => Date.now()) {
  const callerContext = new AsyncLocalStorage<string>()
  const rows = new Map<string, LedgerRow>()
  const released: string[] = []
  const claimedKeys: string[] = []

  const rowKey = (key: string) => `${callerContext.getStore() ?? 'default'}/${key}`

  const idempotent = createIdempotencyExecutor({
    claim: async (key, requestHash) => {
      expect(key.startsWith('_idempotency:')).toBe(true)
      expect(new TextEncoder().encode(key).byteLength).toBeLessThanOrEqual(255)
      expect(requestHash).toBe(key)
      const scoped = rowKey(key)
      claimedKeys.push(scoped)
      const existing = rows.get(scoped)
      if (existing?.status === 'done' && (existing.expiresAt === undefined || existing.expiresAt > clock())) {
        return { status: 'replayed', value: existing.value }
      }
      if (existing?.status === 'in_flight') {
        throw new Error(`idempotency_conflict:${scoped}`)
      }
      rows.set(scoped, { status: 'in_flight' })
      return { status: 'claimed', claimId: scoped }
    },
    complete: async (key, value, ttlSeconds) => {
      rows.set(rowKey(key), {
        status: 'done',
        value,
        ttlSeconds,
        expiresAt: clock() + ttlSeconds * 1_000
      })
      return { completed: true }
    },
    release: async key => {
      const scoped = rowKey(key)
      rows.delete(scoped)
      released.push(scoped)
      return { released: true }
    }
  })

  return {
    idempotent,
    rows,
    released,
    claimedKeys,
    asCaller: <T>(uid: string, fn: () => Promise<T>) => callerContext.run(uid, fn)
  }
}

describe('AnkoleRuntime.idempotent', () => {
  test('replays completed executions, clones stored objects, and honors TTL windows', async () => {
    let now = 1_700_000_000_000
    const { idempotent, rows } = createScopedTestLedger(() => now)

    let sideEffectRuns = 0
    const first = await idempotent(
      'order-42',
      async () => {
        sideEffectRuns += 1
        return { chargeId: `ch_${sideEffectRuns}`, nested: { ok: true } }
      },
      { ttlSeconds: 60 }
    )
    first.nested.ok = false

    const second = await idempotent(
      'order-42',
      async () => {
        sideEffectRuns += 1
        return { chargeId: `ch_${sideEffectRuns}`, nested: { ok: true } }
      },
      { ttlSeconds: 60 }
    )

    expect(sideEffectRuns).toBe(1)
    expect(second).toEqual({ chargeId: 'ch_1', nested: { ok: true } })
    expect(rows.get('default/_idempotency:order-42')?.ttlSeconds).toBe(60)

    now += 30_000
    expect(await idempotent('order-42', async () => ({ chargeId: 'ch_skip', nested: { ok: true } }))).toEqual({
      chargeId: 'ch_1',
      nested: { ok: true }
    })

    now += 31_000
    expect(
      await idempotent('order-42', async () => {
        sideEffectRuns += 1
        return { chargeId: `ch_${sideEffectRuns}`, nested: { ok: true } }
      })
    ).toEqual({ chargeId: 'ch_2', nested: { ok: true } })
  })

  test('isolates concurrent callers sharing one warm isolate executor on the same key', async () => {
    const { idempotent, asCaller, rows } = createScopedTestLedger()

    const [aliceResult, bobResult] = await Promise.all([
      asCaller('alice', () =>
        idempotent('checkout-1', async () => {
          await Bun.sleep(20)
          return { owner: 'alice', amount: 120 }
        })
      ),
      asCaller('bob', () =>
        idempotent('checkout-1', async () => {
          await Bun.sleep(5)
          return { owner: 'bob', amount: 45 }
        })
      )
    ])

    expect(aliceResult).toEqual({ owner: 'alice', amount: 120 })
    expect(bobResult).toEqual({ owner: 'bob', amount: 45 })
    expect(rows.get('alice/_idempotency:checkout-1')?.status).toBe('done')
    expect(rows.get('bob/_idempotency:checkout-1')?.status).toBe('done')

    // Subsequent replays remain isolated per caller scope.
    expect(await asCaller('alice', () => idempotent('checkout-1', () => ({ owner: 'wrong', amount: 0 })))).toEqual({
      owner: 'alice',
      amount: 120
    })
    expect(await asCaller('bob', () => idempotent('checkout-1', () => ({ owner: 'wrong', amount: 0 })))).toEqual({
      owner: 'bob',
      amount: 45
    })
  })

  test('releases the lock when fn() throws, allowing retry, and round-trips undefined results', async () => {
    const { idempotent, released, rows } = createScopedTestLedger()

    let attempts = 0
    await expect(
      idempotent('flaky-webhook', async () => {
        attempts += 1
        throw new Error('upstream 502')
      })
    ).rejects.toThrow('upstream 502')

    expect(released).toEqual(['default/_idempotency:flaky-webhook'])
    expect(rows.has('default/_idempotency:flaky-webhook')).toBe(false)

    expect(
      await idempotent('flaky-webhook', async () => {
        attempts += 1
        return 'recovered'
      })
    ).toBe('recovered')
    expect(attempts).toBe(2)

    let voidRuns = 0
    expect(
      await idempotent('void-op', () => {
        voidRuns += 1
        return undefined
      })
    ).toBeUndefined()
    expect(
      await idempotent('void-op', () => {
        voidRuns += 1
        return undefined
      })
    ).toBeUndefined()
    expect(voidRuns).toBe(1)
  })

  test('never releases an in-flight lock after fn() succeeds if result encoding (>60 KiB / non-JSON) or complete() fails', async () => {
    let failComplete = false
    const rows = new Map<string, LedgerRow>()
    const released: string[] = []

    const idempotent = createIdempotencyExecutor({
      claim: async key => {
        if (rows.has(key)) throw new Error('already_claimed')
        rows.set(key, { status: 'in_flight' })
        return { status: 'claimed', claimId: key }
      },
      complete: async (key, value, ttlSeconds) => {
        if (failComplete) throw new Error('control_plane_disconnected')
        rows.set(key, { status: 'done', value, ttlSeconds })
      },
      release: async key => {
        rows.delete(key)
        released.push(key)
      }
    })

    let oversizedSideEffects = 0
    await expect(
      idempotent('oversized-return', async () => {
        oversizedSideEffects += 1
        return { payload: 'x'.repeat(65 * 1024) }
      })
    ).rejects.toThrow(RangeError)
    expect(oversizedSideEffects).toBe(1)
    expect(released).toEqual([])
    expect(rows.get('_idempotency:oversized-return')?.status).toBe('in_flight')

    let nonJsonSideEffects = 0
    await expect(
      idempotent('non-json-return', async () => {
        nonJsonSideEffects += 1
        return (() => 'not-json') as unknown
      })
    ).rejects.toThrow(TypeError)
    expect(nonJsonSideEffects).toBe(1)
    expect(released).toEqual([])
    expect(rows.get('_idempotency:non-json-return')?.status).toBe('in_flight')

    failComplete = true
    let completeFailureSideEffects = 0
    await expect(
      idempotent('complete-transient-drop', async () => {
        completeFailureSideEffects += 1
        return { charged: true }
      })
    ).rejects.toThrow('control_plane_disconnected')
    expect(completeFailureSideEffects).toBe(1)
    expect(released).toEqual([])
    expect(rows.get('_idempotency:complete-transient-drop')?.status).toBe('in_flight')
  })

  test('hashes keys exceeding 255 UTF-8 bytes with SHA-256, including multi-byte UTF-8 keys', async () => {
    const { idempotent, claimedKeys } = createScopedTestLedger()

    const longAsciiKey = `order-${'x'.repeat(300)}`
    expect(await idempotent(longAsciiKey, () => 99)).toBe(99)
    expect(await idempotent(longAsciiKey, () => 100)).toBe(99)

    // 100 CJK characters = 100 UTF-16 code units (< 255), but 300 UTF-8 bytes (> 255).
    const multibyteKey = '中'.repeat(100)
    expect(multibyteKey.length).toBe(100)
    expect(await idempotent(multibyteKey, () => 'cjk-ok')).toBe('cjk-ok')
    expect(await idempotent(multibyteKey, () => 'cjk-duplicate')).toBe('cjk-ok')

    const shaKeys = claimedKeys.filter(k => k.includes('_idempotency:sha256:'))
    expect(shaKeys).toHaveLength(4)

    // Type-level check that Route handlers see AnkoleRuntime.idempotent & AnkoleRuntime.admin.idempotent.
    const typedRoutes: Routes = {
      'POST /orders/:id': async ({ params }) =>
        AnkoleRuntime.idempotent(`pay:${params.id}`, () => ({ paid: true }), { ttlSeconds: 3600 })
    }
    expect(typeof typedRoutes['POST /orders/:id']).toBe('function')
  })

  test('forwards claimId to complete and release so expired claims cannot overwrite or release newer owners', async () => {
    let claimCounter = 0
    const completedCalls: Array<{ key: string; ttlSeconds: number; claimId?: string }> = []
    const releasedCalls: Array<{ key: string; claimId?: string }> = []
    const rows = new Map<string, { status: 'in_flight' | 'done'; claimId: string; value?: unknown }>()

    const idempotent = createIdempotencyExecutor({
      claim: async key => {
        const claimId = `claim-${++claimCounter}`
        rows.set(key, { status: 'in_flight', claimId })
        return { status: 'claimed', claimId }
      },
      complete: async (key, value, ttlSeconds, claimId) => {
        completedCalls.push({ key, ttlSeconds, claimId })
        const current = rows.get(key)
        if (current && current.claimId === claimId) {
          rows.set(key, { status: 'done', claimId, value })
        }
      },
      release: async (key, claimId) => {
        releasedCalls.push({ key, claimId })
        const current = rows.get(key)
        if (current && current.claimId === claimId) {
          rows.delete(key)
        }
      }
    })

    expect(await idempotent('invoice-1', () => ({ ok: true }), { ttlSeconds: 120 })).toEqual({ ok: true })
    expect(completedCalls).toEqual([{ key: '_idempotency:invoice-1', ttlSeconds: 120, claimId: 'claim-1' }])
    expect(releasedCalls).toEqual([])

    await expect(
      idempotent('invoice-2', () => {
        throw new Error('transient_failure')
      })
    ).rejects.toThrow('transient_failure')
    expect(releasedCalls).toEqual([{ key: '_idempotency:invoice-2', claimId: 'claim-2' }])
  })
})
