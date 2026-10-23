import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { CreatePrincipalGroupData, UpdatePrincipalGroupData } from '../api/v2/generated/types.gen'

type PrincipalGroupCreateRequest = NonNullable<CreatePrincipalGroupData['body']['data']['attributes']>
type PrincipalGroupUpdateRequest = NonNullable<NonNullable<UpdatePrincipalGroupData['body']>['data']['attributes']>

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
  let generation = Symbol()
  const sourceKey = signal<string>()
  const name = signal('')
  const displayName = signal('')
  const description = signal('')
  const kind = signal<PrincipalGroupKind>('static')
  const computedCondition = signal('')
  const initialDraft = signal<PrincipalGroupEditorDraft>()
  const validationError = signal<string>()
  const dirty = computed(() => {
    const source = initialDraft.value
    return Boolean(
      source &&
      (name.value !== source.name ||
        displayName.value !== source.displayName ||
        description.value !== source.description ||
        kind.value !== source.kind ||
        computedCondition.value !== source.computedCondition)
    )
  })

  return {
    resetSource() {
      generation = Symbol()
      sourceKey.value = undefined
    },
    sourceKey,
    name,
    displayName,
    description,
    kind,
    computedCondition,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: PrincipalGroupEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      generation = Symbol()
      batch(() => {
        sourceKey.value = nextSourceKey
        name.value = draft.name
        displayName.value = draft.displayName
        description.value = draft.description
        kind.value = draft.kind
        computedCondition.value = draft.computedCondition
        initialDraft.value = { ...draft }
        validationError.value = undefined
      })
    },
    clearValidation() {
      validationError.value = undefined
    },
    /** Confirms the submitted fields and keeps edits made while saving. */
    captureSave() {
      const requestedGeneration = generation
      const submittedValidation = validationError.value
      const submitted = {
        name: name.value,
        displayName: displayName.value,
        description: description.value,
        kind: kind.value,
        computedCondition: computedCondition.value
      }
      return (accepted: PrincipalGroupEditorDraft) => {
        if (generation !== requestedGeneration) return false
        batch(() => {
          if (JSON.stringify(name.value) === JSON.stringify(submitted.name)) name.value = accepted.name
          if (JSON.stringify(displayName.value) === JSON.stringify(submitted.displayName)) {
            displayName.value = accepted.displayName
          }
          if (JSON.stringify(description.value) === JSON.stringify(submitted.description)) {
            description.value = accepted.description
          }
          if (JSON.stringify(kind.value) === JSON.stringify(submitted.kind)) kind.value = accepted.kind
          if (JSON.stringify(computedCondition.value) === JSON.stringify(submitted.computedCondition)) {
            computedCondition.value = accepted.computedCondition
          }
          initialDraft.value = { ...accepted }
          if (validationError.value === submittedValidation) validationError.value = undefined
        })
        return true
      }
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
