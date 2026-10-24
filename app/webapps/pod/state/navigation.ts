import { createModel, signal } from '@preact/signals-react'

export type NavigationScope = 'space' | 'private'
type Preferences = { rootOpen: Record<NavigationScope, boolean>; expanded: Set<string> }
type PreferenceStorage = Pick<Storage, 'getItem' | 'setItem'>

function browserStorage(): PreferenceStorage | undefined {
  try {
    return typeof window === 'undefined' ? undefined : window.localStorage
  } catch {
    return undefined
  }
}

function decode(raw: string | null): Preferences {
  try {
    const saved = JSON.parse(raw ?? 'null')
    return {
      rootOpen: { space: saved?.rootOpen?.space !== false, private: saved?.rootOpen?.private !== false },
      expanded: new Set<string>(
        Array.isArray(saved?.expanded) ? saved.expanded.filter((id: unknown) => typeof id === 'string' && id) : []
      )
    }
  } catch {
    return { rootOpen: { space: true, private: true }, expanded: new Set() }
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
      toggleRoot(scope: NavigationScope) {
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
