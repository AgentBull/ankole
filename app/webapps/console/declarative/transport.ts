import { useCallback, useEffect, useState, useSyncExternalStore } from 'react'
import { identityHeaders, sessionIdentityKey } from '../../common/browser-context'
import { csrfToken } from '../../common/internal-api-client'
import { draftAt, setDraftAt } from './fields'
import type { DeclarativeEnvelope, DeclarativeFieldDescriptor, DeclarativeSurfaceDescriptor } from './types'

export type DeclarativeRecord = Readonly<Record<string, unknown>>

export interface VisibilitySnapshot {
  readonly ids: ReadonlySet<string>
  readonly loading: boolean
  readonly error: string | null
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === 'object' && !Array.isArray(value))
}

export function asRecord(value: unknown): Record<string, unknown> {
  return isRecord(value) ? { ...value } : {}
}

export function formatIdentifierLabel(name: string): string {
  return name.replace(/_/g, ' ').replace(/\b\w/g, char => char.toUpperCase())
}

export function normalizeDeclarativeResponse(
  payload: unknown,
  envelope: DeclarativeEnvelope = 'jsonapi'
): DeclarativeRecord[] {
  if (envelope === 'flat') {
    return isRecord(payload) ? [payload] : Array.isArray(payload) ? payload.filter(isRecord) : []
  }
  if (!isRecord(payload)) {
    throw new Error('Expected an object JSON:API payload')
  }
  const data = payload.data
  if (data === null || data === undefined) return []
  const rows = (Array.isArray(data) ? data : [data]).filter(isRecord)
  if (envelope === 'data') return rows
  return rows.map(item => ({
    ...item,
    ...(isRecord(item.attributes) ? item.attributes : {})
  }))
}

function extractApiError(payload: unknown, response: Response): string {
  if (isRecord(payload)) {
    const errors = payload.errors
    if (Array.isArray(errors) && errors.length > 0) {
      const messages = errors
        .filter(isRecord)
        .map(item => String(item.detail ?? item.title ?? item.code ?? response.statusText))
        .filter(Boolean)
      if (messages.length > 0) return messages.join('; ')
    }
    if (typeof payload.error === 'string' && payload.error) return payload.error
    if (isRecord(payload.errors) && typeof payload.errors.detail === 'string') return payload.errors.detail
  }
  return `Request failed (${response.status} ${response.statusText})`
}

export async function declarativeRequest(
  url: string,
  method = 'GET',
  payload?: unknown,
  responseEnvelope: DeclarativeEnvelope = 'jsonapi'
): Promise<DeclarativeRecord[]> {
  const token = typeof document === 'undefined' ? undefined : csrfToken()
  const body = payload === undefined ? undefined : JSON.stringify(payload)
  const response = await fetch(url, {
    method,
    credentials: 'same-origin',
    headers: {
      accept: 'application/vnd.api+json',
      ...(body ? { 'content-type': 'application/vnd.api+json' } : {}),
      ...(token ? { 'x-csrf-token': token } : {}),
      ...identityHeaders()
    },
    body
  })

  const text = await response.text()
  let parsed: unknown = null
  if (text) {
    try {
      parsed = JSON.parse(text)
    } catch {
      throw new Error(`Expected a JSON response (${response.status} ${response.statusText})`)
    }
  }
  if (!response.ok) {
    throw new Error(extractApiError(parsed, response))
  }
  return response.status === 204 ? [] : normalizeDeclarativeResponse(parsed, responseEnvelope)
}

export function resolveRecordEndpoint(endpoint: string, id?: string): string | undefined {
  if (!endpoint.includes(':id')) return endpoint
  if (!id) return undefined
  return endpoint.replace(':id', encodeURIComponent(id))
}

export function surfaceQueryEndpoint(
  surface: DeclarativeSurfaceDescriptor,
  id?: string,
  filters: Readonly<Record<string, string | undefined>> = {}
): string | undefined {
  const base = resolveRecordEndpoint(surface.endpoint, id)
  if (!base) return undefined

  const allowedNames = new Set<string>([
    ...surface.filters,
    ...(surface.filterSchemas?.map(schema => schema.name) ?? [])
  ])
  const searchParams = new URLSearchParams()
  for (const [key, rawValue] of Object.entries(filters)) {
    if (rawValue === undefined || rawValue === '') continue
    if (allowedNames.size === 0 || allowedNames.has(key)) {
      searchParams.set(key, rawValue)
    }
  }
  return searchParams.size > 0 ? `${base}?${searchParams}` : base
}

