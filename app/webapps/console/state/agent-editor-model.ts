import { batch, computed, createModel, signal } from '@preact/signals-react'

// The transliteration table is ~0.5 MB, so it loads on demand: the editor
// preloads it on initialize, and handle derivation upgrades from the ASCII-only
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

export type AgentMemoryDisclosureMode = 'strict' | 'relaxed'

export type AgentEditorDraft = {
  handle: string
  displayName: string
  avatarURL: string
  role: string
  ownerPrincipalUID: string
  workerProviderID: string
  groupMemoryDisclosureMode: AgentMemoryDisclosureMode
}

export type AgentEditorDraftError =
  | 'display_name_required'
  | 'handle_invalid'
  | 'handle_required'
  | 'role_required'
  | 'owner_required'
  | 'worker_provider_required'

// Shared with the editor's `pattern` attribute, so the browser reports the
// same rule the model enforces. HTML patterns imply the ^…$ anchors and
// compile with the `v` flag, which requires the escaped hyphen in the class.
export const agentHandleInputPattern = '[a-z0-9][a-z0-9._\\-]{0,95}'
const agentHandlePattern = new RegExp(`^(?:${agentHandleInputPattern})$`)

export function agentHandleError(
  handle: string
): Extract<AgentEditorDraftError, 'handle_invalid' | 'handle_required'> | undefined {
  const normalizedHandle = handle.trim()
  if (!normalizedHandle) return 'handle_required'
  if (!agentHandlePattern.test(normalizedHandle)) return 'handle_invalid'
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

export function agentHandleFromDisplayName(displayName: string): string {
  return slugFromDisplayName(displayName, 96)
}

export const AgentEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const handle = signal('')
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
      (handle.value !== initial.handle ||
        displayName.value !== initial.displayName ||
        avatarURL.value !== initial.avatarURL ||
        role.value !== initial.role ||
        ownerPrincipalUID.value !== initial.ownerPrincipalUID ||
        workerProviderID.value !== initial.workerProviderID ||
        groupMemoryDisclosureMode.value !== initial.groupMemoryDisclosureMode)
    )
  })
  let handleManuallyEdited = false

  return {
    sourceKey,
    handle,
    displayName,
    avatarURL,
    role,
    ownerPrincipalUID,
    workerProviderID,
    groupMemoryDisclosureMode,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: AgentEditorDraft) {
      void preloadTransliteration()
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        handle.value = draft.handle
        displayName.value = draft.displayName
        avatarURL.value = draft.avatarURL
        role.value = draft.role
        ownerPrincipalUID.value = draft.ownerPrincipalUID
        workerProviderID.value = draft.workerProviderID
        groupMemoryDisclosureMode.value = draft.groupMemoryDisclosureMode
        initialDraft.value = { ...draft }
        validationError.value = undefined
        handleManuallyEdited = false
      })
    },
    clearValidation() {
      validationError.value = undefined
    },
    markSaved(draft?: AgentEditorDraft) {
      initialDraft.value = draft
        ? { ...draft }
        : {
            handle: handle.value,
            displayName: displayName.value,
            avatarURL: avatarURL.value,
            role: role.value,
            ownerPrincipalUID: ownerPrincipalUID.value,
            workerProviderID: workerProviderID.value,
            groupMemoryDisclosureMode: groupMemoryDisclosureMode.value
          }
    },
    setDisplayName(value: string, deriveHandle: boolean) {
      batch(() => {
        displayName.value = value
        if (deriveHandle && !handleManuallyEdited) {
          handle.value = agentHandleFromDisplayName(value)
          // Before the table lands, non-Latin input derives an empty or
          // partial handle; re-derive from the current name once it loads.
          if (!transliterate) {
            void preloadTransliteration().then(() => {
              if (!handleManuallyEdited) handle.value = agentHandleFromDisplayName(displayName.value)
            })
          }
        }
        if (
          validationError.value === 'display_name_required' ||
          validationError.value === 'handle_required' ||
          validationError.value === 'handle_invalid'
        ) {
          validationError.value = undefined
        }
      })
    },
    setHandle(value: string) {
      handleManuallyEdited = true
      handle.value = value.toLowerCase()
      if (validationError.value === 'handle_required' || validationError.value === 'handle_invalid') {
        validationError.value = undefined
      }
    },
    draftError(mode: 'new' | 'edit'): AgentEditorDraftError | undefined {
      if (!displayName.value.trim()) return 'display_name_required'
      const handleError = agentHandleError(handle.value)
      if (handleError) return handleError
      if (!role.value.trim()) return 'role_required'
      if (!ownerPrincipalUID.value.trim()) return 'owner_required'
      if (mode === 'new' && !workerProviderID.value) return 'worker_provider_required'
      return undefined
    }
  }
})
