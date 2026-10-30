import { batch, signal, type ReadonlySignal, type Signal } from '@preact/signals-react'
import type { QueryClient } from '@tanstack/react-query'
import type { MentionTarget } from '@ankole/block-editor/editor'
import i18n from '../../common/i18n'
import { podRouteID } from '../../common/browser-context'
import {
  pageAPI,
  type MentionCandidatesResponse,
  type MentionsResolveInput,
  type MentionsResolveResponse
} from '../content-api'
import { pageMetadata } from './page-metadata'

export type ResolvedPageMention = MentionsResolveResponse['pages'][number]
export type ResolvedPrincipalMention = MentionsResolveResponse['principals'][number]
export type PageCandidate = MentionCandidatesResponse['pages'][number]

const MAX_BATCH_IDS = 200

type PendingBatch = {
  pages: Set<string>
  principals: Set<string>
}

const principalKey = (uid: string, contextPageID?: string) => JSON.stringify([contextPageID ?? '', uid])

export class MentionStore {
  readonly spaceName = signal('')
  private readonly pages = new Map<string, Signal<ResolvedPageMention | undefined>>()
  private readonly principals = new Map<string, Signal<ResolvedPrincipalMention | undefined>>()
  private readonly fetchedPages = new Set<string>()
  private readonly fetchedPrincipals = new Set<string>()
  private readonly inflightPages = new Set<string>()
  private readonly inflightPrincipals = new Set<string>()
  private readonly observedPages = new Map<string, { count: number; contextPageID?: string }>()
  private readonly observedPrincipals = new Map<string, { uid: string; count: number; contextPageID?: string }>()
  private readonly pendingByContext = new Map<string, PendingBatch>()
  private flushScheduled = false
  private readonly resolveFn: (body: MentionsResolveInput) => Promise<MentionsResolveResponse>

  constructor(
    resolveFn: (body: MentionsResolveInput) => Promise<MentionsResolveResponse> = body => pageAPI.resolveMentions(body)
  ) {
    this.resolveFn = resolveFn
  }

  pageSignal(id: string): ReadonlySignal<ResolvedPageMention | undefined> {
    return this.getOrCreatePageSignal(id)
  }

  principalSignal(uid: string, contextPageID?: string): ReadonlySignal<ResolvedPrincipalMention | undefined> {
    return this.getOrCreatePrincipalSignal(uid, contextPageID)
  }

  peekPage(id: string): ResolvedPageMention | undefined {
    return this.pages.get(id)?.peek()
  }

  peekPrincipal(uid: string, contextPageID?: string): ResolvedPrincipalMention | undefined {
    return this.principals.get(principalKey(uid, contextPageID))?.peek()
  }

  observePage(id: string, contextPageID?: string): () => void {
    const entry = this.observedPages.get(id)
    if (entry) {
      entry.count += 1
      if (contextPageID) entry.contextPageID = contextPageID
    } else {
      this.observedPages.set(id, { count: 1, contextPageID })
    }
    this.ensurePage(id, contextPageID)
    return () => {
      const current = this.observedPages.get(id)
      if (!current) return
      current.count -= 1
      if (current.count <= 0) this.observedPages.delete(id)
    }
  }

  observePrincipal(uid: string, contextPageID?: string): () => void {
    const key = principalKey(uid, contextPageID)
    const entry = this.observedPrincipals.get(key)
    if (entry) {
      entry.count += 1
    } else {
      this.observedPrincipals.set(key, { uid, count: 1, contextPageID })
    }
    this.ensurePrincipal(uid, contextPageID)
    return () => {
      const current = this.observedPrincipals.get(key)
      if (!current) return
      current.count -= 1
      if (current.count <= 0) this.observedPrincipals.delete(key)
    }
  }

  ensurePage(id: string, contextPageID?: string): void {
    this.getOrCreatePageSignal(id)
    if (this.fetchedPages.has(id) || this.inflightPages.has(id)) return
    this.enqueue(contextPageID).pages.add(id)
    this.scheduleFlush()
  }

