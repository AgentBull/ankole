import { batch, createModel, signal } from '@preact/signals-react'
import type { PermissionGrantCreateRequest, PermissionGrantUpdateRequest } from '../api/generated/types.gen'

export type PermissionGrantEditorDraft = {
  resourcePattern: string
  action: string
  condition: string
  description: string
}

/** Exactly one owner per grant: a principal uid XOR a group name. */
export type PermissionGrantOwner = { principalUID: string } | { groupName: string }

/** Client-side draft problems, reported as i18n key suffixes under `console.permission_grants`. */
export type PermissionGrantDraftError = 'resource_pattern_required' | 'action_required' | 'action_no_colon'

export const PermissionGrantEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const resourcePattern = signal('')
  const action = signal('')
  const condition = signal('true')
  const description = signal('')
  const validationError = signal<string>()

  return {
    sourceKey,
    resourcePattern,
    action,
    condition,
    description,
    validationError,
    initialize(nextSourceKey: string, draft: PermissionGrantEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        resourcePattern.value = draft.resourcePattern
        action.value = draft.action
        condition.value = draft.condition
        description.value = draft.description
        validationError.value = undefined
      })
    },
    clearValidation() {
      validationError.value = undefined
    },
    draftError(): PermissionGrantDraftError | undefined {
      if (!resourcePattern.value.trim()) return 'resource_pattern_required'
      const trimmedAction = action.value.trim()
      if (!trimmedAction) return 'action_required'
      if (trimmedAction.includes(':')) return 'action_no_colon'
      return undefined
    },
    createBody(owner: PermissionGrantOwner): PermissionGrantCreateRequest {
      return {
        ...('principalUID' in owner ? { principal_uid: owner.principalUID } : { group_name: owner.groupName }),
        resource_pattern: resourcePattern.value.trim(),
        action: action.value.trim(),
        condition: condition.value.trim() || 'true',
        description: description.value.trim() || null
      }
    },
    updateBody(): PermissionGrantUpdateRequest {
      return {
        resource_pattern: resourcePattern.value.trim(),
        action: action.value.trim(),
        condition: condition.value.trim() || 'true',
        description: description.value.trim() || null
      }
    }
  }
})
