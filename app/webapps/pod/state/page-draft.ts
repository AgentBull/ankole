import { computed, createModel, effect, signal } from '@preact/signals-react'
import { recordValue, safeJsonParse } from '@agentbull/active-support'
import type { Page } from '../content-api'
import { DocumentDraftModel } from './document-draft'
import { KnowledgeDraftModel } from './knowledge-draft'
import { TitleDraftModel } from './title-draft'

/** A Page owns recovery and navigation; each editor owns its actual draft. */
export const PageDraftModel = createModel((type: Page['type'], storageKey?: string) => {
  const title = new TitleDraftModel()
  const body = type === 'doc' || type === 'knowledge' ? new DocumentDraftModel() : undefined
  const properties = type === 'knowledge' ? new KnowledgeDraftModel() : undefined
  const storageError = signal(false)
  let source = ''
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
  effect(() => () => {
    title[Symbol.dispose]()
    body?.[Symbol.dispose]()
    properties?.[Symbol.dispose]()
  })
  return {
    title,
    body: () => body,
    properties: () => properties,
    storageError,
    hasUnsavedChanges,
    recovery,
    load(id: string, xml: string, revision: number, remoteTitle: string) {
      let stored: Record<string, unknown> | undefined
      if (source !== id && storageKey) {
        try {
          stored = recordValue(safeJsonParse(sessionStorage.getItem(storageKey) ?? '').unwrapOr(undefined))
        } catch {
          storageError.value = true
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
      try {
        if (hasUnsavedChanges.value) sessionStorage.setItem(storageKey, JSON.stringify(recovery.value))
        else sessionStorage.removeItem(storageKey)
        storageError.value = false
      } catch {
        storageError.value = true
      }
    },
    discard() {
      title.discard()
      body?.discard()
      properties?.finish()
    }
  }
})
