import { batch, createModel, signal } from '@preact/signals-react'

export const PROFILE_NAMES = ['primary', 'light', 'heavy', 'coding', 'embedding', 'rerank', 'web_search'] as const
export type ProfileName = (typeof PROFILE_NAMES)[number]

export type ProfileDraft = {
  codexAccountID: string
  providerID: string
  model: string
  contextLength: string
  providerOptions: Record<string, unknown>
  error?: string
}

type ProfileDraftInput = Partial<ProfileDraft>

export function emptyProfileDraft(): ProfileDraft {
  return {
    codexAccountID: '',
    providerID: '',
    model: '',
    contextLength: '',
    providerOptions: {},
    error: undefined
  }
}

export const ModelProfilesModel = createModel(() => {
  const sourceKey = signal<string>()
  const profiles = Object.fromEntries(PROFILE_NAMES.map(name => [name, createProfileSignals()])) as Record<
    ProfileName,
    ReturnType<typeof createProfileSignals>
  >

  function apply(name: ProfileName, input: ProfileDraftInput) {
    const draft = { ...emptyProfileDraft(), ...input }
    const profile = profiles[name]
    profile.codexAccountID.value = draft.codexAccountID
    profile.providerID.value = draft.providerID
    profile.model.value = draft.model
    profile.contextLength.value = draft.contextLength
    profile.providerOptions.value = draft.providerOptions
    profile.error.value = draft.error
  }

  return {
    sourceKey,
    profiles,
    initialize(nextSourceKey: string, drafts: Partial<Record<ProfileName, ProfileDraftInput>>) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        for (const name of PROFILE_NAMES) apply(name, drafts[name] ?? {})
      })
    },
    update(name: ProfileName, patch: ProfileDraftInput) {
      const profile = profiles[name]
      if (patch.codexAccountID !== undefined) profile.codexAccountID.value = patch.codexAccountID
      if (patch.providerID !== undefined) profile.providerID.value = patch.providerID
      if (patch.model !== undefined) profile.model.value = patch.model
      if (patch.contextLength !== undefined) profile.contextLength.value = patch.contextLength
      if (patch.providerOptions !== undefined) profile.providerOptions.value = patch.providerOptions
      if ('error' in patch) profile.error.value = patch.error
    },
    snapshot(name: ProfileName): ProfileDraft {
      const profile = profiles[name]
      return {
        codexAccountID: profile.codexAccountID.value,
        providerID: profile.providerID.value,
        model: profile.model.value,
        contextLength: profile.contextLength.value,
        providerOptions: profile.providerOptions.value,
        error: profile.error.value
      }
    },
    clear(name: ProfileName) {
      batch(() => apply(name, {}))
    }
  }
})

function createProfileSignals() {
  const initial = emptyProfileDraft()
  return {
    codexAccountID: signal(initial.codexAccountID),
    providerID: signal(initial.providerID),
    model: signal(initial.model),
    contextLength: signal(initial.contextLength),
    providerOptions: signal(initial.providerOptions),
    error: signal<string>()
  }
}
