import { batch, computed, createModel, signal } from '@preact/signals-react'
import { parse, stringify } from 'yaml'

export type KnowledgeMetadata = Record<string, unknown>
export const propertySource = (value: unknown) => stringify(value).trimEnd()

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
    () => editing.value && (parsed.value.error !== null || JSON.stringify(parsed.value.metadata) !== baseMetadata.value)
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
    replace,
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
