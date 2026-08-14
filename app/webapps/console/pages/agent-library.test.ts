import { describe, expect, test } from 'bun:test'
import { skillExperienceDraft, skillExperienceUpdateBody } from './agent-library'

describe('Skill Experience editor', () => {
  test('submits edited text with the hash captured at edit start', () => {
    const draft = {
      ...skillExperienceDraft({ content_hash: 'hash-before-edit', text: 'local draft source' }),
      text: 'local edit'
    }

    expect(skillExperienceUpdateBody(draft)).toEqual({
      expected_content_hash: 'hash-before-edit',
      text: 'local edit'
    })
  })

  test('uses the empty hash when it starts a new overlay', () => {
    expect(skillExperienceDraft(undefined)).toEqual({ expectedContentHash: '', text: '' })
  })
})
