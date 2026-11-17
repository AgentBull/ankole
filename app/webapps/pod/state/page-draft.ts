import { computed, createModel, effect, signal } from '@preact/signals-react'
import { recordValue, safeJsonParse } from '@agentbull/active-support'
import { registerPodSessionDraftCleaner } from '../../common/browser-session'
import type { Page } from '../content-api'
import { DocumentDraftModel } from './document-draft'
import { KnowledgeDraftModel } from './knowledge-draft'
import { TitleDraftModel } from './title-draft'

const PERSIST_DEBOUNCE_MS = 300
const MAX_IN_MEMORY_DRAFTS = 32
const inMemoryDrafts = new Map<string, Record<string, unknown>>()
const activeDraftCancels = new Map<string, Set<() => void>>()

function setInMemoryDraft(key: string, snapshot: Record<string, unknown>): void {
  inMemoryDrafts.delete(key)
  inMemoryDrafts.set(key, snapshot)
  if (inMemoryDrafts.size > MAX_IN_MEMORY_DRAFTS) {
    const oldest = inMemoryDrafts.keys().next().value
    if (oldest !== undefined) inMemoryDrafts.delete(oldest)
  }
}

registerPodSessionDraftCleaner(prefixes => {
  if (prefixes === null) {
    inMemoryDrafts.clear()
    for (const cancels of activeDraftCancels.values()) {
      for (const cancel of cancels) cancel()
    }
    return
  }
  for (const key of inMemoryDrafts.keys()) {
    if (prefixes.some(prefix => key.startsWith(prefix))) {
      inMemoryDrafts.delete(key)
    }
  }
  for (const [key, cancels] of activeDraftCancels.entries()) {
    if (prefixes.some(prefix => key.startsWith(prefix))) {
      for (const cancel of cancels) cancel()
    }
  }
})

/** A Page owns recovery and navigation; each editor owns its actual draft. */
export const PageDraftModel = createModel((type: Page['type'], storageKey?: string) => {
  const title = new TitleDraftModel()
  const body = type === 'doc' || type === 'knowledge' ? new DocumentDraftModel() : undefined
  const properties = type === 'knowledge' ? new KnowledgeDraftModel() : undefined
  const storageError = signal(false)
  let source = ''
  let pendingSnapshot: Record<string, unknown> | undefined
  let debounceTimer: ReturnType<typeof setTimeout> | undefined

  const clearPendingTimer = () => {
    if (debounceTimer !== undefined) {
      clearTimeout(debounceTimer)
      debounceTimer = undefined
    }
  }

  const cancelPendingPersistence = () => {
    clearPendingTimer()
    pendingSnapshot = undefined
  }

  if (storageKey) {
    let bucket = activeDraftCancels.get(storageKey)
    if (!bucket) {
      bucket = new Set()
      activeDraftCancels.set(storageKey, bucket)
    }
    bucket.add(cancelPendingPersistence)
  }

  const flush = () => {
    clearPendingTimer()
    if (!storageKey || pendingSnapshot === undefined) return
    const snapshot = pendingSnapshot
    pendingSnapshot = undefined
    try {
      sessionStorage.setItem(storageKey, JSON.stringify(snapshot))
      if (inMemoryDrafts.get(storageKey) === snapshot) {
        inMemoryDrafts.delete(storageKey)
      }
      storageError.value = false
    } catch {
      storageError.value = true
    }
  }

  const hasUnsavedChanges = computed(
    () => title.dirty.value || !!body?.hasUnsavedChanges.value || !!properties?.dirty.value
  )
  // Keep the established key and fields so existing recoverable drafts remain readable.
  const recovery = computed(() => ({
    title: title.value.value,
    savedTitle: title.saved.value,
    titleBase: title.base.value,
    ...(body
      ? {
          xml: body.xml.value,
          savedXML: body.savedXML.value,
          revision: body.revision.value,
          pending: body.bodyPending.value,
          recoveryDrafts: body.recoveryDrafts.value
        }
      : {}),
    ...(properties?.editing.value ? { knowledge: properties.recovery.value } : {})
  }))

  effect(() => {
    const win = typeof window !== 'undefined' ? window : undefined
    if (win && typeof win.addEventListener === 'function' && storageKey) {
      win.addEventListener('pagehide', flush)
      win.addEventListener('beforeunload', flush)
    }
    return () => {
      if (win && typeof win.removeEventListener === 'function' && storageKey) {
        win.removeEventListener('pagehide', flush)
        win.removeEventListener('beforeunload', flush)
      }
      flush()
      if (storageKey) {
        const bucket = activeDraftCancels.get(storageKey)
        bucket?.delete(cancelPendingPersistence)
        if (bucket?.size === 0) activeDraftCancels.delete(storageKey)
      }
      title[Symbol.dispose]()
      body?.[Symbol.dispose]()
      properties?.[Symbol.dispose]()
    }
  })

  return {
    title,
    body: () => body,
    properties: () => properties,
    storageError,
    hasUnsavedChanges,
    recovery,
    flush,
    load(id: string, xml: string, revision: number, remoteTitle: string) {
      let stored: Record<string, unknown> | undefined
      if (source !== id && storageKey) {
        const memSnapshot = inMemoryDrafts.get(storageKey)
        if (memSnapshot !== undefined) {
          stored = memSnapshot
        } else {
          try {
            stored = recordValue(safeJsonParse(sessionStorage.getItem(storageKey) ?? '').unwrapOr(undefined))
          } catch {
            storageError.value = true
          }
        }
      }
      title.load(id, remoteTitle, stored)
      body?.load(id, xml, revision, stored)
      if (
        source !== id &&
        properties &&
        body &&
        typeof stored?.xml === 'string' &&
        typeof stored.savedXML === 'string' &&
        typeof stored.revision === 'number' &&
        properties.restore(stored.knowledge)
      ) {
        body.xml.value = stored.xml
        body.savedXML.value = stored.savedXML
        body.revision.value = stored.revision
        body.recoveryDrafts.value = body.recoveryDrafts.value.filter(value => value !== stored.xml)
      }
      source = id
    },
    persist() {
      if (!storageKey || !source) return
      if (!hasUnsavedChanges.value) {
        cancelPendingPersistence()
        inMemoryDrafts.delete(storageKey)
        try {
          sessionStorage.removeItem(storageKey)
          storageError.value = false
        } catch {
          storageError.value = true
        }
        return
      }
      const snapshot = recovery.value
      pendingSnapshot = snapshot
      setInMemoryDraft(storageKey, snapshot)
      try {
        void sessionStorage
        storageError.value = false
      } catch {
        storageError.value = true
        return
      }
      clearPendingTimer()
      debounceTimer = setTimeout(() => {
        debounceTimer = undefined
        flush()
      }, PERSIST_DEBOUNCE_MS)
    },
    discard() {
      title.discard()
      body?.discard()
      properties?.finish()
    }
  }
})
