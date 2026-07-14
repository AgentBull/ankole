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
  advanced: boolean
  encrypted: boolean
  options: string[]
  required: boolean
  type: 'boolean' | 'float' | 'integer' | 'map' | 'select' | 'string'
  default: unknown
}

export type SettingValidationError = 'required' | 'json_object' | 'integer' | 'number' | 'selection'

const ACRONYMS = new Set(['api', 'url', 'id', 'serp', 'ai', 'gl', 'hl', 'json', 'http'])

/** Returns the connection-scoped settings a provider kind accepts, in a safe shape. */
export function connectionSettings(kind: AIGatewayProviderKindItem | undefined): ProviderSetting[] {
  return settingsForScope(kind, 'connection').filter(setting => !HIDDEN_CONNECTION_KEYS.has(setting.key))
}

// `transport` is a low-level escape hatch and is not rendered in the form.
const HIDDEN_CONNECTION_KEYS = new Set(['transport'])

/** Returns the request-scoped settings accepted by model profiles for a provider kind. */
export function requestSettings(kind: AIGatewayProviderKindItem | undefined): ProviderSetting[] {
  return settingsForScope(kind, 'request')
}

function settingsForScope(
  kind: AIGatewayProviderKindItem | undefined,
  scope: 'connection' | 'request'
): ProviderSetting[] {
  if (!kind) return []

  return kind.settings
    .map(raw => asSetting(raw, scope))
    .filter((setting): setting is ProviderSetting => setting !== null)
}

function asSetting(raw: unknown, expectedScope: 'connection' | 'request'): ProviderSetting | null {
  const record = recordValue(raw)
  if (!record) return null

  const key = typeof record.key === 'string' ? record.key : null
  const scope = typeof record.scope === 'string' ? record.scope : 'connection'
  if (!key || scope !== expectedScope) return null

  return {
    key,
    advanced: record.advanced === true,
    encrypted: record.encrypted === true,
    options: Array.isArray(record.options)
      ? record.options.filter((value): value is string => typeof value === 'string')
      : [],
    required: record.required === true,
    type: settingType(record.type),
    default: record.default
  }
}

function settingType(value: unknown): ProviderSetting['type'] {
  return value === 'boolean' || value === 'float' || value === 'integer' || value === 'map' || value === 'select'
    ? value
    : 'string'
}

/** Turns a snake_case setting key into a readable sentence-case field label. */
export function humanizeKey(key: string): string {
  const words = key
    .replace(/([a-z\d])([A-Z])/g, '$1 $2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
    .split(/[\s_-]+/)
    .filter(Boolean)
    .map(word => {
      const normalized = word.toLowerCase()
      return ACRONYMS.has(normalized) ? normalized.toUpperCase() : normalized
    })
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
  return settingDraftValue(value)
}

/** Converts one stored JSON value into the string shown by its generated form field. */
export function settingDraftValue(value: unknown): string {
  if (value == null) return ''
  if (typeof value === 'object') return JSON.stringify(value, null, 2)
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
 * Assembles DSL-backed settings from field drafts. Encrypted blanks are omitted
 * (preserve), typed fields are converted to their declared JSON values, and
 * blank optional fields are omitted so stored options stay clean.
 */
export function buildSettingOptions(
  settings: ProviderSetting[],
  drafts: Record<string, unknown>,
  validationMessage: (key: string, error: SettingValidationError) => string
): BuildResult {
  const options: Record<string, unknown> = {}

  for (const setting of settings) {
    const raw = drafts[setting.key] ?? ''
    const trimmed = typeof raw === 'string' ? raw.trim() : raw

    if (setting.encrypted) {
      if (trimmed !== '') options[setting.key] = raw
      continue
    }

    if (trimmed === '') {
      if (setting.required) return validationError(setting, 'required', validationMessage)
      continue
    }

    const parsed = parseSettingValue(setting, raw)
    if (!parsed.ok) return validationError(setting, parsed.error, validationMessage)
    options[setting.key] = parsed.value
  }

  return { ok: true, value: options }
}

/** Semantic wrapper for the provider editor's connection-scoped payload. */
export function buildConnectionOptions(
  settings: ProviderSetting[],
  drafts: Record<string, unknown>,
  validationMessage: (key: string, error: SettingValidationError) => string
): BuildResult {
  return buildSettingOptions(settings, drafts, validationMessage)
}

function validationError(
  setting: ProviderSetting,
  error: SettingValidationError,
  validationMessage: (key: string, error: SettingValidationError) => string
): BuildResult {
  return { ok: false, key: setting.key, error: validationMessage(humanizeKey(setting.key), error) }
}

function parseSettingValue(
  setting: ProviderSetting,
  raw: unknown
): { ok: true; value: unknown } | { ok: false; error: SettingValidationError } {
  switch (setting.type) {
    case 'map': {
      if (recordValue(raw)) return { ok: true, value: raw }
      if (typeof raw !== 'string') return { ok: false, error: 'json_object' }
      const parsed = parseObject(raw)
      return parsed.ok ? parsed : { ok: false, error: 'json_object' }
    }
    case 'boolean':
      if (typeof raw === 'boolean') return { ok: true, value: raw }
      if (raw === 'true') return { ok: true, value: true }
      if (raw === 'false') return { ok: true, value: false }
      return { ok: false, error: 'required' }
    case 'integer': {
      if (typeof raw === 'number' && Number.isSafeInteger(raw)) return { ok: true, value: raw }
      if (typeof raw !== 'string' || !/^-?\d+$/.test(raw.trim())) return { ok: false, error: 'integer' }
      const value = Number(raw)
      return Number.isSafeInteger(value) ? { ok: true, value } : { ok: false, error: 'integer' }
    }
    case 'float': {
      if (typeof raw === 'number' && Number.isFinite(raw)) return { ok: true, value: raw }
      const value = typeof raw === 'string' ? Number(raw.trim()) : Number.NaN
      return Number.isFinite(value) ? { ok: true, value } : { ok: false, error: 'number' }
    }
    case 'select': {
      const value = typeof raw === 'string' ? raw.trim() : raw
      return typeof value === 'string' && setting.options.includes(value)
        ? { ok: true, value }
        : { ok: false, error: 'selection' }
    }
    case 'string':
      return { ok: true, value: typeof raw === 'string' ? raw.trim() : raw }
  }
}

function parseObject(text: string): { ok: true; value: Record<string, unknown> } | { ok: false } {
  try {
    const value = recordValue(JSON.parse(text))
    return value ? { ok: true, value } : { ok: false }
  } catch {
    return { ok: false }
  }
}