  ensurePrincipal(uid: string, contextPageID?: string): void {
    this.getOrCreatePrincipalSignal(uid, contextPageID)
    const key = principalKey(uid, contextPageID)
    if (this.fetchedPrincipals.has(key) || this.inflightPrincipals.has(key)) return
    this.enqueue(contextPageID).principals.add(uid)
    this.scheduleFlush()
  }

  primeCandidates(response: MentionCandidatesResponse, contextPageID?: string): void {
    batch(() => {
      if (response.space_name) this.spaceName.value = response.space_name
      for (const candidate of response.pages) {
        const sig = this.getOrCreatePageSignal(candidate.id)
        const existing = sig.peek()
        if (!existing || existing.access === 'restricted') {
          sig.value = {
            id: candidate.id,
            access: 'ok',
            type: candidate.type,
            title: candidate.title,
            icon: candidate.icon ?? null,
            private_owner_uid: candidate.private_owner_uid ?? null,
            ancestors: candidate.ancestors,
            updated_at: candidate.updated_at,
            excerpt: existing?.excerpt ?? null,
            file: existing?.file ?? null
          }
          // Still allow full resolution to populate `excerpt` / `file` on mount.
        } else if (existing.access === 'ok') {
          sig.value = {
            ...existing,
            ancestors: candidate.ancestors,
            updated_at: candidate.updated_at
          }
        }
      }
      for (const candidate of response.principals) {
        const sig = this.getOrCreatePrincipalSignal(candidate.principal_uid, contextPageID)
        sig.value = {
          ...candidate,
          access: 'ok'
        }
        this.fetchedPrincipals.add(principalKey(candidate.principal_uid, contextPageID))
      }
    })
  }

  revalidateObserved(): void {
    this.fetchedPages.clear()
    this.fetchedPrincipals.clear()
    for (const [id, info] of this.observedPages) {
      if (!this.inflightPages.has(id)) {
        this.enqueue(info.contextPageID).pages.add(id)
      }
    }
    for (const [key, info] of this.observedPrincipals) {
      if (!this.inflightPrincipals.has(key)) {
        this.enqueue(info.contextPageID).principals.add(info.uid)
      }
    }
    this.scheduleFlush()
  }

  private getOrCreatePageSignal(id: string): Signal<ResolvedPageMention | undefined> {
    let sig = this.pages.get(id)
    if (!sig) {
      sig = signal<ResolvedPageMention | undefined>(undefined)
      this.pages.set(id, sig)
    }
    return sig
  }

  private getOrCreatePrincipalSignal(
    uid: string,
    contextPageID?: string
  ): Signal<ResolvedPrincipalMention | undefined> {
    const key = principalKey(uid, contextPageID)
    let sig = this.principals.get(key)
    if (!sig) {
      sig = signal<ResolvedPrincipalMention | undefined>(undefined)
      this.principals.set(key, sig)
    }
    return sig
  }

  private enqueue(contextPageID?: string): PendingBatch {
    const key = contextPageID ?? ''
    let pending = this.pendingByContext.get(key)
    if (!pending) {
      pending = { pages: new Set(), principals: new Set() }
      this.pendingByContext.set(key, pending)
    }
    return pending
  }

  private scheduleFlush(): void {
    if (this.flushScheduled) return
    this.flushScheduled = true
    queueMicrotask(() => {
      this.flushScheduled = false
      void this.flush()
    })
  }

