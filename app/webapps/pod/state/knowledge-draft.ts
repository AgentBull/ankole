import { batch, computed, createModel, signal } from '@preact/signals-react'
import { parse, stringify } from 'yaml'
import { isEqual, recordValue, safeJsonParse } from '@agentbull/active-support'
import type { DocumentDraftModel } from './document-draft'

export type KnowledgeMetadata = Record<string, unknown>
export const propertySource = (value: unknown) => stringify(value).trimEnd()
export const propertyText = (value: unknown) =>
  value === undefined ? '' : typeof value === 'string' ? value : propertySource(value)

function jsonValue(value: unknown): unknown {
  // JSONB cannot represent YAML infinities or cyclic aliases. Report them before save.
  JSON.stringify(value, (_key, item) => {
    if (typeof item === 'number' && !Number.isFinite(item)) throw new Error('Properties need finite numbers.')
    return item
  })
  return value
}

export function parseMetadata(source: string): KnowledgeMetadata {
  const value = jsonValue(parse(source) ?? {})
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Properties must be a YAML mapping.')
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
        if (!entry.key.trim()) throw new Error('Property names cannot be empty.')
        if (values.has(entry.key)) throw new Error(`Duplicate property: ${entry.key}`)
        values.set(entry.key, jsonValue(parse(entry.source) ?? null))
      }
      return { metadata: Object.fromEntries(values), error: null }
    } catch (error) {
      return { metadata: null, error: error instanceof Error ? error.message : String(error) }
    }
  })
  const dirty = computed(
    () =>
      editing.value &&
      (parsed.value.error !== null ||
        !isEqual(parsed.value.metadata, safeJsonParse(baseMetadata.value).unwrapOr(undefined)))
  )
  const replace = (metadata: KnowledgeMetadata) => {
    entries.value = Object.entries(metadata)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, value]) => ({ key, source: propertySource(value) }))
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
  if (error || !metadata) throw new Error(error ?? 'Properties must be a YAML mapping.')
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
