import { recordValue } from '@pleisto/active-support'
import type {
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem
} from '../api/generated/types.gen'

/**
 * Maps an AIGateway provider kind's declared connection settings into the shape
 * the provider editor renders. The backend already owns the contract: each
 * `setting` with `scope: "connection"` is an operator-editable connection
 * option, and options flagged `encrypted` are sealed server-side when submitted
 * through `connection_options` (this is how an API key is stored). The console
 * previously ignored this and dumped a raw JSON textarea, so there was no field
 * to enter a credential at all — this module is what turns the declaration into
 * a labeled form.
 */

export type ProviderSetting = {
  key: string
  encrypted: boolean
  required: boolean
  isMap: boolean
  default: unknown
}

const ACRONYMS = new Set(['api', 'url', 'id', 'serp', 'ai', 'gl', 'hl'])

/** Returns the connection-scoped settings a provider kind accepts, in a safe shape. */
export function connectionSettings(kind: AIGatewayProviderKindItem | undefined): ProviderSetting[] {
  if (!kind) return []

  return kind.settings
    .map(asSetting)
    .filter((setting): setting is ProviderSetting => setting !== null && !HIDDEN_KEYS.has(setting.key))
}

// `base_url` has a dedicated top-level field and `transport` is a low-level
// escape hatch, so neither is rendered among the generated setting fields.
const HIDDEN_KEYS = new Set(['base_url', 'transport'])

function asSetting(raw: unknown): ProviderSetting | null {
  const record = recordValue(raw)
  if (!record) return null

  const key = typeof record.key === 'string' ? record.key : null
  const scope = typeof record.scope === 'string' ? record.scope : 'connection'
  if (!key || scope !== 'connection') return null

  return {
    key,
    encrypted: record.encrypted === true,
    required: record.required === true,
    isMap: record.type === 'map',
    default: record.default
  }
}

/** Turns a snake_case setting key into a readable sentence-case field label. */
export function humanizeKey(key: string): string {
  const words = key.split('_').map(word => (ACRONYMS.has(word) ? word.toUpperCase() : word))
  const joined = words.join(' ')
  return joined.charAt(0).toUpperCase() + joined.slice(1)
}

/**
 * Builds the initial string draft for one connection setting. Encrypted values
 * are never returned by the API (only a presence flag), so their inputs always
 * start empty; a blank encrypted input on save means "keep the stored secret".
 */
export function initialSettingValue(setting: ProviderSetting, provider: AIGatewayProviderItem | undefined): string {
  if (setting.encrypted) return ''

  const stored = provider ? recordValue(provider.connection_options)?.[setting.key] : undefined
  const value = stored ?? (provider ? undefined : setting.default)

  if (value == null) return ''
  if (setting.isMap) return JSON.stringify(value, null, 2)
  return String(value)
}

export type EncryptedOptionState = { present: boolean; masked?: string | null }

/** Reads the masked presence projection for an encrypted option, if any. */
export function encryptedOptionState(
  provider: AIGatewayProviderItem | undefined,
  key: string
): EncryptedOptionState | undefined {
  const option = provider?.encrypted_options?.[key]
  if (!option) return undefined
  return { present: option.present, masked: option.masked }
}

export type BuildResult = { ok: true; value: Record<string, unknown> } | { ok: false; key: string; error: string }

/**
 * Assembles `connection_options` from the string drafts, applying the backend's
 * write semantics: encrypted blanks are omitted (preserve), map fields are
 * parsed as JSON objects, and blank plain fields are omitted so the stored
 * options stay clean.
 */
export function buildConnectionOptions(
  settings: ProviderSetting[],
  drafts: Record<string, string>,
  invalidJSONMessage: (key: string) => string
): BuildResult {
  const options: Record<string, unknown> = {}

  for (const setting of settings) {
    const raw = drafts[setting.key] ?? ''
    const trimmed = raw.trim()

    if (setting.encrypted) {
      if (trimmed) options[setting.key] = raw
      continue
    }

    if (setting.isMap) {
      if (!trimmed) continue
      const parsed = parseObject(raw)
      if (!parsed.ok) return { ok: false, key: setting.key, error: invalidJSONMessage(humanizeKey(setting.key)) }
      if (Object.keys(parsed.value).length > 0) options[setting.key] = parsed.value
      continue
    }

    if (trimmed) options[setting.key] = trimmed
  }

  return { ok: true, value: options }
}

function parseObject(text: string): { ok: true; value: Record<string, unknown> } | { ok: false } {
  try {
    const value = recordValue(JSON.parse(text))
    return value ? { ok: true, value } : { ok: false }
  } catch {
    return { ok: false }
  }
}
