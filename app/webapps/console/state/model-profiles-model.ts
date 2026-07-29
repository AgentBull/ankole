import { batch, createModel, signal } from '@preact/signals-react'

export const PROFILE_NAMES = [
  'primary',
  'light',
  'heavy',
  'coding',
  'vision_fallback',
  'embedding',
  'rerank',
  'web_search',
  'web_fetch',
  'image_generate'
] as const
export type ProfileName = (typeof PROFILE_NAMES)[number]

export type ProfileDraft = {
  providerID: string
  model: string
  contextLength: string
  providerOptions: Record<string, unknown>
  error?: string
}

type ProfileDraftInput = Partial<ProfileDraft>

export type ModelProfileSubmission = {
  draft: ProfileDraft
  revision: number
}

export type ModelProfilePersistenceResult = {
  hasUnsavedChanges: boolean
}

export function emptyProfileDraft(): ProfileDraft {
  return {
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
    const draft = normalizedProfileDraft(input)
    const profile = profiles[name]
    profile.source.value = draft
    writeProfileDraft(profile, draft)
    profile.dirty.value = false
    profile.revision.value += 1
  }

  function read(name: ProfileName): ProfileDraft {
    const profile = profiles[name]
    return {
      providerID: profile.providerID.value,
      model: profile.model.value,
      contextLength: profile.contextLength.value,
      providerOptions: profile.providerOptions.value,
      error: profile.error.value
    }
  }

  return {
    sourceKey,
    profiles,
    initialize(nextSourceKey: string, drafts: Partial<Record<ProfileName, ProfileDraftInput>>) {
      batch(() => {
        const sameSource = sourceKey.value === nextSourceKey
        if (!sameSource) sourceKey.value = nextSourceKey

        for (const name of PROFILE_NAMES) {
          if (!sameSource || !profiles[name].dirty.value) apply(name, drafts[name] ?? {})
        }
      })
    },
    update(name: ProfileName, patch: ProfileDraftInput) {
      const profile = profiles[name]
      const current = read(name)
      const next = { ...current, ...patch }
      const valuesChanged = !sameProfileValues(current, next)

      batch(() => {
        writeProfileDraft(profile, next)
        if (valuesChanged) profile.revision.value += 1
        profile.dirty.value = !sameProfileValues(next, profile.source.value)
      })
    },
    snapshot(name: ProfileName): ProfileDraft {
      return read(name)
    },
    submission(name: ProfileName): ModelProfileSubmission {
      return { draft: read(name), revision: profiles[name].revision.value }
    },
    markSaved(
      name: ProfileName,
      input: ProfileDraftInput,
      submission: ModelProfileSubmission
    ): ModelProfilePersistenceResult {
      const profile = profiles[name]
      const saved = normalizedProfileDraft(input)
      const current = read(name)
      const hasUnsavedChanges = profile.revision.value !== submission.revision && !sameProfileValues(current, saved)

      batch(() => {
        profile.source.value = saved
        profile.revision.value += 1

        if (hasUnsavedChanges) {
          profile.dirty.value = true
          return
        }

        writeProfileDraft(profile, saved)
        profile.dirty.value = false
      })

      return { hasUnsavedChanges }
    },
    clear(name: ProfileName) {
      batch(() => apply(name, {}))
    }
  }
})

function createProfileSignals() {
  const initial = emptyProfileDraft()
  return {
    source: signal(initial),
    providerID: signal(initial.providerID),
    model: signal(initial.model),
    contextLength: signal(initial.contextLength),
    providerOptions: signal(initial.providerOptions),
    error: signal<string>(),
    dirty: signal(false),
    revision: signal(0)
  }
}

function normalizedProfileDraft(input: ProfileDraftInput): ProfileDraft {
  return { ...emptyProfileDraft(), ...input, error: input.error }
}

function writeProfileDraft(profile: ReturnType<typeof createProfileSignals>, draft: ProfileDraft) {
  profile.providerID.value = draft.providerID
  profile.model.value = draft.model
  profile.contextLength.value = draft.contextLength
  profile.providerOptions.value = draft.providerOptions
  profile.error.value = draft.error
}

function sameProfileValues(left: ProfileDraft, right: ProfileDraft): boolean {
  return (
    left.providerID === right.providerID &&
    left.model === right.model &&
    left.contextLength === right.contextLength &&
    JSON.stringify(left.providerOptions) === JSON.stringify(right.providerOptions)
  )
}
