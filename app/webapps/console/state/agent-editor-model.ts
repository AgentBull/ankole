import { batch, computed, createModel, signal } from '@preact/signals-react'

// The transliteration table is ~0.5 MB, so it loads on demand: the editor
// preloads it on initialize, and UID derivation upgrades from the ASCII-only
// fallback as soon as the table lands.
type Transliterate = (value: string) => string

let transliterate: Transliterate | undefined
let transliterationLoading: Promise<void> | undefined

export function preloadTransliteration(): Promise<void> {
  transliterationLoading ??= import('any-ascii').then(module => {
    transliterate = module.default
  })
  return transliterationLoading
}

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
  return (transliterate?.(displayName) ?? displayName)
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
      void preloadTransliteration()
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
        if (deriveUID && !uidManuallyEdited) {
          uid.value = agentUIDFromDisplayName(value)
          // Before the table lands, non-Latin input derives an empty or
          // partial UID; re-derive from the current name once it loads.
          if (!transliterate) {
            void preloadTransliteration().then(() => {
              if (!uidManuallyEdited) uid.value = agentUIDFromDisplayName(displayName.value)
            })
          }
        }
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
