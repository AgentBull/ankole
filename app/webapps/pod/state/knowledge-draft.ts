import { batch, computed, createModel, signal } from '@preact/signals-react'
import { parse, stringify, YAMLParseError } from 'yaml'
import { isEqual, recordValue, safeJsonParse } from '@agentbull/active-support'
import type { DocumentDraftModel } from './document-draft'

export type KnowledgeMetadata = Record<string, unknown>
export const propertySource = (value: unknown) => stringify(value).trimEnd()
export const propertyText = (value: unknown) =>
  value === undefined ? '' : typeof value === 'string' ? value : propertySource(value)

/** A property problem that the page words in the reader's language; `detail` keeps the parser's own text. */
export class KnowledgePropertyError extends Error {
  constructor(
    readonly code: 'name_empty' | 'name_duplicate' | 'yaml_syntax' | 'not_mapping' | 'not_finite' | 'invalid',
    readonly params: { name?: string; line?: number; column?: number } = {},
    readonly detail?: string
  ) {
    super(detail ?? code)
  }
}

/** Any failure while reading properties, such as a cyclic alias, keeps its own text as the detail. */
export const propertyError = (error: unknown) =>
  error instanceof KnowledgePropertyError
    ? error
    : new KnowledgePropertyError('invalid', {}, error instanceof Error ? error.message : String(error))

function jsonValue(value: unknown): unknown {
  // JSONB cannot represent YAML infinities or cyclic aliases. Report them before save.
  JSON.stringify(value, (_key, item) => {
    if (typeof item === 'number' && !Number.isFinite(item)) throw new KnowledgePropertyError('not_finite')
    return item
  })
  return value
}

/** Parse YAML source; `name` names the property whose value the source holds. */
function parseYAML(source: string, name?: string): unknown {
  try {
    return parse(source)
  } catch (error) {
    if (!(error instanceof YAMLParseError)) throw error
    const [position] = error.linePos ?? []
    const detail = error.message.split('\n', 1)[0]!.replace(/ at line \d+, column \d+:$/, '')
    if (!position) throw new KnowledgePropertyError('invalid', { name }, detail)
    throw new KnowledgePropertyError('yaml_syntax', { name, line: position.line, column: position.col }, detail)
  }
}

export function parseMetadata(source: string): KnowledgeMetadata {
  const value = jsonValue(parseYAML(source) ?? {})
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new KnowledgePropertyError('not_mapping')
  return value as KnowledgeMetadata
}

export const KnowledgeDraftModel = createModel(() => {
  const editing = signal(false)
  const entries = signal<{ key: string; source: string }[]>([])
  const baseMetadata = signal('{}')
  const generation = signal(0)
  const parsed = computed(() => {
    const values = new Map<string, unknown>()
    try {
      for (const entry of entries.value) {
        if (!entry.key.trim()) throw new KnowledgePropertyError('name_empty')
        if (values.has(entry.key)) throw new KnowledgePropertyError('name_duplicate', { name: entry.key })
        values.set(entry.key, jsonValue(parseYAML(entry.source, entry.key) ?? null))
      }
      return { metadata: Object.fromEntries(values), error: null }
    } catch (error) {
      return { metadata: null, error: propertyError(error) }
    }
  })
  const dirty = computed(
    () =>
      editing.value &&
      (parsed.value.error !== null ||
        !isEqual(parsed.value.metadata, safeJsonParse(baseMetadata.value).unwrapOr(undefined)))
  )
  // Edit mode lists properties in the order that read mode shows them.
  const replace = (metadata: KnowledgeMetadata) => {
    entries.value = Object.entries(metadata).map(([key, value]) => ({ key, source: propertySource(value) }))
  }
  return {
    editing,
    entries,
    parsed,
    dirty,
    generation,
    recovery: computed(() => ({ entries: entries.value, baseMetadata: baseMetadata.value })),
    replace,
    restore(value: unknown) {
      const stored = recordValue(value)
      if (typeof stored?.baseMetadata !== 'string' || !Array.isArray(stored.entries)) return false
      const rows = stored.entries.map(recordValue)
      if (!rows.every(row => typeof row?.key === 'string' && typeof row.source === 'string')) return false
      entries.value = rows.map(row => ({ key: row!.key as string, source: row!.source as string }))
      baseMetadata.value = stored.baseMetadata
      editing.value = true
      generation.value++
      return true
    },
    saved(submitted: KnowledgeMetadata, confirmed: KnowledgeMetadata = submitted) {
      if (isEqual(parsed.value.metadata, submitted)) replace(confirmed)
      baseMetadata.value = JSON.stringify(
        Object.fromEntries(Object.entries(confirmed).sort(([a], [b]) => a.localeCompare(b)))
      )
    },
    begin(metadata: KnowledgeMetadata) {
      batch(() => {
        replace(metadata)
        baseMetadata.value = JSON.stringify(parsed.value.metadata)
        editing.value = true
        generation.value++
      })
    },
    finish() {
      editing.value = false
      generation.value++
    },
    change(index: number, patch: Partial<{ key: string; source: string }>) {
      entries.value = entries.value.map((entry, current) => (current === index ? { ...entry, ...patch } : entry))
    },
    remove(index: number) {
      entries.value = entries.value.filter((_, current) => index !== current)
    },
    add() {
      entries.value = [...entries.value, { key: '', source: '' }]
    }
  }
})

type Body = InstanceType<typeof DocumentDraftModel>
type Properties = InstanceType<typeof KnowledgeDraftModel>

/** Capture one XML/metadata revision before the request starts. */
export function knowledgeSubmission(body: Body, properties: Properties) {
  const { metadata, error } = properties.parsed.value
  if (error || !metadata) throw error ?? new KnowledgePropertyError('not_mapping')
  return { xml: body.xml.value, metadata, base_revision: body.revision.value, generation: properties.generation.value }
}

/** A save only confirms its own submission; newer input stays in the same editing session. */
export function acknowledgeKnowledge(
  body: Body,
  properties: Properties,
  submitted: ReturnType<typeof knowledgeSubmission>,
  confirmed = { xml: submitted.xml, metadata: submitted.metadata, revision: submitted.base_revision }
) {
  batch(() => {
    if (!properties.editing.value || properties.generation.value !== submitted.generation) return
    if (body.xml.value === submitted.xml) body.xml.value = confirmed.xml
    body.saved(confirmed.xml, confirmed.revision, false)
    properties.saved(submitted.metadata, confirmed.metadata)
    if (!body.hasUnsavedChanges.value && !properties.dirty.value) properties.finish()
  })
}

/** Rebases an untouched editing session onto a newer upstream snapshot without leaving edit mode. */
export function rebaseCleanKnowledge(
  body: Body,
  properties: Properties,
  latest: { xml: string; metadata: KnowledgeMetadata; revision: number }
) {
  batch(() => {
    if (!properties.editing.value || body.hasUnsavedChanges.value || properties.dirty.value) return
    const currentMeta = properties.parsed.value.metadata ?? {}
    if (
      body.revision.value === latest.revision &&
      body.savedXML.value === latest.xml &&
      isEqual(currentMeta, latest.metadata)
    ) {
      return
    }
    const xmlChanged = body.xml.value !== latest.xml
    body.xml.value = latest.xml
    body.saved(latest.xml, latest.revision, false)
    properties.saved(currentMeta, latest.metadata)
    if (xmlChanged) properties.generation.value++
  })
}
