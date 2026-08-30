import { isRecord } from '@agentbull/active-support'
import type { JsonValue as JSONValue } from '../api/generated/types.gen'

/**
 * Pure helpers for the `brain.` settings group editor. The drawer owns
 * loading and saving; this module owns the key set, draft parsing, submit
 * serialization, and validation that mirrors `Ankole.Brain.Config`.
 */

export const BRAIN_KEYS = {
  enabled: 'brain.enabled',
  embeddingModel: 'brain.embedding_model',
  rerankModel: 'brain.rerank_model',
  webFetchModel: 'brain.web_fetch_model',
  extractionModel: 'brain.extraction_model',
  dreamingModel: 'brain.dreaming_model',
  searchTokenizer: 'brain.search_tokenizer',
  chunking: 'brain.chunking',
  forgetting: 'brain.forgetting',
  dreamingTaskCron: 'brain.dreaming_task_cron',
  selfHealingTaskCron: 'brain.self_healing_task_cron',
  signalChannelBatchIdleTime: 'brain.signal_channel_batch_idle_time',
  skillLearningEnabled: 'brain.skill_learning_enabled',
  skillLearningReflectionThreshold: 'brain.skill_learning_reflection_threshold'
} as const

/** The five nullable model keys; only the embedding model carries dimensions. */
export const BRAIN_MODEL_KEYS = [
  BRAIN_KEYS.embeddingModel,
  BRAIN_KEYS.rerankModel,
  BRAIN_KEYS.webFetchModel,
  BRAIN_KEYS.extractionModel,
  BRAIN_KEYS.dreamingModel
] as const

export const BRAIN_CRON_KEYS = [BRAIN_KEYS.dreamingTaskCron, BRAIN_KEYS.selfHealingTaskCron] as const

export const BRAIN_SEARCH_TOKENIZERS = ['icu', 'jieba', 'lindera_japanese', 'lindera_korean'] as const

export const BRAIN_CHUNKING_FIELDS = ['chunk_size', 'chunk_overlap', 'max_chars', 'max_tokens'] as const

export const BRAIN_FORGETTING_FIELDS = [
  'event_halflife_days',
  'preference_halflife_days',
  'commitment_halflife_days',
  'belief_halflife_days',
  'fact_halflife_days',
  'purge_soft_delete_ttl_hours'
] as const

export const BRAIN_MAX_EMBEDDING_DIMENSIONS = 4096

type BrainModelKey = (typeof BRAIN_MODEL_KEYS)[number]

export function isBrainModelKey(key: string): key is BrainModelKey {
  return (BRAIN_MODEL_KEYS as readonly string[]).includes(key)
}

export type BrainModelDraft = {
  configured: boolean
  providerID: string
  model: string
  /** Kept as text so a partial edit stays visible; validated on submit. */
  dimensions: string
  /** Raw JSON object text; empty means no provider options. */
  providerOptions: string
}

export type BrainSettingsValidationError = {
  /** i18n suffix under `console.settings.brain_error_`. */
  error: string
  /** The failing AppConfigure key, for the message interpolation. */
  key: string
  field?: string
}

export function brainModelRequiresDimensions(key: string): boolean {
  return key === BRAIN_KEYS.embeddingModel
}

/** Names the model-catalog class one Brain model slot suggests from. */
export function brainModelCatalogKind(key: string): 'embedding' | 'rerank' | 'llm' {
  if (key === BRAIN_KEYS.embeddingModel) return 'embedding'
  if (key === BRAIN_KEYS.rerankModel) return 'rerank'
  return 'llm'
}

/** Reads a stored model value (object or null) into an editable draft. */
export function brainModelDraft(value: JSONValue | undefined): BrainModelDraft {
  if (!isRecord(value)) {
    return { configured: false, providerID: '', model: '', dimensions: '', providerOptions: '' }
  }

  return {
    configured: true,
    providerID: typeof value.provider_id === 'string' ? value.provider_id : '',
    model: typeof value.model === 'string' ? value.model : '',
    dimensions: typeof value.dimensions === 'number' ? String(value.dimensions) : '',
    providerOptions: isRecord(value.provider_options) ? JSON.stringify(value.provider_options, null, 2) : ''
  }
}

/** Serializes a validated model draft into the stored JSON value. */
export function brainModelValue(draft: BrainModelDraft, requireDimensions: boolean): JSONValue {
  if (!draft.configured) return null

  const value: Record<string, JSONValue> = {
    provider_id: draft.providerID.trim(),
    model: draft.model.trim()
  }
  if (requireDimensions) value.dimensions = Number.parseInt(draft.dimensions, 10)
  const options = parseJSONObject(draft.providerOptions)
  if (options && Object.keys(options).length > 0) value.provider_options = options
  return value
}

export function sameBrainModelDraft(left: BrainModelDraft, right: BrainModelDraft): boolean {
  return (
    left.configured === right.configured &&
    left.providerID === right.providerID &&
    left.model === right.model &&
    left.dimensions === right.dimensions &&
    left.providerOptions === right.providerOptions
  )
}

/** Reads a number-map draft text into per-field text values with the given field order. */
export function brainNumberMapDraft(text: string | undefined, fields: readonly string[]): Record<string, string> {
  const parsed = parseDraftValue(text)
  const map = isRecord(parsed) ? parsed : {}

  return Object.fromEntries(
    fields.map(field => {
      const value = map[field]
      return [field, typeof value === 'number' ? String(value) : typeof value === 'string' ? value : '']
    })
  )
}

