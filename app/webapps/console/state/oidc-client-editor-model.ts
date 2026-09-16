import { batch, computed, createModel, signal } from '@preact/signals-react'
import type {
  ModelProfileWriteRequest,
  OidcClientCreateRequest,
  OidcClientItem,
  OidcClientUpdateRequest
} from '../api/generated/types.gen'
import type { ProfileDraft } from './model-profiles-model'
export const supportedScopes = ['openid', 'profile', 'email', 'offline_access', 'ai_gateway.write'] as const
export type OidcScope = (typeof supportedScopes)[number]

export type ClientDraft = {
  allowedGroupIDs: string[]
  allowedIdentityProviderIDs: string[]
  backchannelLogoutURI: string
  backchannelLogoutSessionRequired: boolean
  postLogoutRedirectURIs: string
  allowInsecureLocalLogout: boolean
  modelAliases: ClientModelAliasDraft[]
  enabled: boolean
  name: string
  redirectURIs: string
  scopes: OidcScope[]
  type: 'public' | 'confidential'
}

export type ClientModelAliasDraft = {
  key: string
  name: string
  persisted: boolean
  profile: ProfileDraft
  nameError?: string
  savedProfileKey?: string
}

export function emptyDraft(): ClientDraft {
  return {
    allowedGroupIDs: [],
    allowedIdentityProviderIDs: [],
    backchannelLogoutURI: '',
    backchannelLogoutSessionRequired: true,
    postLogoutRedirectURIs: '',
    allowInsecureLocalLogout: false,
    modelAliases: [],
    enabled: true,
    name: '',
    redirectURIs: '',
    scopes: ['openid'],
    type: 'public'
  }
}

export function draftFromClient(client: OidcClientItem): ClientDraft {
  return {
    allowedGroupIDs: client.allowed_group_ids,
    allowedIdentityProviderIDs: client.allowed_identity_provider_ids,
    backchannelLogoutURI: client.backchannel_logout_uri ?? '',
    backchannelLogoutSessionRequired: client.backchannel_logout_session_required,
    postLogoutRedirectURIs: client.post_logout_redirect_uris.join('\n'),
    allowInsecureLocalLogout: client.allow_insecure_local_logout,
    modelAliases: Object.entries(client.allowed_models)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([name, profile]) => {
        const draft = profileDraftFromRequest(profile)

        return {
          key: `stored:${name}`,
          name,
          persisted: true,
          profile: draft,
          savedProfileKey: profileDraftKey(draft)
        }
      }),
    enabled: client.enabled,
    name: client.name,
    redirectURIs: client.redirect_uris.join('\n'),
    scopes: supportedScopes.filter(scope => client.scopes.includes(scope)),
    type: client.type
  }
}

function draftKey(draft: ClientDraft): string {
  return JSON.stringify({
    ...draft,
    modelAliases: draft.modelAliases.map(alias => ({
      name: alias.name,
      profile: {
        contextLength: alias.profile.contextLength,
        description: alias.profile.description,
        model: alias.profile.model,
        providerID: alias.profile.providerID,
        providerOptions: alias.profile.providerOptions
      }
    }))
  })
}

export function writeBody(
  draft: ClientDraft,
  modelAliases: Record<string, ModelProfileWriteRequest>
): OidcClientUpdateRequest & Omit<OidcClientCreateRequest, 'type'> {
  return {
    allowed_group_ids: draft.allowedGroupIDs,
    allowed_identity_provider_ids: draft.allowedIdentityProviderIDs,
    backchannel_logout_uri: draft.backchannelLogoutURI.trim() || null,
    backchannel_logout_session_required: draft.backchannelLogoutSessionRequired,
    post_logout_redirect_uris: lines(draft.postLogoutRedirectURIs),
    allow_insecure_local_logout: draft.allowInsecureLocalLogout,
    allowed_models: modelAliases,
    enabled: draft.enabled,
    name: draft.name.trim(),
    redirect_uris: lines(draft.redirectURIs),
    scopes: draft.scopes
  }
}

function profileDraftFromRequest(profile: ModelProfileWriteRequest): ProfileDraft {
  return {
    contextLength: profile.context_length ? String(profile.context_length) : '',
    description: profile.description ?? '',
    model: profile.model ?? '',
    providerID: profile.provider_id ?? '',
    providerOptions: profile.provider_options ?? {}
  }
}

export function profileDraftKey(profile: ProfileDraft): string {
  return JSON.stringify({
    contextLength: profile.contextLength,
    description: profile.description,
    model: profile.model,
    providerID: profile.providerID,
    providerOptions: profile.providerOptions
  })
}

function lines(value: string): string[] {
  return [
    ...new Set(
      value
        .split(/\r?\n/)
        .map(line => line.trim())
        .filter(Boolean)
    )
  ]
}
export const OIDCClientEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const draft = signal<ClientDraft>(emptyDraft())
  const savedDraft = signal(draftKey(draft.value))
  const dirty = computed(() => draftKey(draft.value) !== savedDraft.value)
  const markSaved = (next: ClientDraft) =>
    batch(() => {
      draft.value = next
      savedDraft.value = draftKey(next)
    })
  return {
    sourceKey,
    draft,
    dirty,
    markSaved,
    initialize(key: string, source: ClientDraft) {
      batch(() => {
        sourceKey.value = key
        markSaved(source)
      })
    },
    setDraft(next: ClientDraft | ((current: ClientDraft) => ClientDraft)) {
      draft.value = typeof next === 'function' ? next(draft.value) : next
    }
  }
})
