import { describe, expect, test } from 'bun:test'
import { AgentLibraryEditorModel, type AgentLibraryDocumentsSnapshot } from './agent-library-editor-model'

function documents(mission: string, soul: string, design = 'Design A'): AgentLibraryDocumentsSnapshot {
  return {
    mission: { kind: 'mission', content: mission, content_hash: `mission:${mission}` },
    soul: { kind: 'soul', content: soul, content_hash: `soul:${soul}` },
    design: { kind: 'design', content: design, content_hash: `design:${design}` },
    confidentiality_policy: {
      kind: 'confidentiality_policy',
      content: 'Policy A',
      content_hash: 'confidentiality_policy:Policy A'
    }
  }
}

describe('AgentLibraryEditorModel', () => {
  test('keeps the page dirty until every changed document is saved or discarded', () => {
    const model = new AgentLibraryEditorModel()
    model.initialize('agent:alpha', documents('Mission A', 'Soul A'))
    expect(model.dirty.value).toBeFalse()
    model.beginEdit('mission')
    expect(model.dirty.value).toBeFalse()
    model.setDraft('mission', 'Mission draft')
    model.beginEdit('confidentiality_policy')
    model.setDraft('confidentiality_policy', 'Policy draft')
    expect(model.dirty.value).toBeTrue()

    model.markSaved('mission', documents('Mission draft', 'Soul A').mission, model.snapshot('mission'))
    expect(model.dirty.value).toBeTrue()
    model.cancel('confidentiality_policy')
    expect(model.dirty.value).toBeFalse()

    model.beginEdit('design')
    model.setDraft('design', 'Design draft')
    expect(model.dirty.value).toBeTrue()
    model.initialize('agent:beta', documents('Mission B', 'Soul B'))
    expect(model.dirty.value).toBeFalse()
    model[Symbol.dispose]()
  })

  test('saves, cancels, and reloads one document without changing the other draft', async () => {
    const model = new AgentLibraryEditorModel()
    model.initialize('agent:alpha', documents('Mission A', 'Soul A'))
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

    await model.reload('mission', async () => ({
      kind: 'mission',
      content: 'Latest mission',
      content_hash: 'mission:latest'
    }))
    expect(model.documents.mission.draft.value).toBe('Latest mission')
    expect(model.documents.mission.editing.value).toBeFalse()
    expect(model.documents.mission.conflict.value).toBeFalse()
    model[Symbol.dispose]()
  })

  test('applies a saved source without discarding edits made after submission', () => {
    const model = new AgentLibraryEditorModel()
    model.initialize('agent:alpha', documents('Mission A', 'Soul A'))
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
    expect(model.dirty.value).toBeTrue()
    expect(model.snapshot('mission')).toMatchObject({
      content: 'Newer unsaved mission',
      expectedContentHash: 'mission:submitted'
    })
    model[Symbol.dispose]()
  })

  test('edits during a reload retain the draft, its CAS hash, and its conflict', async () => {
    const model = new AgentLibraryEditorModel()
    model.initialize('agent:alpha', documents('Mission A', 'Soul A'))
    model.beginEdit('mission')
    model.setDraft('mission', 'Conflicting draft')
    model.setError('mission', 'Changed elsewhere', true)
    const response = Promise.withResolvers<AgentLibraryDocumentsSnapshot['mission']>()
    const reload = model.reload('mission', () => response.promise)
    model.setDraft('mission', 'Newer draft')
    response.resolve(documents('Remote', 'Soul A').mission)
    await reload
    expect(model.documents.mission.draft.value).toBe('Newer draft')
    expect(model.documents.mission.contentHash.value).toBe('mission:Mission A')
    expect(model.documents.mission.conflict.value).toBeTrue()
    expect(model.documents.mission.editing.value).toBeTrue()
    expect(model.dirty.value).toBeTrue()
    model[Symbol.dispose]()
  })

  test('only the last reload can replace a draft, even when it finishes first', async () => {
    const model = new AgentLibraryEditorModel()
    model.initialize('agent:alpha', documents('Mission A', 'Soul A'))
    const first = Promise.withResolvers<AgentLibraryDocumentsSnapshot['mission']>()
    const pending = model.reload('mission', () => first.promise)
    await model.reload('mission', async () => documents('Newest', 'Soul A').mission)
    first.resolve(documents('Older', 'Soul A').mission)
    await pending
    expect(model.documents.mission.draft.value).toBe('Newest')
    expect(model.documents.mission.contentHash.value).toBe('mission:Newest')
    model[Symbol.dispose]()
  })

  test('closing and reopening the same source rejects old reload failures', async () => {
    const model = new AgentLibraryEditorModel()
    model.initialize('agent:alpha', documents('Mission A', 'Soul A'))
    const response = Promise.withResolvers<AgentLibraryDocumentsSnapshot['mission']>()
    const pending = model.reload('mission', () => response.promise)
    model.resetSource()
    model.initialize('agent:alpha', documents('Reopened', 'Soul A'))
    response.reject(new Error('Old read failed'))
    await pending
    expect(model.documents.mission.draft.value).toBe('Reopened')
    expect(model.documents.mission.error.value).toBeUndefined()
    model[Symbol.dispose]()
  })
})
