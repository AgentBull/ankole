import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { PrincipalItem } from '../api/generated/types.gen'
import { resetCursorParams } from './cursor-pagination'

export type BrainEntrySnapshot = {
  id: string
  name: string
  type: string
  summary: string
  aliases: string[]
  properties: Record<string, unknown>
  lock_version: number
}

export type BrainMetadataDraft = {
  name: string
  type: string
  summary: string
  aliases: string[]
  properties: Record<string, unknown>
}

export type BrainMetadataOperation =
  | {
      operation: 'set_name'
      entry_id: string
      name: string
      expected_entry_lock_version: number
    }
  | {
      operation: 'set_type'
      entry_id: string
      type: string
      expected_entry_lock_version: number
    }
  | {
      operation: 'set_summary'
      entry_id: string
      summary: string
      expected_entry_lock_version: number
    }
  | {
      operation: 'set_aliases'
      entry_id: string
      aliases: string[]
      expected_entry_lock_version: number
    }
  | {
      operation: 'set_property'
      entry_id: string
      key: string
      value: unknown
      expected_entry_lock_version: number
    }

export type PropertyDraft = { key: string; value: string }

export type BrainMetadataEditorDraft = {
  name: string
  type: string
  summary: string
  aliases: string[]
  propertyDrafts: PropertyDraft[]
}

export type BrainOwnerOption = Pick<PrincipalItem, 'uid' | 'type'>

export type BrainAuditSelection = {
  scope: string
  ids: Set<string>
  confirming: boolean
}

export const BrainMetadataEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const name = signal('')
  const type = signal('')
  const summary = signal('')
  const aliases = signal<string[]>([])
  const propertyDrafts = signal<PropertyDraft[]>([])
  const initialDraft = signal<BrainMetadataEditorDraft>()
  const dirty = computed(() => {
    const source = initialDraft.value
    return Boolean(
      source &&
      (name.value !== source.name ||
        type.value !== source.type ||
        summary.value !== source.summary ||
        JSON.stringify(aliases.value) !== JSON.stringify(source.aliases) ||
        JSON.stringify(propertyDrafts.value) !== JSON.stringify(source.propertyDrafts))
    )
  })

  return {
    sourceKey,
    name,
    type,
    summary,
    aliases,
    propertyDrafts,
    dirty,
    initialize(nextSourceKey: string, draft: BrainMetadataEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        name.value = draft.name
        type.value = draft.type
        summary.value = draft.summary
        aliases.value = [...draft.aliases]
        propertyDrafts.value = draft.propertyDrafts.map(property => ({ ...property }))
        initialDraft.value = {
          ...draft,
          aliases: [...draft.aliases],
          propertyDrafts: draft.propertyDrafts.map(property => ({ ...property }))
        }
      })
    },
    markSaved(draft?: BrainMetadataEditorDraft) {
      initialDraft.value = draft
        ? {
            ...draft,
            aliases: [...draft.aliases],
            propertyDrafts: draft.propertyDrafts.map(property => ({ ...property }))
          }
        : {
            name: name.value,
            type: type.value,
            summary: summary.value,
            aliases: [...aliases.value],
            propertyDrafts: propertyDrafts.value.map(property => ({ ...property }))
          }
    }
  }
})

/** Keeps Brain's agent-first default while allowing every active Principal to be selected. */
export function defaultBrainOwnerUID(principals: BrainOwnerOption[]): string {
  return principals.find(principal => principal.type === 'agent')?.uid ?? principals[0]?.uid ?? ''
}

/**
 * Resolves a `?owner` request on the agent-only Brain surfaces, whose pickers
 * list only agents. An owner that is not a listed agent falls back to the
 * default, so the page and the picker always agree.
 */
export function agentOwnerUID(requested: string | null, agents: BrainOwnerOption[]): string {
  return requested && agents.some(agent => agent.uid === requested) ? requested : defaultBrainOwnerUID(agents)
}

