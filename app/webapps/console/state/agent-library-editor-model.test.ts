import { describe, expect, test } from 'bun:test'
import { AgentLibraryEditorModel, type AgentLibraryDocumentsSnapshot } from './agent-library-editor-model'

function documents(mission: string, soul: string, design = 'Design A'): AgentLibraryDocumentsSnapshot {
  return {
    mission: { kind: 'mission', content: mission, content_hash: `mission:${mission}` },
    soul: { kind: 'soul', content: soul, content_hash: `soul:${soul}` },
    design: { kind: 'design', content: design, content_hash: `design:${design}` }
  }
}

describe('AgentLibraryEditorModel', () => {
  test('preserves an edited document during same-agent refetch and refreshes the other document', () => {
    const model = new AgentLibraryEditorModel()
    model.initialize('alpha', documents('Mission A', 'Soul A'))
    model.beginEdit('mission')
    model.setDraft('mission', 'Mission draft')

    model.initialize('alpha', documents('Mission from refetch', 'Soul from refetch'))

    expect(model.documents.mission.draft.value).toBe('Mission draft')
    expect(model.documents.mission.contentHash.value).toBe('mission:Mission A')
    expect(model.documents.soul.sourceContent.value).toBe('Soul from refetch')
    expect(model.documents.design.sourceContent.value).toBe('Design A')
    model[Symbol.dispose]()
  })

  test('resets every document when the route selects another agent', () => {
    const model = new AgentLibraryEditorModel()
    model.initialize('alpha', documents('Mission A', 'Soul A'))
    model.beginEdit('soul')
    model.setDraft('soul', 'Unsaved soul')

    model.initialize('beta', documents('Mission B', 'Soul B', 'Design B'))

    expect(model.sourceKey.value).toBe('agent:beta')
    expect(model.documents.mission.draft.value).toBe('Mission B')
    expect(model.documents.soul.draft.value).toBe('Soul B')
    expect(model.documents.soul.editing.value).toBeFalse()
    expect(model.documents.design.draft.value).toBe('Design B')
    model[Symbol.dispose]()
  })

  test('saves, cancels, and reloads one document without changing the other draft', () => {
    const model = new AgentLibraryEditorModel()
    model.initialize('alpha', documents('Mission A', 'Soul A'))
    model.beginEdit('mission')
    model.beginEdit('soul')
    model.setDraft('mission', 'Mission draft')
    model.setDraft('soul', 'Soul draft')

    model.cancel('mission')
    expect(model.documents.mission.draft.value).toBe('Mission A')
    expect(model.documents.soul.draft.value).toBe('Soul draft')

    const soulSubmission = model.snapshot('soul')
    model.markSaved('soul', { kind: 'soul', content: 'Soul saved', content_hash: 'soul:saved' }, soulSubmission)
    expect(model.documents.soul.sourceContent.value).toBe('Soul saved')
    expect(model.documents.soul.editing.value).toBeFalse()

    model.beginEdit('mission')
    model.setDraft('mission', 'Conflicting draft')
    model.setError('mission', 'Changed elsewhere', true)
    expect(model.snapshot('mission')).toMatchObject({
      content: 'Conflicting draft',
      expectedContentHash: 'mission:Mission A'
    })
    expect(model.documents.mission.conflict.value).toBeTrue()

    model.reload('mission', { kind: 'mission', content: 'Latest mission', content_hash: 'mission:latest' })
    expect(model.documents.mission.draft.value).toBe('Latest mission')
    expect(model.documents.mission.editing.value).toBeFalse()
    expect(model.documents.mission.conflict.value).toBeFalse()
    model[Symbol.dispose]()
  })

  test('applies a saved source without discarding edits made after submission', () => {
    const model = new AgentLibraryEditorModel()
    model.initialize('alpha', documents('Mission A', 'Soul A'))
    model.beginEdit('mission')
    model.setDraft('mission', 'Submitted mission')
    const submission = model.snapshot('mission')

    model.setDraft('mission', 'Newer unsaved mission')
    const result = model.markSaved(
      'mission',
      { kind: 'mission', content: 'Submitted mission', content_hash: 'mission:submitted' },
      submission
    )

    expect(result).toEqual({ hasUnsavedChanges: true })
    expect(model.documents.mission.sourceContent.value).toBe('Submitted mission')
    expect(model.documents.mission.contentHash.value).toBe('mission:submitted')
    expect(model.documents.mission.draft.value).toBe('Newer unsaved mission')
    expect(model.documents.mission.editing.value).toBeTrue()
    expect(model.snapshot('mission')).toMatchObject({
      content: 'Newer unsaved mission',
      expectedContentHash: 'mission:submitted'
    })
    model[Symbol.dispose]()
  })
})
