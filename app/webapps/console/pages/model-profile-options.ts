import { recordValue } from '@pleisto/active-support'
import type { CreatableComboboxOption } from '@ankole/uikit'
import type {
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem
} from '../api/generated/types.gen'
import type { ProfileName } from '../state/model-profiles-model'

export type ModelProfileCapability = 'llm' | 'embedding' | 'rerank'

export function profileCapability(profile: ProfileName): ModelProfileCapability {
  if (profile === 'embedding') return 'embedding'
  if (profile === 'rerank') return 'rerank'
  return 'llm'
}

/** Keeps only configured providers whose DSL declares the profile's capability. */
export function providersForProfile(
  providers: AIGatewayProviderItem[],
  kinds: AIGatewayProviderKindItem[],
  profile: ProfileName
): AIGatewayProviderItem[] {
  if (kinds.length === 0) return providers

  const capability = profileCapability(profile)
  const capabilitiesByKind = new Map(kinds.map(kind => [kind.provider_kind, kind.capabilities]))
  return providers.filter(provider => capabilitiesByKind.get(provider.provider_kind)?.includes(capability))
}

/**
 * Extracts known model ids for one configured provider from the OpenRouter-shaped
 * AIGateway catalog. Capability metadata narrows mixed catalogs, while entries
 * with incomplete metadata remain selectable for custom/private providers.
 */
export function modelOptionsForProfile(
  catalog: unknown,
  providerID: string,
  profile: ProfileName
): CreatableComboboxOption[] {
  if (!providerID) return []

  const prefix = `${providerID}/`
  const entries = catalogEntries(catalog).filter(entry => entry.id.startsWith(prefix))
  const capability = profileCapability(profile)
  const visibleEntries = entries.filter(entry => {
    const inferred = inferredCapability(entry)
    return inferred === capability || inferred === 'unknown'
  })
  const options = new Map<string, CreatableComboboxOption>()

  for (const entry of visibleEntries) {
    const value = entry.id.slice(prefix.length)
    if (!value || options.has(value)) continue

    const label = entry.name || value
    options.set(value, {
      value,
      label,
      description: label === value ? entry.description : value
    })
  }

  return [...options.values()]
}

type CatalogEntry = {
  id: string
  name?: string
  description?: string
  architecture?: Record<string, unknown>
  supportedParameters: string[]
}

function catalogEntries(catalog: unknown): CatalogEntry[] {
  const data = recordValue(catalog)?.data
  if (!Array.isArray(data)) return []

  return data.flatMap(raw => {
    const entry = recordValue(raw)
    if (!entry || typeof entry.id !== 'string') return []

    return [
      {
        id: entry.id,
        name: typeof entry.name === 'string' ? entry.name : undefined,
        description: typeof entry.description === 'string' ? entry.description : undefined,
        architecture: recordValue(entry.architecture) ?? undefined,
        supportedParameters: stringArray(entry.supported_parameters)
      }
    ]
  })
}

type CatalogCapability = ModelProfileCapability | 'other' | 'unknown'

function inferredCapability(entry: CatalogEntry): CatalogCapability {
  const outputModalities = stringArray(entry.architecture?.output_modalities)
  if (outputModalities.includes('embeddings') || entry.supportedParameters.includes('encoding_format')) {
    return 'embedding'
  }

  if (entry.supportedParameters.includes('query') && entry.supportedParameters.includes('documents')) {
    return 'rerank'
  }

  if (outputModalities.includes('text')) return 'llm'
  if (outputModalities.length > 0) return 'other'
  return 'unknown'
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []
}
