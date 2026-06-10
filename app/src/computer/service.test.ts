import { afterAll, beforeAll, describe, expect, it } from 'bun:test'
import { and, eq, inArray, like, not, sql } from 'drizzle-orm'
import { loadTestEnvFiles } from '../common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('../common/database')
const { ComputerAgentWorkerBindings, ComputerAgentWorkerPins, ComputerWorkers } =
  await import('../common/db-schema/computer')
const { registerWorker, releaseComputerWorkerBinding, resolveComputerWorker, setAgentPin } = await import('./service')

const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`
const workerIds = [0, 1, 2].map(index => `test-w${index}-${suffix}`)
const agentOf = (name: string) => `test-agent-${name}-${suffix}`

async function cleanup(): Promise<void> {
  await DB.delete(ComputerAgentWorkerBindings).where(like(ComputerAgentWorkerBindings.agentUid, `%${suffix}`))
  await DB.delete(ComputerAgentWorkerBindings).where(inArray(ComputerAgentWorkerBindings.workerId, workerIds))
  await DB.delete(ComputerAgentWorkerPins).where(inArray(ComputerAgentWorkerPins.workerId, workerIds))
  await DB.delete(ComputerWorkers).where(inArray(ComputerWorkers.workerId, workerIds))
}

async function setHealthy(workerId: string, healthy: boolean): Promise<void> {
  await DB.update(ComputerWorkers)
    .set({ lastHeartbeatAt: healthy ? sql`now()` : sql`now() - interval '120 seconds'` })
    .where(eq(ComputerWorkers.workerId, workerId))
}

beforeAll(async () => {
  await cleanup()
  for (const workerId of workerIds) {
    await registerWorker({
      workerId,
      instanceId: `${workerId}-inst`,
      baseUrl: `https://${workerId}:8787`,
      features: ['bwrap'],
      capacity: { maxAgents: 128 }
    })
  }
})

afterAll(cleanup)

describe('resolveComputerWorker', () => {
  it('creates a sticky implicit binding and reuses it', async () => {
    const agent = agentOf('sticky')
    const first = await resolveComputerWorker(agent)
    expect(workerIds).toContain(first.worker.workerId)
    expect(first.binding.kind).toBe('implicit')

    const second = await resolveComputerWorker(agent)
    expect(second.worker.workerId).toBe(first.worker.workerId)
  })

  it('spreads new agents across the least-bound workers', async () => {
    await DB.delete(ComputerAgentWorkerBindings).where(inArray(ComputerAgentWorkerBindings.workerId, workerIds))
    const otherHealthyWorkers = await DB.select({ workerId: ComputerWorkers.workerId })
      .from(ComputerWorkers)
      .where(
        and(
          not(inArray(ComputerWorkers.workerId, workerIds)),
          eq(ComputerWorkers.status, 'ready'),
          sql`${ComputerWorkers.lastHeartbeatAt} > now() - interval '30 seconds'`
        )
      )

    for (const row of otherHealthyWorkers) {
      for (let i = 0; i < 16; i++) {
        await DB.insert(ComputerAgentWorkerBindings)
          .values({
            agentUid: agentOf(`spread-baseline-${row.workerId}-${i}`),
            workerId: row.workerId,
            instanceId: `test-baseline-${i}`,
            bindingKind: 'implicit',
            bindingReason: 'test_baseline'
          })
          .onConflictDoNothing()
      }
    }

    const spreadAgents = Array.from({ length: 9 }, (_, index) => agentOf(`spread-${index}`))
    const used = new Set<string>()
    for (const agent of spreadAgents) {
      const resolved = await resolveComputerWorker(agent)
      used.add(resolved.worker.workerId)
    }
    expect(used).toEqual(new Set(workerIds))

    // The real invariant: strict least-bound selection keeps the fleet balanced.
    const rows = await DB.select({ workerId: ComputerAgentWorkerBindings.workerId, n: sql<number>`count(*)::int` })
      .from(ComputerAgentWorkerBindings)
      .where(inArray(ComputerAgentWorkerBindings.agentUid, spreadAgents))
      .groupBy(ComputerAgentWorkerBindings.workerId)
    const totals = rows.map(row => Number(row.n))
    expect(totals.reduce((sum, total) => sum + total, 0)).toBe(9)
    expect(totals.length).toBe(used.size)
    expect(Math.max(...totals) - Math.min(...totals)).toBeLessThanOrEqual(1)
  })

  it('honors an explicit pin', async () => {
    const agent = agentOf('pinned')
    const pinned = workerIds[2]!
    await setAgentPin({ agentUid: agent, workerId: pinned })
    const resolved = await resolveComputerWorker(agent)
    expect(resolved.worker.workerId).toBe(pinned)
    expect(resolved.binding.kind).toBe('explicit_pin')
  })

  it('falls back when the pinned worker is unhealthy, then recovers', async () => {
    const agent = agentOf('pin-fallback')
    const pinned = workerIds[0]!
    await setAgentPin({ agentUid: agent, workerId: pinned })
    expect((await resolveComputerWorker(agent)).worker.workerId).toBe(pinned)

    await setHealthy(pinned, false)
    const fallback = await resolveComputerWorker(agent)
    expect(fallback.worker.workerId).not.toBe(pinned)
    expect(fallback.binding.kind).toBe('fallback')

    await setHealthy(pinned, true)
    const recovered = await resolveComputerWorker(agent)
    expect(recovered.worker.workerId).toBe(pinned)
    expect(recovered.binding.kind).toBe('explicit_pin')
  })

  it('releases only the stale resolved worker binding for an agent', async () => {
    const agent = agentOf('release-stale')
    const first = await resolveComputerWorker(agent)
    await releaseComputerWorkerBinding(agent, {
      ...first.worker,
      instanceId: `${first.worker.instanceId}-stale`
    })
    expect((await resolveComputerWorker(agent)).worker.workerId).toBe(first.worker.workerId)

    await releaseComputerWorkerBinding(agent, first.worker)
    const rows = await DB.select()
      .from(ComputerAgentWorkerBindings)
      .where(eq(ComputerAgentWorkerBindings.agentUid, agent))
    expect(rows).toHaveLength(0)
  })
})