export async function executeDeclarativeAction(
  surface: DeclarativeSurfaceDescriptor,
  payload: Readonly<Record<string, unknown>>
): Promise<DeclarativeRecord[]> {
  const needsId = surface.endpoint.includes(':id')
  const recordId = needsId && typeof payload.id === 'string' && payload.id ? payload.id : undefined
  if (needsId && !recordId) {
    throw new Error('Select a record before executing this action')
  }
  const url = resolveRecordEndpoint(surface.endpoint, recordId)
  if (!url) throw new Error('Missing target endpoint')

  const responseEnvelope = surface.responseEnvelope ?? (surface.payloadEnvelope === 'jsonapi' ? 'jsonapi' : 'flat')
  if (surface.method === 'DELETE') {
    return declarativeRequest(url, 'DELETE', undefined, responseEnvelope)
  }

  const attributes = Object.fromEntries(
    Object.entries(payload).filter(([key, value]) => {
      if (key !== 'id') return true
      return !needsId && typeof value === 'string' && value.trim().length > 0
    })
  )

  switch (surface.payloadEnvelope) {
    case 'flat':
      return declarativeRequest(url, surface.method, attributes, responseEnvelope)
    case 'data':
      return declarativeRequest(url, surface.method, { data: attributes }, responseEnvelope)
    case 'jsonapi': {
      if (!surface.resourceType) {
        throw new Error(`Surface "${surface.id}" is missing a JSON:API resourceType`)
      }
      return declarativeRequest(
        url,
        surface.method,
        {
          data: {
            type: surface.resourceType,
            ...(recordId ? { id: recordId } : {}),
            attributes
          }
        },
        responseEnvelope
      )
    }
  }
}

export interface NullablePatchSerializerOptions {
  readonly nullableFields: readonly string[]
  readonly arrayFields?: readonly string[]
}

export function serializeNullablePatchPayload(
  draft: Readonly<Record<string, unknown>>,
  options: NullablePatchSerializerOptions
): Record<string, unknown> {
  const nullableSet = new Set(options.nullableFields)
  const arraySet = new Set(options.arrayFields ?? [])
  const output: Record<string, unknown> = {}

  for (const [key, rawValue] of Object.entries(draft)) {
    if (arraySet.has(key)) {
      if (rawValue === null || rawValue === undefined || rawValue === '') {
        output[key] = []
      } else if (Array.isArray(rawValue)) {
        output[key] = rawValue.filter(item => item !== '' && item !== null && item !== undefined)
      } else if (typeof rawValue === 'string') {
        const trimmed = rawValue.trim()
        output[key] =
          trimmed === ''
            ? []
            : trimmed
                .split(',')
                .map(part => part.trim())
                .filter(Boolean)
      } else {
        output[key] = []
      }
      continue
    }

    if (nullableSet.has(key)) {
      if (rawValue === undefined || rawValue === null) {
        output[key] = null
      } else if (typeof rawValue === 'string' && rawValue.trim() === '') {
        output[key] = null
      } else if (Array.isArray(rawValue) && rawValue.length === 0) {
        output[key] = []
      } else {
        output[key] = rawValue
      }
      continue
    }

    if (rawValue !== undefined) {
      output[key] = rawValue
    }
  }

  for (const nullableKey of options.nullableFields) {
    if (!(nullableKey in output)) {
      output[nullableKey] = arraySet.has(nullableKey) ? [] : null
    }
  }

  return output
}

function parseFieldScalar(field: DeclarativeFieldDescriptor, rawValue: unknown): unknown {
  if (field.type === 'object') {
    const source = asRecord(rawValue)
    const nestedFields = field.fields ?? []
    if (nestedFields.length === 0) return source
    const nested: Record<string, unknown> = {}
    for (const child of nestedFields) {
      if (child.name in source) {
        const parsed = parseFieldScalar(child, source[child.name])
        if (parsed !== undefined) nested[child.name] = parsed
      }
    }
    return nested
  }

  if (field.type === 'key_value') {
    if (!isRecord(rawValue)) return {}
    const out: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(rawValue)) {
      const key = k.trim()
      if (!key) continue
      if (field.valueType === 'number') {
        if (v === '' || v == null) continue
        const num = Number(v)
        if (Number.isNaN(num)) throw new Error(`${formatIdentifierLabel(field.name)} values must be numeric`)
        out[key] = num
      } else {
        out[key] = v == null ? '' : String(v)
      }
    }
    return out
  }

  if (field.type === 'string_array') {
    if (Array.isArray(rawValue)) return rawValue.map(item => String(item).trim()).filter(Boolean)
    if (typeof rawValue === 'string') {
      return rawValue
        .split(',')
        .map(item => item.trim())
        .filter(Boolean)
    }
    return []
  }

  if (field.type === 'integer' || field.type === 'number') {
    if (rawValue === '' || rawValue === null || rawValue === undefined) return undefined
    const parsed = Number(rawValue)
    if (Number.isNaN(parsed)) throw new Error(`${formatIdentifierLabel(field.name)} must be a valid number`)
    return field.type === 'integer' ? Math.trunc(parsed) : parsed
  }

  if (field.type === 'boolean') return Boolean(rawValue)

  if (field.type === 'json') {
    if (typeof rawValue === 'string') {
      const trimmed = rawValue.trim()
      if (!trimmed) return {}
      try {
        return JSON.parse(trimmed)
      } catch {
        throw new Error(`${formatIdentifierLabel(field.name)} must be valid JSON`)
      }
    }
    return rawValue ?? {}
  }

  if (field.type === 'datetime') {
    if (rawValue === '' || rawValue === null || rawValue === undefined) return undefined
    if (typeof rawValue === 'number') return new Date(rawValue * 1000).toISOString()
    const str = String(rawValue)
    if (field.inputUnit === 'date' && /^\d{4}-\d{2}-\d{2}$/.test(str)) {
      return `${str}T23:59:59Z`
    }
    const parsedDate = new Date(str)
    return Number.isNaN(parsedDate.getTime()) ? str : parsedDate.toISOString()
  }

  return rawValue === '' ? undefined : rawValue
}

