import type { OfficeSyncEngine } from '../office/office-collaboration'
import type {
  PresentationCommandInfo,
  PresentationFindMatch,
  PresentationRenderedSlide,
  PresentationSelection,
  PresentationSlideInfo,
  PresentationSnapshot,
  PresentationWorkerMethods,
  PresentationWorkerResponse
} from './presentation-worker'
// oxlint-disable-next-line import/default -- Vite's `?worker&url` query synthesizes a default URL export.
import workerSourceURL from './presentation-worker.ts?worker&url'

export type {
  PresentationCommandInfo,
  PresentationFindMatch,
  PresentationRenderedSlide,
  PresentationSelection,
  PresentationSlideInfo,
  PresentationSnapshot
}

export type PresentationEngine = OfficeSyncEngine<PresentationSnapshot> & {
  [K in keyof PresentationWorkerMethods]: (
    ...args: Parameters<PresentationWorkerMethods[K]>
  ) => Promise<ReturnType<PresentationWorkerMethods[K]>>
}

/**
 * Spawns one Presentation WebAssembly Worker per open presentation or preview and exposes its
 * methods as typed promises compatible with `OfficeCollaborationModel`.
 */
export function createPresentationEngine(): PresentationEngine {
  // When Vite or a CDN serves scripts from a different origin, bootstrap the module Worker from a
  // same-origin Blob so the browser Worker origin policy accepts it.
  const workerURL = new URL(workerSourceURL, import.meta.url)
  let bootstrapURL: string | undefined
  if (workerURL.origin !== location.origin) {
    bootstrapURL = URL.createObjectURL(
      new Blob([`import ${JSON.stringify(workerURL.href)};`], { type: 'text/javascript' })
    )
  }
  const worker = new Worker(bootstrapURL ?? workerURL, { type: 'module' })
  if (bootstrapURL) URL.revokeObjectURL(bootstrapURL)

  const pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>()
  let nextID = 0

  const failAll = (reason: string) => {
    const error = new Error(reason)
    for (const call of pending.values()) call.reject(error)
    pending.clear()
  }

  worker.onmessage = ({ data }: MessageEvent<PresentationWorkerResponse>) => {
    const call = pending.get(data.id)
    if (!call) return
    pending.delete(data.id)
    if ('error' in data) call.reject(new Error(data.error.message))
    else call.resolve(data.ok)
  }
  worker.onerror = event => failAll(event.message || 'The presentation worker stopped')

  const call = <K extends keyof PresentationWorkerMethods>(
    method: K,
    ...args: Parameters<PresentationWorkerMethods[K]>
  ): Promise<ReturnType<PresentationWorkerMethods[K]>> =>
    new Promise((resolve, reject) => {
      const id = ++nextID
      pending.set(id, {
        resolve: resolve as (value: unknown) => void,
        reject
      })
      worker.postMessage({ id, method, args })
    })

  return new Proxy(
    {
      dispose() {
        worker.terminate()
        failAll('The presentation was closed')
      }
    } as PresentationEngine,
    {
      get(target, prop) {
        if (prop in target) return target[prop as keyof typeof target]
        if (typeof prop !== 'string' || prop === 'then') return undefined
        return (...args: unknown[]) =>
          call(
            prop as keyof PresentationWorkerMethods,
            ...(args as Parameters<PresentationWorkerMethods[keyof PresentationWorkerMethods]>)
          )
      }
    }
  )
}
