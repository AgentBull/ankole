import { parseXml } from '@ankole/block-editor/document'
import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { ChildrenViewPatch, SubpageItem } from '../content-api'

export type SubpageViewMode = 'list' | 'grid'
export const SUBPAGE_FIELDS = ['created_by', 'updated_at', 'created_at'] as const
export type SubpageField = (typeof SUBPAGE_FIELDS)[number]
export type SubpageSortField = 'title' | 'updated_at' | 'created_at'
export type SubpageSort = { field: SubpageSortField; direction: 'asc' | 'desc' } | null

export type NormalizedChildrenView = {
  collapsed: boolean
  view: SubpageViewMode
  fieldOrder: SubpageField[]
  visibleFields: SubpageField[]
}

const DEFAULT_FIELD_ORDER: readonly SubpageField[] = ['created_by', 'updated_at', 'created_at']
const DEFAULT_VISIBLE_FIELDS: readonly SubpageField[] = ['created_by', 'updated_at']

function isSubpageField(value: unknown): value is SubpageField {
  return typeof value === 'string' && (SUBPAGE_FIELDS as readonly string[]).includes(value)
}

function normalizeFieldOrder(raw: unknown): SubpageField[] {
  if (!Array.isArray(raw)) return [...DEFAULT_FIELD_ORDER]
  const seen = new Set<SubpageField>()
  for (const item of raw) {
    if (isSubpageField(item)) seen.add(item)
  }
  for (const fallback of DEFAULT_FIELD_ORDER) seen.add(fallback)
  return [...seen]
}

function normalizeVisibleFields(raw: unknown, fieldOrder: readonly SubpageField[]): SubpageField[] {
  const source = Array.isArray(raw) ? raw.filter(isSubpageField) : DEFAULT_VISIBLE_FIELDS
  const visible = new Set<SubpageField>(source)
  return fieldOrder.filter(field => visible.has(field))
}

export function normalizeChildrenView(raw?: Record<string, unknown> | null): NormalizedChildrenView {
  const fieldOrder = normalizeFieldOrder(raw?.field_order)
  return {
    collapsed: typeof raw?.collapsed === 'boolean' ? raw.collapsed : false,
    view: raw?.view === 'grid' ? 'grid' : 'list',
    fieldOrder,
    visibleFields: normalizeVisibleFields(raw?.visible_fields, fieldOrder)
  }
}

function compareTreeOrder(a: Pick<SubpageItem, 'id' | 'position'>, b: Pick<SubpageItem, 'id' | 'position'>): number {
  return a.position < b.position ? -1 : a.position > b.position ? 1 : a.id.localeCompare(b.id)
}

export function sortSubpages<T extends Pick<SubpageItem, 'id' | 'title' | 'position' | 'created_at' | 'updated_at'>>(
  pages: readonly T[],
  sort: SubpageSort,
  untitledLabel: string
): T[] {
  if (!sort) return [...pages]
  const sign = sort.direction === 'asc' ? 1 : -1
  return [...pages].sort((a, b) => {
    if (sort.field === 'title') {
      const left = (a.title || untitledLabel).trim()
      const right = (b.title || untitledLabel).trim()
      const diff = left.localeCompare(right, undefined, { numeric: true, sensitivity: 'base' })
      return diff !== 0 ? diff * sign : compareTreeOrder(a, b)
    }
    const leftRaw = a[sort.field]
    const rightRaw = b[sort.field]
    const leftTime = leftRaw ? Date.parse(leftRaw) : Number.NaN
    const rightTime = rightRaw ? Date.parse(rightRaw) : Number.NaN
    const leftValid = Number.isFinite(leftTime)
    const rightValid = Number.isFinite(rightTime)
    if (!leftValid && !rightValid) return compareTreeOrder(a, b)
    if (!leftValid) return 1
    if (!rightValid) return -1
    if (leftTime !== rightTime) return (leftTime < rightTime ? -1 : 1) * sign
    return compareTreeOrder(a, b)
  })
}

export function fileExtensionBadge(filename?: string | null, mimeType?: string | null): string {
  if (filename) {
    const base = filename.trim().split('/').pop() ?? ''
    const dot = base.lastIndexOf('.')
    if (dot > 0 && dot < base.length - 1) {
      return base.slice(dot + 1, dot + 9).toUpperCase()
    }
  }
  if (mimeType) {
    const slash = mimeType.indexOf('/')
    if (slash >= 0 && slash < mimeType.length - 1) {
      const subtype = mimeType
        .slice(slash + 1)
        .split(';')[0]
        ?.split('+')[0]
        ?.trim()
      if (subtype) return subtype.slice(0, 8).toUpperCase()
    }
  }
  return 'FILE'
}

export function isDocumentBodyEmpty(xml: string): boolean {
  try {
    const root = parseXml(xml)
    return root.children.every(
      child =>
        child.type === 'element' &&
        child.name === 'p' &&
        Object.keys(child.attrs).length === 0 &&
        child.children.length === 0
    )
  } catch {
    return false
  }
}

type PersistPatch = NonNullable<ChildrenViewPatch>