export function serializeDeclarativeFields(
  surface: Pick<DeclarativeSurfaceDescriptor, 'fields' | 'nullableFields' | 'method' | 'ruleSchema'>,
  draft: Readonly<Record<string, unknown>>,
  recordId?: unknown
): Record<string, unknown> {
  const preserveNulls = surface.method === 'PATCH' || surface.method === 'PUT'
  const arrayFields = surface.fields.filter(field => field.type === 'string_array').map(field => field.name)
  const rawEntries: Record<string, unknown> = {}

  for (const field of surface.fields) {
    if (field.readOnly) continue
    if (!(field.name in draft)) continue
    const raw = draft[field.name]
    if (raw === '' || raw === null || raw === undefined) {
      rawEntries[field.name] = field.type === 'string_array' ? [] : null
    } else {
      rawEntries[field.name] = parseFieldScalar(field, raw)
    }
  }

  let workingDraft: Record<string, unknown> = { ...draft }
  if (surface.ruleSchema) {
    for (const section of surface.ruleSchema) {
      if (section.kind !== 'fields' || section.path.length === 0) continue
      const rawSection = draftAt(workingDraft, section.path)
      if (Object.keys(rawSection).length === 0) continue
      const coercedSection: Record<string, unknown> = { ...rawSection }
      for (const secField of section.fields) {
        if (secField.readOnly || !(secField.name in rawSection)) continue
        const coerced = parseFieldScalar(secField, rawSection[secField.name])
        if (coerced === undefined) delete coercedSection[secField.name]
        else coercedSection[secField.name] = coerced
      }
      workingDraft = setDraftAt(workingDraft, section.path, coercedSection)
    }
    for (const section of surface.ruleSchema) {
      const rootKey = section.path[0]
      if (rootKey && rootKey in workingDraft && isRecord(workingDraft[rootKey])) {
        rawEntries[rootKey] = workingDraft[rootKey]
      }
    }
  }

  const base = preserveNulls
    ? serializeNullablePatchPayload(rawEntries, { nullableFields: surface.nullableFields, arrayFields })
    : Object.fromEntries(
        Object.entries(rawEntries).filter(
          ([key, value]) => value !== undefined && (value !== null || arrayFields.includes(key))
        )
      )

  return typeof recordId === 'string' && recordId ? { ...base, id: recordId } : base
}

export function useDeclarativeRecords(
  endpoint?: string,
  refreshKey = 0,
  responseEnvelope: DeclarativeEnvelope = 'jsonapi'
) {
  const scope = currentScopeKey()
  const [revision, setRevision] = useState(0)
  const refresh = useCallback(() => setRevision(prev => prev + 1), [])
  const requestKey = endpoint ? JSON.stringify([endpoint, scope, revision, refreshKey, responseEnvelope]) : ''
  const [state, setState] = useState<{ key: string; rows: readonly DeclarativeRecord[]; error: string | null }>()

  useEffect(() => {
    if (!endpoint || !requestKey) return
    let active = true
    void declarativeRequest(endpoint, 'GET', undefined, responseEnvelope)
      .then(rows => {
        if (active) setState({ key: requestKey, rows, error: null })
      })
      .catch((failure: unknown) => {
        if (active) {
          setState({
            key: requestKey,
            rows: [],
            error: failure instanceof Error ? failure.message : String(failure)
          })
        }
      })
    return () => {
      active = false
    }
  }, [endpoint, requestKey, responseEnvelope])

  const current = state?.key === requestKey ? state : undefined
  return {
    rows: current?.rows ?? [],
    loading: Boolean(endpoint && !current),
    error: current?.error ?? null,
    refresh
  }
}

