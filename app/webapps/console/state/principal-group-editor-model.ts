import { batch, createModel, signal } from '@preact/signals-react'
import type { PrincipalGroupCreateRequest, PrincipalGroupUpdateRequest } from '../api/generated/types.gen'

export type PrincipalGroupKind = 'static' | 'computed'

export type PrincipalGroupEditorDraft = {
  name: string
  displayName: string
  description: string
  kind: PrincipalGroupKind
  computedCondition: string
}

/** Client-side draft problems, reported as i18n key suffixes under `console.principal_groups`. */
export type PrincipalGroupDraftError =
  | 'name_required'
  | 'name_lowercase'
  | 'display_name_required'
  | 'condition_required'

export const PrincipalGroupEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const name = signal('')
  const displayName = signal('')
  const description = signal('')
  const kind = signal<PrincipalGroupKind>('static')
  const computedCondition = signal('')
  const validationError = signal<string>()

  return {
    sourceKey,
    name,
    displayName,
    description,
    kind,
    computedCondition,
    validationError,
    initialize(nextSourceKey: string, draft: PrincipalGroupEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        name.value = draft.name
        displayName.value = draft.displayName
        description.value = draft.description
        kind.value = draft.kind
        computedCondition.value = draft.computedCondition
        validationError.value = undefined
      })
    },
    clearValidation() {
      validationError.value = undefined
    },
    draftError(mode: 'new' | 'edit'): PrincipalGroupDraftError | undefined {
      if (mode === 'new') {
        const trimmedName = name.value.trim()
        if (!trimmedName) return 'name_required'
        if (trimmedName !== trimmedName.toLowerCase()) return 'name_lowercase'
      }
      if (!displayName.value.trim()) return 'display_name_required'
      if (kind.value === 'computed' && !computedCondition.value.trim()) return 'condition_required'
      return undefined
    },
    createBody(): PrincipalGroupCreateRequest {
      return {
        name: name.value.trim(),
        display_name: displayName.value.trim(),
        description: description.value.trim() || null,
        kind: kind.value,
        computed_condition: kind.value === 'computed' ? computedCondition.value.trim() : null
      }
    },
    updateBody(): PrincipalGroupUpdateRequest {
      return {
        display_name: displayName.value.trim(),
        description: description.value.trim() || null,
        computed_condition: kind.value === 'computed' ? computedCondition.value.trim() : null
      }
    }
  }
})
