import { signal } from '@preact/signals-react'

export type PanelWidthStorage = Pick<Storage, 'getItem' | 'setItem'>

export function browserStorage(): PanelWidthStorage | undefined {
  try {
    return typeof window === 'undefined' ? undefined : window.localStorage
  } catch {
    return undefined
  }
}

/**
 * The width of a panel that the viewer resizes by dragging its edge. The panel reads the width that this browser last
 * saved, a drag previews each width in memory, and the end of the drag saves the width. Storage is a convenience: a
 * browser that blocks it still resizes the panel, and a width that is missing, unreadable, or out of range falls
 * back to `initial` or the nearest bound.
 */
export function panelWidth(
  { storageKey, min, max, initial }: { storageKey: string; min: number; max: number; initial: number },
  storage: PanelWidthStorage | undefined
) {
  const normalize = (raw?: string | number | null) => {
    if (raw === null || raw === undefined || raw === '') return initial
    const value = Number(raw)
    if (!Number.isFinite(value)) return initial
    return Math.min(max, Math.max(min, Math.round(value)))
  }
  let saved: string | null = null
  try {
    saved = storage?.getItem(storageKey) ?? null
  } catch {
    // The panel remains usable when storage is unavailable.
  }
  const width = signal(normalize(saved))

  const update = (next: string | number, persist: boolean) => {
    const normalized = normalize(next)
    width.value = normalized
    if (!persist) return
    try {
      storage?.setItem(storageKey, String(normalized))
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
}
