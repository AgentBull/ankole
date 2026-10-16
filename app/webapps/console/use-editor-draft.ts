import { useLayoutEffect } from 'react'

export type EditorDraftStatus = 'loading' | 'absent' | 'ready'

export type EditorDraftModel<Source> = {
  sourceKey: { value: string | undefined }
  initialize: (sourceKey: string, source: Source) => void
  resetSource?: () => void
}

export function useEditorDraft<Source>(
  model: EditorDraftModel<Source>,
  {
    sourceKey,
    source,
    absent
  }: {
    sourceKey: string
    source: Source | undefined
    absent?: () => boolean
  }
): EditorDraftStatus {
  const isAbsent = absent?.() ?? false

  useLayoutEffect(() => () => model.resetSource?.(), [model])

  useLayoutEffect(() => {
    seedEditorDraft(model, sourceKey, source, isAbsent)
  }, [isAbsent, model, source, sourceKey])

  if (isAbsent) return 'absent'
  if (source === undefined || model.sourceKey.value !== sourceKey) return 'loading'
  return 'ready'
}

export function seedEditorDraft<Source>(
  model: EditorDraftModel<Source>,
  sourceKey: string,
  source: Source | undefined,
  absent: boolean
): void {
  // Selection changes revoke old request captures before the next source loads.
  if (model.sourceKey.value !== undefined && (absent || model.sourceKey.value !== sourceKey)) {
    model.resetSource?.()
  }
  if (absent || source === undefined || model.sourceKey.value === sourceKey) return
  model.initialize(sourceKey, source)
}
