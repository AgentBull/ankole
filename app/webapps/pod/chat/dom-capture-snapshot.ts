export interface CaptureSnapshot {
  dataUrl: string
  width: number
  height: number
  alt?: string
}

export type CaptureSnapshotProvider = () => Promise<CaptureSnapshot | null> | CaptureSnapshot | null

const SNAPSHOT_ATTR = 'data-capture-snapshot-id'
const providers = new Map<string, CaptureSnapshotProvider>()
let nextSnapshotSeq = 1

/**
 * Registers a live DOM element whose cross-origin / sandboxed `<iframe sandbox="">`
 * contents cannot be cloned directly by `XMLSerializer`, providing an equivalent
 * raster or SVG `data:` image snapshot during multi-select share card export.
 */
export function registerCaptureSnapshot(element: HTMLElement, provider: CaptureSnapshotProvider): () => void {
  const id = `snap-${nextSnapshotSeq++}`
  element.setAttribute(SNAPSHOT_ATTR, id)
  providers.set(id, provider)
  return () => {
    providers.delete(id)
    if (element.getAttribute(SNAPSHOT_ATTR) === id) {
      element.removeAttribute(SNAPSHOT_ATTR)
    }
  }
}

export function getCaptureSnapshotAttr(): string {
  return SNAPSHOT_ATTR
}

export async function resolveCaptureSnapshotsInSubtree(root: ParentNode): Promise<Map<string, CaptureSnapshot>> {
  const resolved = new Map<string, CaptureSnapshot>()
  const elements = root.querySelectorAll<HTMLElement>(`[${SNAPSHOT_ATTR}]`)

  await Promise.all(
    Array.from(elements).map(async el => {
      const id = el.getAttribute(SNAPSHOT_ATTR)
      if (!id || resolved.has(id)) return
      const provider = providers.get(id)
      if (!provider) return
      try {
        const snapshot = await provider()
        if (snapshot && snapshot.dataUrl) {
          resolved.set(id, snapshot)
        }
      } catch {
        // Leave fallback element untouched when a snapshot provider fails.
      }
    })
  )

  return resolved
}
