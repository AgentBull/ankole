import type { CreatableComboboxOption } from '@ankole/uikit'
import type { AIGatewayModelCatalogEntry, AIGatewayProviderKindItem } from '../state/provider-settings'
import type { ProfileDraft } from '../state/model-profiles-model'
import type { AIGatewayProviderItem, SettingValidationError } from '../state/provider-settings'

export type ModelProfileCapability = 'llm' | 'web_search' | 'web_fetch' | 'image_generate'

export function profileCapability(profile: string): ModelProfileCapability {
  if (profile === 'web_search') return 'web_search'
  if (profile === 'web_fetch') return 'web_fetch'
  if (profile === 'image_generate') return 'image_generate'
  return 'llm'
}

export function profileUsesConfigurableModel(profile: string): boolean {
  const capability = profileCapability(profile)
  return capability !== 'web_search' && capability !== 'web_fetch'
}

export type ModelProfileRequestFields =
  | { ok: true; fields: { model: string; context_length?: number } }
  | { ok: false; error: SettingValidationError }

/**
 * Adapts provider-only profiles to the backend's existing model-profile write
 * shape. A context length draft must be a positive integer; anything else is a
 * validation error, never a silent drop or truncation.
 */
export function modelProfileRequestFields(
  profile: string,
  draft: Pick<ProfileDraft, 'model' | 'contextLength'>
): ModelProfileRequestFields {
  if (!profileUsesConfigurableModel(profile)) return { ok: true, fields: { model: 'default' } }

  const contextLength = draft.contextLength.trim()
  if (!contextLength) return { ok: true, fields: { model: draft.model } }

  const value = /^\d+$/.test(contextLength) ? Number(contextLength) : Number.NaN
  if (!Number.isSafeInteger(value) || value <= 0) return { ok: false, error: 'integer' }
  return { ok: true, fields: { model: draft.model, context_length: value } }
}

/** Keeps only configured providers whose DSL declares the profile's capability. */
export function providersForProfile(
  providers: AIGatewayProviderItem[],
  kinds: AIGatewayProviderKindItem[],
  profile: string
): AIGatewayProviderItem[] {
  return providersWithCapability(providers, kinds, profileCapability(profile))
}

/** Keeps only configured providers whose DSL declares the given capability name. */
export function providersWithCapability(
  providers: AIGatewayProviderItem[],
  kinds: AIGatewayProviderKindItem[],
  capability: string
): AIGatewayProviderItem[] {
  const capabilitiesByKind = new Map(kinds.map(kind => [kind.provider_kind, kind.capabilities]))
  return providers.filter(provider => capabilitiesByKind.get(provider.provider_kind)?.includes(capability))
}

/** Lists typed catalog models for one provider and model profile. */
export function modelOptionsForProfile(
  catalog: AIGatewayModelCatalogEntry[],
  providerID: string,
  profile: string
): CreatableComboboxOption[] {
  return catalogOptions(
    catalog,
    providerID,
    entry => entry.capability === profileCapability(profile) && (profile !== 'vision_fallback' || entry.image_input)
  )
}

export type BrainModelCatalogKind = 'embedding' | 'rerank' | 'llm'

/** Lists typed catalog models for one Brain model slot. */
export function modelOptionsForBrainModel(
  catalog: AIGatewayModelCatalogEntry[],
  providerID: string,
  kind: BrainModelCatalogKind
): CreatableComboboxOption[] {
  return catalogOptions(catalog, providerID, entry => entry.capability === kind)
}

function catalogOptions(
  catalog: AIGatewayModelCatalogEntry[],
  providerID: string,
  visible: (entry: AIGatewayModelCatalogEntry) => boolean
): CreatableComboboxOption[] {
  const options = new Map<string, CreatableComboboxOption>()
  for (const entry of catalog.filter(entry => entry.provider_id === providerID && visible(entry))) {
    const value = entry.model
    if (!value || options.has(value)) continue
    const label = entry.name || value
    options.set(value, { value, label, description: label === value ? entry.description : value })
  }
  return [...options.values()]
}
