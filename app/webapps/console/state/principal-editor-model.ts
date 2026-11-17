import { batch, computed, createModel, signal } from '@preact/signals-react'
import { z } from 'zod'
import { requestErrorCode, requestErrorDetailList } from '../../common/request-errors'
import type { UpdateHumanData } from '../api/v2/generated/types.gen'

type PrincipalUpdateRequest = NonNullable<NonNullable<UpdateHumanData['body']>['data']['attributes']>

type PrincipalEditorDraft = {
  displayName: string
  email: string
}

/** Client-side draft problems; the edit page translates the code at render. */
type PrincipalDraftError = 'display_name_required' | 'email_invalid'

type Translate = {
  (key: string): string
  (key: string, values: Record<string, unknown>): string
}

const emailSchema = z.email()

export function principalDraftErrorText(error: PrincipalDraftError, t: Translate): string {
  switch (error) {
    case 'display_name_required':
      return t('common.field_required', { field: t('console.principals.display_name') })
    case 'email_invalid':
      return t('common.email_invalid')
  }
}

/** Localizes the write-endpoint failures this page can trigger: a taken email is a field error. */
export function principalRequestError(error: unknown, t: Translate): unknown {
  const code = requestErrorCode(error)
  const emailTaken =
    code === 'email_taken' ||
    requestErrorDetailList(error).some(
      detail =>
        detail.code === 'email_taken' ||
        (detail.path === 'email' &&
          (detail.code === 'taken' ||
            detail.kind === 'taken' ||
            (typeof detail.message === 'string' && detail.message.includes('taken'))))
    )
  return emailTaken ? t('console.principals.email_taken') : (error ?? undefined)
}

/** Draft model for editing a human Principal's profile in Site Console. */
function createPrincipalEditor() {
  let source = Symbol()
  const sourceKey = signal<string>()
  const displayName = signal('')
  const email = signal('')
  const initialDraft = signal<PrincipalEditorDraft>()
  const validationError = signal<PrincipalDraftError>()
  const dirty = computed(() => {
    const currentSource = initialDraft.value
    return Boolean(
      currentSource && (displayName.value !== currentSource.displayName || email.value !== currentSource.email)
    )
  })

  return {
    sourceKey,
    displayName,
    email,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: PrincipalEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      source = Symbol()
      batch(() => {
        sourceKey.value = nextSourceKey
        displayName.value = draft.displayName
        email.value = draft.email
        initialDraft.value = { ...draft }
        validationError.value = undefined
      })
    },
    async save(request: () => Promise<unknown>, onSaved: (clean: boolean) => void) {
      const requestedSource = source
      const sentDraft = { displayName: displayName.value, email: email.value }
      await request()
      if (source !== requestedSource) return
      initialDraft.value = sentDraft
      onSaved(!dirty.peek())
    },
    resetSource() {
      source = Symbol()
      sourceKey.value = undefined
    },
    clearValidation() {
      validationError.value = undefined
    },
    draftError(): PrincipalDraftError | undefined {
      if (!displayName.value.trim()) return 'display_name_required'
      const trimmedEmail = email.value.trim()
      if (!trimmedEmail) return undefined
      if (!emailSchema.safeParse(trimmedEmail).success) return 'email_invalid'
      return undefined
    },
    /** Sends only the fields the operator changed. */
    updateBody(): PrincipalUpdateRequest {
      const currentSource = initialDraft.value
      const body: PrincipalUpdateRequest = {}
      if (!currentSource || displayName.value !== currentSource.displayName) {
        body.display_name = displayName.value.trim()
      }
      if (!currentSource || email.value !== currentSource.email) {
        body.email = email.value.trim()
      }
      return body
    }
  }
}

export const PrincipalEditorModel = createModel(createPrincipalEditor)
