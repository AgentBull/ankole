import type { trackCommentSelection } from '@ankole/block-editor/editor'
import { batch, createModel, signal } from '@preact/signals-react'
import { recordValue, safeJsonParse } from '@agentbull/active-support'

type CommentAnchor = { quote: string; read?: ReturnType<typeof trackCommentSelection> }

/** Drafts outlive a closed thread and failed requests, but never select a different quote implicitly. */
export const PageCommentsModel = createModel((storageKey: string) => {
  let stored: Record<string, unknown> | undefined
  try {
    stored = recordValue(safeJsonParse(localStorage.getItem(storageKey) ?? '').unwrapOr(undefined))
  } catch {
    // Browsers may block storage; the open page still keeps its drafts.
  }
  const initial = recordValue(stored?.drafts) ?? {}
  const drafts = signal<Record<string, string>>(
    Object.fromEntries(
      Object.entries(initial).filter((entry): entry is [string, string] => typeof entry[1] === 'string')
    )
  )
  const editVersions = signal<Record<string, number>>(
    Object.fromEntries(
      Object.entries(recordValue(stored?.editVersions) ?? {}).filter(
        (entry): entry is [string, number] => Number.isSafeInteger(entry[1]) && Number(entry[1]) >= 0
      )
    )
  )
  const anchor = signal<CommentAnchor | null>(typeof stored?.quote === 'string' ? { quote: stored.quote } : null)
  const persist = () => {
    try {
      const versions = editVersions.peek()
      const persistedDrafts = Object.fromEntries(
        Object.entries(drafts.peek()).filter(([key, value]) => Object.hasOwn(versions, key) || value.trim() !== '')
      )
      const quote = anchor.peek()?.quote
      if (Object.keys(persistedDrafts).length === 0 && Object.keys(versions).length === 0 && !quote) {
        localStorage.removeItem(storageKey)
        return
      }
      localStorage.setItem(storageKey, JSON.stringify({ drafts: persistedDrafts, editVersions: versions, quote }))
    } catch {
      // Submission and local editing do not depend on storage availability.
    }
  }
  const consume = (key: string) => {
    const remaining = { ...drafts.value }
    const versions = { ...editVersions.value }
    delete remaining[key]
    delete versions[key]
    drafts.value = remaining
    editVersions.value = versions
  }
  return {
    drafts,
    editVersions,
    anchor,
    write(key: string, body: string) {
      drafts.value = { ...drafts.value, [key]: body }
      persist()
    },
    capture(value: CommentAnchor | null) {
      anchor.value = value
      persist()
    },
    beginEdit(key: string, body: string, version: number) {
      if (Object.hasOwn(drafts.value, key)) return
      batch(() => {
        drafts.value = { ...drafts.value, [key]: body }
        editVersions.value = { ...editVersions.value, [key]: version }
      })
      persist()
    },
    reviewEdit(key: string, version: number) {
      if (!Object.hasOwn(drafts.value, key)) return
      editVersions.value = { ...editVersions.value, [key]: version }
      persist()
    },
    edited(key: string, submitted: string, submittedVersion: number, savedVersion: number) {
      const sameVersion = editVersions.value[key] === submittedVersion
      const consumed = sameVersion && drafts.value[key] === submitted
      batch(() => {
        if (consumed) consume(key)
        else if (sameVersion) editVersions.value = { ...editVersions.value, [key]: savedVersion }
      })
      persist()
      return consumed
    },
    sent(key: string, submitted: string, submittedAnchor?: CommentAnchor | null) {
      batch(() => {
        const consumed = drafts.value[key] === submitted && (key !== 'new' || anchor.value === submittedAnchor)
        if (!consumed) return
        consume(key)
        if (key === 'new') anchor.value = null
      })
      persist()
    }
  }
})
