import { batch, computed, createModel, signal } from '@preact/signals-react'
import * as v from 'valibot'
import type { PrincipalCreateRequest, PrincipalUpdateRequest } from '../api/generated/types.gen'

export type PrincipalEditorDraft = {
  displayName: string
  email: string
}

/** Client-side draft problems, mapped to i18n text by the pages. */
export type PrincipalDraftError = 'display_name_required' | 'email_required' | 'email_invalid'

const emailSchema = v.pipe(v.string(), v.email())

/**
 * Shared draft for the create and edit pages of a local human user. An email
 * owned by an external identity is locked: the profile editor neither
 * validates nor submits it.
 */
export const PrincipalEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const displayName = signal('')
  const email = signal('')
  const emailLocked = signal(false)
  const mustChangePassword = signal(true)
  const initialDraft = signal<PrincipalEditorDraft>()
  const validationError = signal<string>()
  const dirty = computed(() => {
    const source = initialDraft.value
    return Boolean(source && (displayName.value !== source.displayName || email.value !== source.email))
  })

  return {
    sourceKey,
    displayName,
    email,
    emailLocked,
    mustChangePassword,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: PrincipalEditorDraft, options: { emailLocked?: boolean } = {}) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        displayName.value = draft.displayName
        email.value = draft.email
        emailLocked.value = options.emailLocked ?? false
        mustChangePassword.value = true
        initialDraft.value = { ...draft }
        validationError.value = undefined
      })
    },
    clearValidation() {
      validationError.value = undefined
    },
    draftError(): PrincipalDraftError | undefined {
      if (!displayName.value.trim()) return 'display_name_required'
      if (emailLocked.value) return undefined
      const trimmedEmail = email.value.trim()
      if (!trimmedEmail) return 'email_required'
      if (!v.is(emailSchema, trimmedEmail)) return 'email_invalid'
      return undefined
    },
    createBody(): PrincipalCreateRequest {
      return {
        display_name: displayName.value.trim(),
        email: email.value.trim(),
        must_change_password: mustChangePassword.value
      }
    },
    /** Sends only the fields the operator changed. */
    updateBody(): PrincipalUpdateRequest {
      const source = initialDraft.value
      const body: PrincipalUpdateRequest = {}
      if (!source || displayName.value !== source.displayName) body.display_name = displayName.value.trim()
      if (!emailLocked.value && (!source || email.value !== source.email)) body.email = email.value.trim()
      return body
    }
  }
})