/**
 * Presentation state for a Document page's bottom-appended subpages directory.
 * Editors persist presentation changes onto `page.children_view`; read-only viewers
 * keep interactive overrides in session memory without mutating the document.
 */
export const PageSubpagesModel = createModel((initialRaw?: Record<string, unknown> | null) => {
  let lastSyncedJSON = JSON.stringify(initialRaw ?? {})
  const server = signal<NormalizedChildrenView>(normalizeChildrenView(initialRaw))
  const sessionOverride = signal<Partial<NormalizedChildrenView>>({})
  const sort = signal<SubpageSort>(null)

  const collapsed = computed(() => sessionOverride.value.collapsed ?? server.value.collapsed)
  const view = computed(() => sessionOverride.value.view ?? server.value.view)
  const fieldOrder = computed(() => sessionOverride.value.fieldOrder ?? server.value.fieldOrder)
  const visibleFields = computed(() => {
    const order = fieldOrder.value
    const visible = new Set(sessionOverride.value.visibleFields ?? server.value.visibleFields)
    return order.filter(field => visible.has(field))
  })

  const applyChange = (
    next: Partial<NormalizedChildrenView>,
    patch: PersistPatch,
    canEdit: boolean,
    persist?: (patch: PersistPatch) => void
  ): PersistPatch | null => {
    if (canEdit) {
      batch(() => {
        server.value = { ...server.value, ...next }
        if (Object.keys(sessionOverride.value).length > 0) sessionOverride.value = {}
      })
      persist?.(patch)
      return patch
    }
    sessionOverride.value = { ...sessionOverride.value, ...next }
    return null
  }

  return {
    collapsed,
    view,
    fieldOrder,
    visibleFields,
    sort,
    syncFromServer(raw?: Record<string, unknown> | null) {
      const serialized = JSON.stringify(raw ?? {})
      if (serialized === lastSyncedJSON) return
      lastSyncedJSON = serialized
      server.value = normalizeChildrenView(raw)
    },
    setCollapsed(next: boolean, canEdit: boolean, persist?: (patch: PersistPatch) => void) {
      if (collapsed.value === next) return null
      return applyChange({ collapsed: next }, { collapsed: next }, canEdit, persist)
    },
    toggleCollapsed(canEdit: boolean, persist?: (patch: PersistPatch) => void) {
      const next = !collapsed.value
      return applyChange({ collapsed: next }, { collapsed: next }, canEdit, persist)
    },
    setView(next: SubpageViewMode, canEdit: boolean, persist?: (patch: PersistPatch) => void) {
      if (view.value === next) return null
      return applyChange({ view: next }, { view: next }, canEdit, persist)
    },
    toggleField(field: SubpageField, canEdit: boolean, persist?: (patch: PersistPatch) => void) {
      const order = fieldOrder.value
      const current = new Set(visibleFields.value)
      if (current.has(field)) current.delete(field)
      else current.add(field)
      const nextVisible = order.filter(candidate => current.has(candidate))
      return applyChange({ visibleFields: nextVisible }, { visible_fields: nextVisible }, canEdit, persist)
    },
    moveField(field: SubpageField, toIndex: number, canEdit: boolean, persist?: (patch: PersistPatch) => void) {
      const currentOrder = [...fieldOrder.value]
      const fromIndex = currentOrder.indexOf(field)
      const clamped = Math.max(0, Math.min(currentOrder.length - 1, toIndex))
      if (fromIndex < 0 || fromIndex === clamped) return null
      currentOrder.splice(fromIndex, 1)
      currentOrder.splice(clamped, 0, field)
      const currentVisible = new Set(visibleFields.value)
      const nextVisible = currentOrder.filter(candidate => currentVisible.has(candidate))
      return applyChange(
        { fieldOrder: currentOrder, visibleFields: nextVisible },
        { field_order: currentOrder, visible_fields: nextVisible },
        canEdit,
        persist
      )
    },
    stepField(field: SubpageField, delta: -1 | 1, canEdit: boolean, persist?: (patch: PersistPatch) => void) {
      const fromIndex = fieldOrder.value.indexOf(field)
      if (fromIndex < 0) return null
      const toIndex = fromIndex + delta
      if (toIndex < 0 || toIndex >= fieldOrder.value.length) return null
      const nextOrder = [...fieldOrder.value]
      nextOrder.splice(fromIndex, 1)
      nextOrder.splice(toIndex, 0, field)
      const currentVisible = new Set(visibleFields.value)
      const nextVisible = nextOrder.filter(candidate => currentVisible.has(candidate))
      return applyChange(
        { fieldOrder: nextOrder, visibleFields: nextVisible },
        { field_order: nextOrder, visible_fields: nextVisible },
        canEdit,
        persist
      )
    },
    cycleSort(field: SubpageSortField) {
      const current = sort.value
      if (!current || current.field !== field) {
        sort.value = { field, direction: 'asc' }
      } else if (current.direction === 'asc') {
        sort.value = { field, direction: 'desc' }
      } else {
        sort.value = null
      }
    },
    resetSort() {
      sort.value = null
    }
  }
})
