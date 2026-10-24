import { batch, computed, createModel, signal } from '@preact/signals-react'
import { z } from 'zod'
import type { CreateMemberData, UpdateHumanData } from '../api/v2/generated/types.gen'

type PrincipalCreateRequest = CreateMemberData['body']['data']
type PrincipalUpdateRequest = NonNullable<NonNullable<UpdateHumanData['body']>['data']['attributes']>

export type PrincipalEditorDraft = {
  displayName: string
  email: string
  membership?: 'member' | 'guest'
}

/** Client-side draft problems; the pages translate the code at render. */
export type PrincipalDraftError = 'display_name_required' | 'email_invalid'

const emailSchema = z.email()

/** Shared draft for the create and edit pages of a Pod human member. */
export const PrincipalEditorModel = createModel(() => {
  let source = Symbol()
  const sourceKey = signal<string>()
  const displayName = signal('')
  const email = signal('')
  const membership = signal<'member' | 'guest'>('member')
  const initialDraft = signal<PrincipalEditorDraft>()
  const validationError = signal<PrincipalDraftError>()
  const dirty = computed(() => {
    const source = initialDraft.value
    return Boolean(
      source &&
      (displayName.value !== source.displayName ||
        email.value !== source.email ||
        membership.value !== (source.membership ?? 'member'))
    )
  })

  return {
    sourceKey,
    displayName,
    email,
    membership,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: PrincipalEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      source = Symbol()
      batch(() => {
        sourceKey.value = nextSourceKey
        displayName.value = draft.displayName
        email.value = draft.email
        membership.value = draft.membership ?? 'member'
        initialDraft.value = { ...draft }
        validationError.value = undefined
      })
    },
    async save(request: () => Promise<unknown>, onSaved: (clean: boolean) => void) {
      const requestedSource = source
      const sentDraft = { displayName: displayName.value, email: email.value, membership: membership.value }
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
    createBody(): PrincipalCreateRequest {
      return {
        display_name: displayName.value.trim(),
        email: email.value.trim(),
        membership: membership.value
      }
    },
    /** Sends only the fields the operator changed. */
    updateBody(): PrincipalUpdateRequest {
      const source = initialDraft.value
      const body: PrincipalUpdateRequest = {}
      if (!source || displayName.value !== source.displayName) body.display_name = displayName.value.trim()
      if (!source || email.value !== source.email) body.email = email.value.trim()
      return body
    }
  }
})
