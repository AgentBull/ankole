import { batch, computed, createModel, signal } from '@preact/signals-react'

// Slug editors load the transliteration table on demand.
type Transliterate = (value: string) => string

let transliterate: Transliterate | undefined
let transliterationLoading: Promise<void> | undefined

export function preloadTransliteration(): Promise<void> {
  transliterationLoading ??= import('any-ascii').then(module => {
    transliterate = module.default
  })
  return transliterationLoading
}

export type AgentMemoryDisclosureMode = 'strict' | 'relaxed'

export type AgentEditorDraft = {
  uid: string
  displayName: string
  avatarURL: string
  role: string
  ownerPrincipalUID: string
  workerProviderID: string
  groupMemoryDisclosureMode: AgentMemoryDisclosureMode
}

export type AgentEditorDraftError =
  | 'display_name_required'
  | 'uid_invalid'
  | 'uid_required'
  | 'role_required'
  | 'owner_required'
  | 'worker_provider_required'

// Shared with the editor's `pattern` attribute, so the browser reports the
// same rule the model enforces. HTML patterns imply the ^…$ anchors and
// compile with the `v` flag, which requires the escaped hyphen in the class.
export const agentUIDInputPattern = '[a-z0-9][a-z0-9._@+\\-]{0,95}'
const agentUIDPattern = new RegExp(`^(?:${agentUIDInputPattern})$`)

export function agentUIDError(uid: string): Extract<AgentEditorDraftError, 'uid_invalid' | 'uid_required'> | undefined {
  const normalizedUID = uid.trim()
  if (!normalizedUID) return 'uid_required'
  if (!agentUIDPattern.test(normalizedUID)) return 'uid_invalid'
  return undefined
}

export function slugFromDisplayName(displayName: string, maxLength = 63): string {
  return (transliterate?.(displayName) ?? displayName)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, maxLength)
    .replace(/-+$/g, '')
}

export function deriveSlugWithTransliteration(
  displayName: string,
  maxLength: number,
  onTransliterated: () => void
): string {
  const initial = slugFromDisplayName(displayName, maxLength)
  if (!transliterate) {
    void preloadTransliteration().then(onTransliterated)
  }
  return initial
}

export const AgentEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const uid = signal('')
  const displayName = signal('')
  const avatarURL = signal('')
  const role = signal('')
  const ownerPrincipalUID = signal('')
  const workerProviderID = signal('')
  const groupMemoryDisclosureMode = signal<AgentMemoryDisclosureMode>('strict')
  const initialDraft = signal<AgentEditorDraft>()
  const validationError = signal<AgentEditorDraftError>()
  const dirty = computed(() => {
    const initial = initialDraft.value
    return Boolean(
      initial &&
      (uid.value !== initial.uid ||
        displayName.value !== initial.displayName ||
        avatarURL.value !== initial.avatarURL ||
        role.value !== initial.role ||
        ownerPrincipalUID.value !== initial.ownerPrincipalUID ||
        workerProviderID.value !== initial.workerProviderID ||
        groupMemoryDisclosureMode.value !== initial.groupMemoryDisclosureMode)
    )
  })

  return {
    sourceKey,
    uid,
    displayName,
    avatarURL,
    role,
    ownerPrincipalUID,
    workerProviderID,
    groupMemoryDisclosureMode,
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
        ownerPrincipalUID.value = draft.ownerPrincipalUID
        workerProviderID.value = draft.workerProviderID
        groupMemoryDisclosureMode.value = draft.groupMemoryDisclosureMode
        initialDraft.value = { ...draft }
        validationError.value = undefined
      })
    },
    clearValidation() {
      validationError.value = undefined
    },
    markSaved(draft?: AgentEditorDraft) {
      initialDraft.value = draft
        ? { ...draft }
        : {
            uid: uid.value,
            displayName: displayName.value,
            avatarURL: avatarURL.value,
            role: role.value,
            ownerPrincipalUID: ownerPrincipalUID.value,
            workerProviderID: workerProviderID.value,
            groupMemoryDisclosureMode: groupMemoryDisclosureMode.value
          }
    },
    setDisplayName(value: string) {
      displayName.value = value
      if (validationError.value === 'display_name_required') validationError.value = undefined
    },
    setUID(value: string) {
      uid.value = value.toLowerCase()
      if (validationError.value === 'uid_required' || validationError.value === 'uid_invalid') {
        validationError.value = undefined
      }
    },
    draftError(mode: 'new' | 'edit'): AgentEditorDraftError | undefined {
      if (!displayName.value.trim()) return 'display_name_required'
      const uidError = agentUIDError(uid.value)
      if (uidError) return uidError
      if (!role.value.trim()) return 'role_required'
      if (!ownerPrincipalUID.value.trim()) return 'owner_required'
      if (mode === 'new' && !workerProviderID.value) return 'worker_provider_required'
      return undefined
    }
  }
})
