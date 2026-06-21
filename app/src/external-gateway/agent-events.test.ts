// Tests the input-window queue's recall-versus-receive race, driven
// deterministically through PostgreSQL advisory locks. The queue serializes a
// receive enqueue and a recall tombstone on a per-message advisory lock; these
// tests take that same lock from a transaction to force a precise interleaving
// and prove the loser observes the winner's effect. Hits the real database.
import { afterEach, describe, expect, it } from 'bun:test'
import { eq, sql } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type { ExternalGatewayAgentEnvelope } from './agent-events'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { ExternalGatewayAgentEvents, ExternalGatewayInputTombstones } = await import('@/common/db-schema')
const { DrizzleExternalGatewayAgentEventQueue, externalGatewayInputTombstoneLockKey } = await import('./agent-events')

const testPrefix = `test_external_gateway_events_${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()

afterEach(async () => {
  await DB.delete(ExternalGatewayAgentEvents).where(eq(ExternalGatewayAgentEvents.agentUid, testPrefix))
  await DB.delete(ExternalGatewayInputTombstones).where(eq(ExternalGatewayInputTombstones.agentUid, testPrefix))
})

describe('DrizzleExternalGatewayAgentEventQueue', () => {
  it('does not enqueue a receive when a recall tombstone wins the key race before enqueue', async () => {
    const queue = new DrizzleExternalGatewayAgentEventQueue()
    const key = tombstoneKey('race-before-enqueue')
    const input = receiveInput(key, 'received:race-before-enqueue')
    let enqueuePromise!: ReturnType<typeof queue.enqueueReceive>

    // Hold the message's advisory lock, kick off the enqueue (which now blocks
    // trying to take the same lock), insert the tombstone, then commit. The
    // enqueue can only proceed after commit, so it re-checks inside the lock and
    // sees the tombstone — exactly the ordering a real concurrent recall forces.
    await DB.transaction(async tx => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${externalGatewayInputTombstoneLockKey(key)}))`)
      enqueuePromise = queue.enqueueReceive(input)
      await Bun.sleep(20)
      await tx.insert(ExternalGatewayInputTombstones).values({
        ...key,
        expiresAt: new Date(Date.now() + 60_000)
      })
    })

    // The recall won the race, so the receive is dropped and no input row exists.
    const queued = await enqueuePromise
    expect(queued).toBeUndefined()
    expect(await eventsForAgent()).toHaveLength(0)
  })

  it('records tombstones under the same provider-message key lock', async () => {
    const queue = new DrizzleExternalGatewayAgentEventQueue()
    const key = tombstoneKey('record-lock')
    let settled = false
    let recordPromise!: Promise<void>

    // While the lock is held, recordInputTombstone must NOT settle — proving it
    // contends on the same per-message lock the receive enqueue uses, which is
    // what makes the two operations mutually exclusive.
    await DB.transaction(async tx => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${externalGatewayInputTombstoneLockKey(key)}))`)
      recordPromise = queue.recordInputTombstone(key).then(() => {
        settled = true
      })
      await Bun.sleep(20)
      expect(settled).toBe(false)
    })

    await recordPromise
    expect(await queue.hasInputTombstone(key)).toBe(true)
  })
})

function tombstoneKey(suffix: string) {
  return {
    agentUid: testPrefix,
    bindingName: 'main',
    providerMessageId: `m-${suffix}`,
    providerRoomId: `room-${suffix}`
  }
}

function receiveInput(key: ReturnType<typeof tombstoneKey>, providerEventId: string) {
  return {
    agentUid: key.agentUid,
    actorKey: 'alice',
    batchKey: `batch:${key.providerRoomId}`,
    bindingName: key.bindingName,
    deliveryMode: 'addressed' as const,
    payload: envelope(providerEventId),
    providerEventId,
    providerMessageId: key.providerMessageId,
    providerRoomId: key.providerRoomId,
    providerThreadId: `${key.providerRoomId}:thread`
  }
}

function envelope(id: string): ExternalGatewayAgentEnvelope {
  return {
    specversion: '1.0',
    id,
    source: 'external://test/main',
    subject: `external_messages:${id}`,
    time: new Date().toISOString(),
    type: 'message.received',
    data: {
      room: { id: 'room' },
      message: { id, text: 'hello' },
      mentions: [],
      session: {
        id: 'session',
        scope: 'external_room'
      }
    }
  }
}

async function eventsForAgent() {
  return DB.select().from(ExternalGatewayAgentEvents).where(eq(ExternalGatewayAgentEvents.agentUid, testPrefix))
}