export function brainAuditSelectionScope(ownerUID: string, searchParams: URLSearchParams): string {
  return JSON.stringify([
    ownerUID,
    ...['store', 'action', 'actor', 'run', 'after', 'before'].map(key => searchParams.get(key) ?? '')
  ])
}

export function brainAuditSelectionForScope(selection: BrainAuditSelection, scope: string): BrainAuditSelection {
  return selection.scope === scope ? selection : { scope, ids: new Set(), confirming: false }
}

export function brainAuditSelectionAfterRestore(
  selection: BrainAuditSelection,
  restoredSelection: BrainAuditSelection
): BrainAuditSelection {
  return selection === restoredSelection ? { ...selection, ids: new Set(), confirming: false } : selection
}

/** Builds the smallest structured operation batch for the editable entry metadata. */
export function buildMetadataOperations(
  entry: BrainEntrySnapshot,
  draft: BrainMetadataDraft
): BrainMetadataOperation[] {
  const operations: BrainMetadataOperation[] = []

  if (draft.name.trim() !== entry.name) {
    operations.push({
      operation: 'set_name',
      entry_id: entry.id,
      name: draft.name.trim(),
      expected_entry_lock_version: entry.lock_version
    })
  }

  if (draft.type.trim() !== entry.type) {
    operations.push({
      operation: 'set_type',
      entry_id: entry.id,
      type: draft.type.trim(),
      expected_entry_lock_version: entry.lock_version
    })
  }

  if (draft.summary !== entry.summary) {
    operations.push({
      operation: 'set_summary',
      entry_id: entry.id,
      summary: draft.summary,
      expected_entry_lock_version: entry.lock_version
    })
  }

  const aliases = normalizeAliases(draft.aliases)
  if (!sameJSON(aliases, entry.aliases)) {
    operations.push({
      operation: 'set_aliases',
      entry_id: entry.id,
      aliases,
      expected_entry_lock_version: entry.lock_version
    })
  }

  for (const key of new Set([...Object.keys(entry.properties), ...Object.keys(draft.properties)])) {
    const before = entry.properties[key]
    const after = Object.hasOwn(draft.properties, key) ? draft.properties[key] : null
    if (sameJSON(before, after)) continue

    operations.push({
      operation: 'set_property',
      entry_id: entry.id,
      key,
      value: after,
      expected_entry_lock_version: entry.lock_version
    })
  }

  return operations
}

export function normalizeAliases(values: string[]): string[] {
  return [...new Set(values.map(value => value.trim()).filter(Boolean))]
}

export function propertiesToDrafts(properties: Record<string, unknown>): PropertyDraft[] {
  return Object.entries(properties).map(([key, value]) => ({ key, value: JSON.stringify(value, null, 2) }))
}

export function parsePropertyDrafts(
  drafts: PropertyDraft[]
): { ok: true; value: Record<string, unknown> } | { ok: false; key: string; detail: string } {
  const properties: Record<string, unknown> = {}

  for (const draft of drafts) {
    const key = draft.key.trim()
    if (!key) return { ok: false, key: '', detail: 'property key is required' }
    if (Object.hasOwn(properties, key)) return { ok: false, key, detail: 'property key is duplicated' }

    try {
      properties[key] = JSON.parse(draft.value)
    } catch (error) {
      return { ok: false, key, detail: error instanceof Error ? error.message : String(error) }
    }
  }

  return { ok: true, value: properties }
}

/** Updates one URL-backed Brain filter and invalidates any cursor page derived from the old filter set. */
export function setBrainFilter(
  searchParams: URLSearchParams,
  key: string,
  value: string,
  cursorPrefix = ''
): URLSearchParams {
  const next = new URLSearchParams(searchParams)
  if (value) next.set(key, value)
  else next.delete(key)
  return resetCursorParams(next, cursorPrefix)
}

function sameJSON(left: unknown, right: unknown): boolean {
  return JSON.stringify(left) === JSON.stringify(right)
}
