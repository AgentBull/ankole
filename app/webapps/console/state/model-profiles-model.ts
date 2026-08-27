import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import { batch, createModel, signal } from '@preact/signals-react'

// Embedding and rerank are not Agent profile slots: Brain owns those models
// instance-wide through the brain.* settings.
export const PROFILE_NAMES = [
  'primary',
  'light',
  'heavy',
  'coding',
  'vision_fallback',
  'web_search',
  'web_fetch',
  'image_generate'
] as const
export type ProfileName = (typeof PROFILE_NAMES)[number]

export type ProfileDraft = {
  description: string
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
    description: '',
    providerID: '',
    model: '',
    contextLength: '',
    providerOptions: {},
    error: undefined
  }
}

/** Converts one persisted model-profile object into the editor draft shape. */
export function draftFromProfile(profile: JSONObject): ProfileDraft {
  return {
    description: stringValue(profile.description),
    providerID: stringValue(profile.provider_id),
    model: stringValue(profile.model),
    contextLength: profile.context_length ? String(profile.context_length) : '',
    providerOptions: recordValue(profile.provider_options) ?? {}
  }
}

export const ModelProfilesModel = createModel(() => {
  const sourceKey = signal<string>()
  const profiles = Object.fromEntries(PROFILE_NAMES.map(name => [name, createProfileSignals()])) as Record<
    ProfileName,
    ProfileSignals
  >

  return {
    sourceKey,
    profiles,
    initialize(nextSourceKey: string, drafts: Partial<Record<ProfileName, ProfileDraftInput>>) {
      batch(() => {
        const sameSource = sourceKey.value === nextSourceKey
        if (!sameSource) sourceKey.value = nextSourceKey

        for (const name of PROFILE_NAMES) {
          if (!sameSource || !profiles[name].dirty.value) applyProfile(profiles[name], drafts[name] ?? {})
        }
      })
    },
    update(name: ProfileName, patch: ProfileDraftInput) {
      updateProfile(profiles[name], patch)
    },
    snapshot(name: ProfileName): ProfileDraft {
      return readProfile(profiles[name])
    },
    submission(name: ProfileName): ModelProfileSubmission {
      return profileSubmission(profiles[name])
    },
    markSaved(
      name: ProfileName,
      input: ProfileDraftInput,
      submission: ModelProfileSubmission
    ): ModelProfilePersistenceResult {
      return markProfileSaved(profiles[name], input, submission)
    },
    clear(name: ProfileName) {
      const profile = profiles[name]
      const empty = emptyProfileDraft()

      batch(() => {
        writeProfileDraft(profile, empty)
        profile.revision.value += 1
        profile.dirty.value = !sameProfileValues(empty, profile.source.value)
      })
    }
  }
})

/** One stored custom profile draft under the same preserve-dirty policy as the fixed profiles. */
export const CustomModelProfileModel = createModel(() => {
  const sourceKey = signal<string>()
  const profile = createProfileSignals()

  return {
    sourceKey,
    profile,
    initialize(nextSourceKey: string, input: ProfileDraftInput) {
      batch(() => {
        const sameSource = sourceKey.value === nextSourceKey
        if (!sameSource) sourceKey.value = nextSourceKey
        if (!sameSource || !profile.dirty.value) applyProfile(profile, input)
      })
    },
    update(patch: ProfileDraftInput) {
      updateProfile(profile, patch)
    },
    snapshot(): ProfileDraft {
      return readProfile(profile)
    },
    submission(): ModelProfileSubmission {
      return profileSubmission(profile)
    },
    markSaved(input: ProfileDraftInput, submission: ModelProfileSubmission): ModelProfilePersistenceResult {
      return markProfileSaved(profile, input, submission)
    }
  }
})

type ProfileSignals = ReturnType<typeof createProfileSignals>

function createProfileSignals() {
  const initial = emptyProfileDraft()
  return {
    source: signal(initial),
    description: signal(initial.description),
    providerID: signal(initial.providerID),
    model: signal(initial.model),
    contextLength: signal(initial.contextLength),
    providerOptions: signal(initial.providerOptions),
    error: signal<string>(),
    dirty: signal(false),
    revision: signal(0)
  }
}

function applyProfile(profile: ProfileSignals, input: ProfileDraftInput) {
  const draft = normalizedProfileDraft(input)
  // A refetch that restates the current values must not advance the revision:
  // markSaved compares revisions to detect edits made during a save, so a
  // background restatement would fake an "unsaved changes" result.
  if (sameProfileValues(draft, profile.source.value) && sameProfileValues(draft, readProfile(profile))) return
  profile.source.value = draft
  writeProfileDraft(profile, draft)
  profile.dirty.value = false
  profile.revision.value += 1
}

function readProfile(profile: ProfileSignals): ProfileDraft {
  return {
    description: profile.description.value,
    providerID: profile.providerID.value,
    model: profile.model.value,
    contextLength: profile.contextLength.value,
    providerOptions: profile.providerOptions.value,
    error: profile.error.value
  }
}

function updateProfile(profile: ProfileSignals, patch: ProfileDraftInput) {
  const current = readProfile(profile)
  const next = { ...current, ...patch }
  const valuesChanged = !sameProfileValues(current, next)

  batch(() => {
    writeProfileDraft(profile, next)
    if (valuesChanged) profile.revision.value += 1
    profile.dirty.value = !sameProfileValues(next, profile.source.value)
  })
}

function profileSubmission(profile: ProfileSignals): ModelProfileSubmission {
  return { draft: readProfile(profile), revision: profile.revision.value }
}

function markProfileSaved(
  profile: ProfileSignals,
  input: ProfileDraftInput,
  submission: ModelProfileSubmission
): ModelProfilePersistenceResult {
  const saved = normalizedProfileDraft(input)
  const current = readProfile(profile)
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
}

function stringValue(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function normalizedProfileDraft(input: ProfileDraftInput): ProfileDraft {
  return { ...emptyProfileDraft(), ...input, error: input.error }
}

function writeProfileDraft(profile: ReturnType<typeof createProfileSignals>, draft: ProfileDraft) {
  profile.description.value = draft.description
  profile.providerID.value = draft.providerID
  profile.model.value = draft.model
  profile.contextLength.value = draft.contextLength
  profile.providerOptions.value = draft.providerOptions
  profile.error.value = draft.error
}

function sameProfileValues(left: ProfileDraft, right: ProfileDraft): boolean {
  return (
    left.description === right.description &&
    left.providerID === right.providerID &&
    left.model === right.model &&
    left.contextLength === right.contextLength &&
    JSON.stringify(left.providerOptions) === JSON.stringify(right.providerOptions)
  )
}
