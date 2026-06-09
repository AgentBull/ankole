import 'reflect-metadata'
import { afterAll, describe, expect, it } from 'bun:test'
import { inArray } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { Principals } = await import('@/common/db-schema')
const { createAgent } = await import('@/principals/agents/service')
const {
  getEffectiveSkillContent,
  getSoul,
  searchEffectiveSkills,
  setAgentSkillAppend,
  setAgentSkillEnabled,
  syncBuiltinLibraryFromAppDirectory
} = await import('./service')

const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const agentA = `library_test_a_${suffix}`
const agentB = `library_test_b_${suffix}`

afterAll(async () => {
  await DB.delete(Principals).where(inArray(Principals.uid, [agentA, agentB]))
})

describe('agent library containers and skills', () => {
  it('seeds SOUL.md and composes default skills with agent-specific append', async () => {
    await syncBuiltinLibraryFromAppDirectory({ force: true })
    await createAgent({ uid: agentA })
    await createAgent({ uid: agentB })

    const soul = await getSoul(agentA)
    expect(soul).toContain('Bayesian')

    const initial = await searchEffectiveSkills({ agentUid: agentA, query: 'BullX workflow' })
    expect(initial.map(skill => skill.name)).toContain('bullx-workflow')

    await setAgentSkillAppend({ agentUid: agentA, skillName: 'bullx-workflow', content: 'Prefer e2e evidence.' })
    const merged = await getEffectiveSkillContent({ agentUid: agentA, skillName: 'bullx-workflow' })
    expect(merged?.content).toContain('BullX Workflow')
    expect(merged?.content).toContain('Prefer e2e evidence.')

    await setAgentSkillEnabled({ agentUid: agentA, skillName: 'bullx-workflow', enabled: false, reason: 'test disable' })
    expect(await searchEffectiveSkills({ agentUid: agentA, query: 'BullX workflow' })).toHaveLength(0)

    const otherAgentSkills = await searchEffectiveSkills({ agentUid: agentB, query: 'BullX workflow' })
    expect(otherAgentSkills.map(skill => skill.name)).toContain('bullx-workflow')
  })
})