/** Field text becomes a JSON number when it reads as one; other text stays text for validation. */
function numberOrText(text: string): number | string {
  const trimmed = text.trim()
  const value = trimmed === '' ? Number.NaN : Number(trimmed)
  return Number.isFinite(value) ? value : text
}

/** Writes per-field text values back into the draft's JSON text, keeping numbers numeric. */
export function brainNumberMapText(values: Record<string, string>): string {
  return JSON.stringify(Object.fromEntries(Object.entries(values).map(([field, text]) => [field, numberOrText(text)])))
}

/** Serializes one number field's text into its draft JSON, keeping numbers numeric. */
export function brainNumberText(text: string): string {
  return JSON.stringify(numberOrText(text))
}

/**
 * Canonical draft text for the number-map keys; other keys return `undefined`.
 * Seeding through the same serialization the editor writes keeps a reverted
 * edit equal to its seed, so the drawer's dirty compare stays truthful.
 */
export function brainCanonicalDraft(key: string, value: JSONValue | null | undefined): string | undefined {
  const fields =
    key === BRAIN_KEYS.chunking
      ? BRAIN_CHUNKING_FIELDS
      : key === BRAIN_KEYS.forgetting
        ? BRAIN_FORGETTING_FIELDS
        : undefined
  if (!fields) return undefined
  return brainNumberMapText(brainNumberMapDraft(JSON.stringify(value ?? null), fields))
}

export function brainStringDraft(text: string | undefined): string {
  const value = parseDraftValue(text)
  return typeof value === 'string' ? value : ''
}

export function brainNumberDraft(text: string | undefined): string {
  const value = parseDraftValue(text)
  return typeof value === 'number' ? String(value) : typeof value === 'string' ? value : ''
}

/** Validates every brain key before the first write, mirroring the server schemas. */
export function brainSettingsValidationError(
  drafts: Record<string, string>,
  models: Record<string, BrainModelDraft>
): BrainSettingsValidationError | undefined {
  for (const key of BRAIN_MODEL_KEYS) {
    const draft = models[key]
    if (!draft || !draft.configured) continue
    if (!draft.providerID.trim()) return { error: 'model_provider_required', key }
    if (!draft.model.trim()) return { error: 'model_name_required', key }
    if (brainModelRequiresDimensions(key)) {
      const dimensions = Number(draft.dimensions)
      if (!Number.isInteger(dimensions) || dimensions < 1 || dimensions > BRAIN_MAX_EMBEDDING_DIMENSIONS) {
        return { error: 'model_dimensions_invalid', key }
      }
    }
    if (draft.providerOptions.trim() && parseJSONObject(draft.providerOptions) === undefined) {
      return { error: 'model_provider_options_invalid', key }
    }
  }

  const chunking = brainNumberMapDraft(drafts[BRAIN_KEYS.chunking], BRAIN_CHUNKING_FIELDS)
  for (const field of BRAIN_CHUNKING_FIELDS) {
    const value = Number(chunking[field])
    const minimum = field === 'chunk_overlap' ? 0 : 1
    if (chunking[field]?.trim() === '' || !Number.isInteger(value) || value < minimum) {
      return { error: 'chunking_field_invalid', key: BRAIN_KEYS.chunking, field }
    }
  }
  if (Number(chunking['chunk_overlap']) >= Number(chunking['chunk_size'])) {
    return { error: 'chunking_overlap', key: BRAIN_KEYS.chunking }
  }

  const forgetting = brainNumberMapDraft(drafts[BRAIN_KEYS.forgetting], BRAIN_FORGETTING_FIELDS)
  for (const field of BRAIN_FORGETTING_FIELDS) {
    const value = Number(forgetting[field])
    if (forgetting[field]?.trim() === '' || !Number.isFinite(value) || value <= 0) {
      return { error: 'forgetting_field_invalid', key: BRAIN_KEYS.forgetting, field }
    }
  }

  for (const key of BRAIN_CRON_KEYS) {
    const expression = brainStringDraft(drafts[key])
    if (expression.trim().split(/\s+/).length !== 5) return { error: 'cron_invalid', key }
  }

  const idleTime = Number(brainNumberDraft(drafts[BRAIN_KEYS.signalChannelBatchIdleTime]))
  if (!Number.isInteger(idleTime) || idleTime < 1) {
    return { error: 'idle_time_invalid', key: BRAIN_KEYS.signalChannelBatchIdleTime }
  }

  const threshold = Number(brainNumberDraft(drafts[BRAIN_KEYS.skillLearningReflectionThreshold]))
  if (!Number.isInteger(threshold) || threshold < 2) {
    return {
      error: 'skill_learning_threshold_invalid',
      key: BRAIN_KEYS.skillLearningReflectionThreshold
    }
  }

  return undefined
}

function parseDraftValue(text: string | undefined): JSONValue | undefined {
  if (text === undefined) return undefined
  try {
    return JSON.parse(text) as JSONValue
  } catch {
    return undefined
  }
}

function parseJSONObject(text: string): Record<string, JSONValue> | undefined {
  if (!text.trim()) return {}
  try {
    const value: unknown = JSON.parse(text)
    return isRecord(value) ? (value as Record<string, JSONValue>) : undefined
  } catch {
    return undefined
  }
}
