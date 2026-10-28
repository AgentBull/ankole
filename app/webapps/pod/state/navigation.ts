import { recordValue, safeJsonParse } from '@agentbull/active-support'
import { createModel, signal } from '@preact/signals-react'

export type NavigationScope = 'space' | 'private'
export type CollapsibleSection = NavigationScope | 'recent' | 'favorites'

export type RecentEntry<
  P extends { id: string; visited_at?: string | null; updated_at?: string },
  R extends { id: string; lastActivityAt?: string | null }
> =
  | { kind: 'page'; id: string; timestamp: string | undefined; time: number; page: P }
  | { kind: 'conversation'; id: string; timestamp: string | undefined; time: number; room: R }

export function mergeRecentEntries<
  P extends { id: string; visited_at?: string | null; updated_at?: string },
  R extends { id: string; lastActivityAt?: string | null }
>(pages: P[], conversations: R[]): RecentEntry<P, R>[] {
  const entries: RecentEntry<P, R>[] = [
    ...pages.map((page): RecentEntry<P, R> => {
      const timestamp = page.visited_at ?? page.updated_at
      const parsed = timestamp ? Date.parse(timestamp) : NaN
      return { kind: 'page', id: page.id, timestamp, time: Number.isNaN(parsed) ? 0 : parsed, page }
    }),
    ...conversations.map((room): RecentEntry<P, R> => {
      const timestamp = room.lastActivityAt ?? undefined
      const parsed = timestamp ? Date.parse(timestamp) : NaN
      return { kind: 'conversation', id: room.id, timestamp, time: Number.isNaN(parsed) ? 0 : parsed, room }
    })
  ]
  return entries.sort((left, right) => right.time - left.time || left.id.localeCompare(right.id))
}

type Preferences = { rootOpen: Record<CollapsibleSection, boolean>; expanded: Set<string> }
type PreferenceStorage = Pick<Storage, 'getItem' | 'setItem'>

function browserStorage(): PreferenceStorage | undefined {
  try {
    return typeof window === 'undefined' ? undefined : window.localStorage
  } catch {
    return undefined
  }
}

function decode(raw: string | null): Preferences {
  const saved = raw ? recordValue(safeJsonParse(raw).unwrapOr(undefined)) : undefined
  const rootOpen = recordValue(saved?.rootOpen)
  return {
    rootOpen: {
      recent: rootOpen?.recent !== false,
      favorites: rootOpen?.favorites !== false,
      space: rootOpen?.space !== false,
      private: rootOpen?.private !== false
    },
    expanded: new Set<string>(
      Array.isArray(saved?.expanded) ? saved.expanded.filter((id: unknown) => typeof id === 'string' && id) : []
    )
  }
}

/** One document's navigation choices. Page data and permissions stay in the remote cache. */
export const NavigationModel = createModel(
  (pod?: string, identity?: string, storage: PreferenceStorage | undefined = browserStorage()) => {
    const storageKey = pod && identity ? `ankole.pod.navigation:${pod}:${identity}` : undefined
    let initial: string | null = null
    try {
      if (storageKey) initial = storage?.getItem(storageKey) ?? null
    } catch {
      // Storage may be blocked. Navigation remains available for this document.
    }
    const preferences = signal(decode(initial))
    const save = (next: Preferences) => {
      preferences.value = next
      try {
        if (storageKey) {
          storage?.setItem(storageKey, JSON.stringify({ rootOpen: next.rootOpen, expanded: [...next.expanded] }))
        }
      } catch {
        // A failed preference write must not undo the user's local choice.
      }
    }
    return {
      storageKey() {
        return storageKey
      },
      preferences,
      restore(raw: string | null) {
        preferences.value = decode(raw)
      },
      toggleRoot(scope: CollapsibleSection) {
        const current = preferences.peek()
        save({ ...current, rootOpen: { ...current.rootOpen, [scope]: !current.rootOpen[scope] } })
      },
      togglePage(id: string) {
        const current = preferences.peek()
        const expanded = new Set(current.expanded)
        if (expanded.has(id)) expanded.delete(id)
        else expanded.add(id)
        save({ ...current, expanded })
      }
    }
  }
)
