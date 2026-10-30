import { createModel, signal } from '@preact/signals-react'

export const POD_SIDEBAR_MIN_WIDTH = 248
export const POD_SIDEBAR_MAX_WIDTH = 480
const POD_SIDEBAR_WIDTH_STORAGE_KEY = 'ankole.pod.sidebar-width'

type SidebarWidthStorage = Pick<Storage, 'getItem' | 'setItem'>

function browserStorage(): SidebarWidthStorage | undefined {
  try {
    return typeof window === 'undefined' ? undefined : window.localStorage
  } catch {
    return undefined
  }
}

function normalizeSidebarWidth(raw?: string | number | null): number {
  if (raw === null || raw === undefined || raw === '') return POD_SIDEBAR_MIN_WIDTH
  const value = Number(raw)
  if (!Number.isFinite(value)) return POD_SIDEBAR_MIN_WIDTH
  return Math.min(POD_SIDEBAR_MAX_WIDTH, Math.max(POD_SIDEBAR_MIN_WIDTH, Math.round(value)))
}

export const SidebarLayoutModel = createModel((storage: SidebarWidthStorage | undefined = browserStorage()) => {
  let initial: string | null = null
  try {
    initial = storage?.getItem(POD_SIDEBAR_WIDTH_STORAGE_KEY) ?? null
  } catch {
    // The sidebar remains usable when storage is unavailable.
  }
  const width = signal(normalizeSidebarWidth(initial))

  const update = (next: string | number, persist: boolean) => {
    const normalized = normalizeSidebarWidth(next)
    width.value = normalized
    if (!persist) return
    try {
      storage?.setItem(POD_SIDEBAR_WIDTH_STORAGE_KEY, String(normalized))
    } catch {
      // A failed preference write must not undo the user's local choice.
    }
  }

  return {
    width,
    previewWidth(next: number) {
      update(next, false)
    },
    commitWidth(next: number) {
      update(next, true)
    }
  }
})