  private async flush(): Promise<void> {
    const batches = [...this.pendingByContext.entries()]
    this.pendingByContext.clear()
    await Promise.all(
      batches.map(async ([contextKey, pending]) => {
        const pageIDs = [...pending.pages].filter(id => !this.fetchedPages.has(id) && !this.inflightPages.has(id))
        const principalUIDs = [...pending.principals].filter(
          uid =>
            !this.fetchedPrincipals.has(principalKey(uid, contextKey)) &&
            !this.inflightPrincipals.has(principalKey(uid, contextKey))
        )
        if (pageIDs.length === 0 && principalUIDs.length === 0) return

        for (const id of pageIDs) this.inflightPages.add(id)
        for (const uid of principalUIDs) this.inflightPrincipals.add(principalKey(uid, contextKey))

        const chunks = Math.max(
          Math.ceil(pageIDs.length / MAX_BATCH_IDS),
          Math.ceil(principalUIDs.length / MAX_BATCH_IDS),
          1
        )

        try {
          for (let i = 0; i < chunks; i++) {
            const pageSlice = pageIDs.slice(i * MAX_BATCH_IDS, (i + 1) * MAX_BATCH_IDS)
            const principalSlice = principalUIDs.slice(i * MAX_BATCH_IDS, (i + 1) * MAX_BATCH_IDS)
            const response = await this.resolveFn({
              page_ids: pageSlice,
              principal_uids: principalSlice,
              ...(contextKey ? { context_page_id: contextKey } : {})
            })
            batch(() => {
              if (response.space_name) this.spaceName.value = response.space_name
              for (const resolved of response.pages) {
                this.getOrCreatePageSignal(resolved.id).value = resolved
                this.fetchedPages.add(resolved.id)
              }
              for (const resolved of response.principals) {
                this.getOrCreatePrincipalSignal(resolved.principal_uid, contextKey).value = resolved
                this.fetchedPrincipals.add(principalKey(resolved.principal_uid, contextKey))
              }
            })
          }
        } catch {
          // Leave unfetched so subsequent revalidations or remounts can retry cleanly.
        } finally {
          for (const id of pageIDs) this.inflightPages.delete(id)
          for (const uid of principalUIDs) this.inflightPrincipals.delete(principalKey(uid, contextKey))
        }
      })
    )
  }
}

const stores = new WeakMap<QueryClient, MentionStore>()

export function mentionStore(client: QueryClient): MentionStore {
  let store = stores.get(client)
  if (!store) {
    store = new MentionStore(body =>
      pageMetadata(client).read(
        () => pageAPI.resolveMentions(body),
        result =>
          result.pages.flatMap(page =>
            page.access !== 'restricted' && typeof page.title === 'string'
              ? [{ id: page.id, title: page.title, icon: page.icon }]
              : []
          )
      )
    )
    stores.set(client, store)
  }
  return store
}

export function revalidateMentions(client: QueryClient): void {
  stores.get(client)?.revalidateObserved()
}

export function matchPodPageUrl(rawUrl: string, currentOrigin?: string): string | null {
  const origin = currentOrigin ?? (typeof window !== 'undefined' ? window.location.origin : '')
  if (!origin) return null
  let parsed: URL
  try {
    parsed = new URL(rawUrl.trim())
  } catch {
    return null
  }
  if ((parsed.protocol !== 'http:' && parsed.protocol !== 'https:') || parsed.origin !== origin) {
    return null
  }
  if (parsed.search !== '' || parsed.hash !== '') return null
  const match = /^\/pages\/([^/?#]+)\/?$/.exec(parsed.pathname)
  if (!match?.[1]) return null
  return podRouteID(match[1]) ?? null
}

export function readPageMention(client: QueryClient, id: string): ResolvedPageMention | undefined {
  const snapshot = mentionStore(client).peekPage(id)
  if (!snapshot || snapshot.access === 'restricted') return snapshot
  const live = pageMetadata(client).collection.get(id)
  if (!live) return snapshot
  return {
    ...snapshot,
    title: live.title ?? snapshot.title,
    icon: live.icon === undefined ? snapshot.icon : live.icon
  }
}

export function mentionPlainText(client: QueryClient, target: MentionTarget, contextPageID?: string): string {
  const store = mentionStore(client)
  if ('page' in target) {
    const resolved = readPageMention(client, target.page)
    if (resolved && (resolved.access === 'ok' || resolved.access === 'trashed')) {
      return (resolved.title ?? '').trim() || i18n.t('pod.content.untitled') || 'Untitled'
    }
    return i18n.t('pod.mention.restricted_page', { defaultValue: 'Restricted page' }) || 'Restricted page'
  }
  const resolved = store.peekPrincipal(target.principal, contextPageID)
  if (resolved && (resolved.access === 'ok' || resolved.access === 'disabled')) {
    return `@${(resolved.name ?? '').trim() || target.principal}`
  }
  return `@${i18n.t('pod.mention.restricted_principal', { defaultValue: 'Restricted user' }) || 'Restricted user'}`
}
