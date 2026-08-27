import { describe, expect, test } from 'bun:test'
import type { AgentSkillLessonItem } from '../api/generated/types.gen'
import { groupSkillLessons } from './agent-library'

function lesson(overrides: Partial<AgentSkillLessonItem> & Pick<AgentSkillLessonItem, 'id'>): AgentSkillLessonItem {
  return {
    skill_name: 'brainstorming',
    agent_plugin_id: null,
    description: null,
    effective_enabled: true,
    content: 'State the situation, then the caution.',
    author_kind: 'human',
    author_uid: null,
    evidence_job_ids: [],
    checked_release: null,
    review_after: null,
    retired_at: null,
    // The wire value is null for an active row; the generated type drops null
    // from nullable enums (the codebase-wide hey-api behavior).
    retire_reason: null as unknown as AgentSkillLessonItem['retire_reason'],
    created_at: '2026-08-01T00:00:00Z',
    ...overrides
  }
}

describe('groupSkillLessons', () => {
  test('splits rows per skill into active and retired by retired_at', () => {
    const groups = groupSkillLessons([
      lesson({ id: 'a', skill_name: 'brainstorming' }),
      lesson({
        id: 'b',
        skill_name: 'brainstorming',
        retired_at: '2026-08-10T00:00:00Z',
        retire_reason: 'human_revoked'
      }),
      lesson({ id: 'c', skill_name: 'deep-research', author_kind: 'dreaming' })
    ])

    expect(groups.get('brainstorming')?.active.map(item => item.id)).toEqual(['a'])
    expect(groups.get('brainstorming')?.retired.map(item => item.id)).toEqual(['b'])
    expect(groups.get('deep-research')?.active.map(item => item.id)).toEqual(['c'])
    expect(groups.get('deep-research')?.retired).toEqual([])
  })

  test('keeps the server order inside each group and stays empty for unknown skills', () => {
    const groups = groupSkillLessons([
      lesson({ id: 'newer', created_at: '2026-08-20T00:00:00Z' }),
      lesson({ id: 'older', created_at: '2026-08-01T00:00:00Z' })
    ])

    expect(groups.get('brainstorming')?.active.map(item => item.id)).toEqual(['newer', 'older'])
    expect(groups.get('missing-skill')).toBeUndefined()
    expect(groupSkillLessons([]).size).toBe(0)
  })
})
