import { batch, computed, createModel, signal } from '@preact/signals-react'
import { pinyin } from 'pinyin-pro'

export type AgentEditorDraft = {
  uid: string
  displayName: string
  avatarURL: string
  role: string
}

export type AgentEditorDraftError = 'display_name_required' | 'uid_invalid' | 'uid_required' | 'role_required'

const agentUIDPattern = /^[a-z0-9][a-z0-9._-]{0,95}$/

export function agentUIDError(uid: string): Extract<AgentEditorDraftError, 'uid_invalid' | 'uid_required'> | undefined {
  const normalizedUID = uid.trim()
  if (!normalizedUID) return 'uid_required'
  if (!agentUIDPattern.test(normalizedUID)) return 'uid_invalid'
  return undefined
}

export function agentUIDFromDisplayName(displayName: string): string {
  return pinyin(displayName, { nonZh: 'consecutive', separator: '-', toneType: 'none' })
    .normalize('NFKD')
    .replace(/\p{M}/gu, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 96)
    .replace(/-+$/g, '')
}

export const AgentEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const uid = signal('')
  const displayName = signal('')
  const avatarURL = signal('')
  const role = signal('')
  const initialDraft = signal<AgentEditorDraft>()
  const validationError = signal<AgentEditorDraftError>()
  const dirty = computed(() => {
    const initial = initialDraft.value
    return Boolean(
      initial &&
      (uid.value !== initial.uid ||
        displayName.value !== initial.displayName ||
        avatarURL.value !== initial.avatarURL ||
        role.value !== initial.role)
    )
  })
  let uidManuallyEdited = false

  return {
    sourceKey,
    uid,
    displayName,
    avatarURL,
    role,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: AgentEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        uid.value = draft.uid
        displayName.value = draft.displayName
        avatarURL.value = draft.avatarURL
        role.value = draft.role
        initialDraft.value = { ...draft }
        validationError.value = undefined
        uidManuallyEdited = false
      })
    },
    clearValidation() {
      validationError.value = undefined
    },
    markSaved(draft?: AgentEditorDraft) {
      initialDraft.value = draft
        ? { ...draft }
        : { uid: uid.value, displayName: displayName.value, avatarURL: avatarURL.value, role: role.value }
    },
    setDisplayName(value: string, deriveUID: boolean) {
      batch(() => {
        displayName.value = value
        if (deriveUID && !uidManuallyEdited) uid.value = agentUIDFromDisplayName(value)
        if (
          validationError.value === 'display_name_required' ||
          validationError.value === 'uid_required' ||
          validationError.value === 'uid_invalid'
        ) {
          validationError.value = undefined
        }
      })
    },
    setUID(value: string) {
      uidManuallyEdited = true
      uid.value = value.toLowerCase()
      if (validationError.value === 'uid_required' || validationError.value === 'uid_invalid') {
        validationError.value = undefined
      }
    },
    draftError(mode: 'new' | 'edit'): AgentEditorDraftError | undefined {
      if (!displayName.value.trim()) return 'display_name_required'
      if (mode === 'new') {
        const uidError = agentUIDError(uid.value)
        if (uidError) return uidError
      }
      if (!role.value.trim()) return 'role_required'
      return undefined
    }
  }
})
