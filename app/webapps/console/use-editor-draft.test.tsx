import { describe, expect, test } from 'bun:test'
import type { EditorDraftModel } from './use-editor-draft'
import { seedEditorDraft } from './use-editor-draft'

describe('useEditorDraft', () => {
  test('preserves the existing draft while the same selection loads or refetches', () => {
    const model = recordingModel()
    const sourceKey = 'opaque key / selected version 3'
    seedEditorDraft(model, sourceKey, 'cached', false)
    model.resetSource = () => {
      throw new Error('same-selection loading must retain the draft')
    }
    seedEditorDraft(model, sourceKey, undefined, false)
    seedEditorDraft(model, sourceKey, 'refetched', false)
    expect(model.initializations).toEqual([{ key: sourceKey, source: 'cached' }])
  })

  test('revokes a previous draft when the selected source is loading or absent', () => {
    for (const absent of [false, true]) {
      const model = recordingModel()
      let resets = 0
      model.resetSource = () => {
        resets += 1
        model.sourceKey.value = undefined
      }
      seedEditorDraft(model, 'tenant:A', 'A source', false)
      seedEditorDraft(model, 'global:B', undefined, absent)
      expect(resets).toBe(1)
      expect(model.sourceKey.value).toBeUndefined()
      expect(model.initializations).toEqual([{ key: 'tenant:A', source: 'A source' }])
      seedEditorDraft(model, 'global:B', undefined, absent)
      expect(resets).toBe(1)
    }
  })
})

function recordingModel() {
  const model: EditorDraftModel<string> & { initializations: Array<{ key: string; source: string }> } = {
    sourceKey: { value: undefined },
    initializations: [],
    initialize(key, source) {
      model.initializations.push({ key, source })
      model.sourceKey.value = key
    }
  }
  return model
}