function currentScopeKey(): string {
  if (typeof document === 'undefined') return 'ssr'
  return `${location.origin}:${sessionIdentityKey()}`
}

interface VisibilityEntry {
  snapshot: VisibilitySnapshot
  inFlight: Promise<void> | null
  listeners: Set<() => void>
}

const EMPTY_SNAPSHOT: VisibilitySnapshot = {
  ids: new Set(),
  loading: true,
  error: null
}

const visibilityStore = new Map<string, VisibilityEntry>()

function entryKey(endpoint: string, scope: string): string {
  return `${scope}::${endpoint}`
}

function getOrCreateVisibilityEntry(endpoint: string, scope: string): VisibilityEntry {
  const key = entryKey(endpoint, scope)
  let entry = visibilityStore.get(key)
  if (!entry) {
    entry = {
      snapshot: EMPTY_SNAPSHOT,
      inFlight: null,
      listeners: new Set()
    }
    visibilityStore.set(key, entry)
  }
  return entry
}

function notifyEntry(entry: VisibilityEntry) {
  for (const listener of entry.listeners) listener()
}

function fetchVisibilityEntry(endpoint: string, scope: string, entry: VisibilityEntry, force = false): void {
  if (!endpoint || typeof window === 'undefined') return
  if (entry.inFlight) return
  if (!force && !entry.snapshot.loading && entry.snapshot.error === null) return

  entry.inFlight = declarativeRequest(endpoint, 'GET', undefined, 'flat')
    .then(rows => {
      const first = rows[0] ?? {}
      const rawIds = first.visible_ids
      const ids = new Set(
        Array.isArray(rawIds) ? rawIds.filter((item): item is string => typeof item === 'string') : []
      )
      entry.snapshot = { ids, loading: false, error: null }
    })
    .catch((failure: unknown) => {
      entry.snapshot = {
        ids: new Set(),
        loading: false,
        error: failure instanceof Error ? failure.message : String(failure)
      }
    })
    .finally(() => {
      entry.inFlight = null
      notifyEntry(entry)
    })
}

export function resetDeclarativeVisibilityStoreForTests() {
  visibilityStore.clear()
}

export function seedDeclarativeVisibilityForTests(endpoint: string, ids: readonly string[], scope = currentScopeKey()) {
  const entry = getOrCreateVisibilityEntry(endpoint, scope)
  entry.snapshot = {
    ids: new Set(ids),
    loading: false,
    error: null
  }
  notifyEntry(entry)
}

function subscribeScopeChanges(onStoreChange: () => void): () => void {
  if (typeof document === 'undefined' || typeof MutationObserver === 'undefined' || !document.head) {
    return () => {}
  }
  const observer = new MutationObserver(onStoreChange)
  observer.observe(document.head, {
    subtree: true,
    attributes: true,
    attributeFilter: ['content'],
    childList: true
  })
  return () => observer.disconnect()
}

export function useDeclarativeVisibility(endpoint: string) {
  const scope = useSyncExternalStore(subscribeScopeChanges, currentScopeKey, () => 'ssr')

  const subscribe = useCallback(
    (listener: () => void) => {
      const entry = getOrCreateVisibilityEntry(endpoint, scope)
      entry.listeners.add(listener)
      fetchVisibilityEntry(endpoint, scope, entry)
      return () => {
        entry.listeners.delete(listener)
      }
    },
    [endpoint, scope]
  )

  const snapshot = useSyncExternalStore(
    subscribe,
    () => getOrCreateVisibilityEntry(endpoint, scope).snapshot,
    () => getOrCreateVisibilityEntry(endpoint, scope).snapshot
  )

  useEffect(() => {
    const entry = getOrCreateVisibilityEntry(endpoint, scope)
    fetchVisibilityEntry(endpoint, scope, entry)
  }, [endpoint, scope])

  const refresh = useCallback(() => {
    const entry = getOrCreateVisibilityEntry(endpoint, scope)
    fetchVisibilityEntry(endpoint, scope, entry, true)
  }, [endpoint, scope])

  const isVisible = useCallback(
    (surfaceIdentifier: string, permissionSurface?: string) =>
      snapshot.ids.has(surfaceIdentifier) || (permissionSurface ? snapshot.ids.has(permissionSurface) : false),
    [snapshot.ids]
  )

  return {
    ...snapshot,
    scope,
    refresh,
    isVisible
  }
}
