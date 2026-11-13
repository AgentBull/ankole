import type { PutAgentModelProfileData } from '../api/v2/generated/types.gen'
import { equal, recordValue, stringArg, type JsonObject as JSONObject } from '@agentbull/active-support'
import { batch, computed, createModel, signal } from '@preact/signals-react'

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
export const POD_PROFILE_NAMES = [
  ...PROFILE_NAMES,
  'rerank',
  'decision',
  'speech',
  'transcription',
  'ocr',
  'video',
  'music'
] as const
export type ProfileName = (typeof POD_PROFILE_NAMES)[number]

export function resolvedProfileValue(entry: unknown): JSONObject {
  const resolved = recordValue(entry)
  return recordValue(resolved?.value) ?? {}
}

export function resolvedProviderHosted(configuration: JSONObject | undefined): {
  web_search: boolean
  image_generate: boolean
} {
  const effective = recordValue(configuration?.effective)

  return {
    web_search: recordValue(effective?.web_search)?.value !== false,
    image_generate: recordValue(effective?.image_generate)?.value !== false
  }
}

/** The layer a model-profile editor writes: Site and Pod defaults, one Agent, or one system Principal. */
export type ModelProfileLayer = 'global' | 'tenant' | 'agent' | 'system'

/**
 * Lists the overrides that the editor's layer stores, which restoring every
 * slot's inheritance removes: fixed-slot profiles and Provider-hosted switches.
 */
export function layerOverrides(configuration: JSONObject | undefined): {
  profiles: ProfileName[]
  hosted: ('web_search' | 'image_generate')[]
} {
  const overrides = recordValue(configuration?.overrides) ?? {}
  const hostedOverrides = recordValue(recordValue(configuration?.provider_hosted)?.overrides) ?? {}

  return {
    profiles: POD_PROFILE_NAMES.filter(profile => Object.hasOwn(overrides, profile)),
    hosted: (['web_search', 'image_generate'] as const).filter(capability => Object.hasOwn(hostedOverrides, capability))
  }
}

/**
 * Says where a slot's effective value comes from, so a value that the layer
 * inherits never reads as one that the layer stores.
 */
export function profileSource(
  layer: ModelProfileLayer,
  profile: ProfileName,
  hasOverride: boolean,
  entry: unknown
):
  | { kind: 'own'; layer: ModelProfileLayer }
  | { kind: 'fallback'; profile: ProfileName }
  | { kind: 'inherited'; source: string }
  | { kind: 'none' } {
  if (hasOverride) return { kind: 'own', layer }

  const resolved = recordValue(entry)
  const resolvedFrom = resolved?.resolved_from_profile
  if (typeof resolvedFrom === 'string' && resolvedFrom !== profile) {
    return { kind: 'fallback', profile: resolvedFrom as ProfileName }
  }

  const value = recordValue(resolved?.value)
  if (!value || Object.keys(value).length === 0) return { kind: 'none' }
  return { kind: 'inherited', source: typeof resolved?.source === 'string' ? resolved.source : 'default' }
}

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
    description: stringArg(profile, 'description') ?? '',
    providerID: stringArg(profile, 'provider_id') ?? '',
    model: stringArg(profile, 'model') ?? '',
    contextLength: profile.context_length ? String(profile.context_length) : '',
    providerOptions: recordValue(profile.provider_options) ?? {}
  }
}

export function draftsFromEffective(effective: JSONObject) {
  return Object.fromEntries(
    POD_PROFILE_NAMES.map(profile => [profile, draftFromProfile(resolvedProfileValue(effective[profile]))])
  )
}

export const ModelProfilesModel = createModel(() => {
  const sourceKey = signal<string>()
  const profiles = Object.fromEntries(POD_PROFILE_NAMES.map(name => [name, createProfileSignals()])) as Record<
    ProfileName,
    ProfileSignals
  >
  const dirty = computed(() => POD_PROFILE_NAMES.some(name => profiles[name].dirty.value))

  return {
    sourceKey,
    profiles,
    dirty,
    initialize(nextSourceKey: string, drafts: Partial<Record<ProfileName, ProfileDraftInput>>) {
      batch(() => {
        const sameSource = sourceKey.value === nextSourceKey
        if (!sameSource) sourceKey.value = nextSourceKey

        for (const name of POD_PROFILE_NAMES) {
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
      effective: JSONObject,
      submission: ModelProfileSubmission
    ): ModelProfilePersistenceResult {
      const drafts = draftsFromEffective(effective)
      return batch(() => {
        const result = markProfileSaved(profiles[name], drafts[name]!, submission)
        for (const profile of POD_PROFILE_NAMES) {
          if (!profiles[profile].dirty.value) applyProfile(profiles[profile], drafts[profile]!)
        }
        return result
      })
    },
    reset(name: ProfileName) {
      const profile = profiles[name]
      const restored: ProfileDraft = {
        ...profile.source.value,
        providerOptions: { ...profile.source.value.providerOptions },
        error: undefined
      }

      batch(() => {
        writeProfileDraft(profile, restored)
        profile.revision.value += 1
        profile.dirty.value = false
      })
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
  const description = signal(initial.description)
  const providerID = signal(initial.providerID)
  const model = signal(initial.model)
  const contextLength = signal(initial.contextLength)
  const providerOptions = signal(initial.providerOptions)
  const error = signal<string>()
  const draft = computed<ProfileDraft>(() => ({
    description: description.value,
    providerID: providerID.value,
    model: model.value,
    contextLength: contextLength.value,
    providerOptions: providerOptions.value,
    error: error.value
  }))

  return {
    source: signal(initial),
    description,
    providerID,
    model,
    contextLength,
    providerOptions,
    error,
    draft,
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
    equal(left.providerOptions, right.providerOptions)
  )
}

export type ModelProfileWriteRequest = PutAgentModelProfileData['body']['data']['attrs']
