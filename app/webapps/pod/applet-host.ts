import { t } from 'i18next'
import type { AppletRuntime } from '@ankole/applet-sdk'
import { InternalAPIError } from '../common/internal-api-client'
import { authenticationRef, principalUID } from '../common/browser-context'
import { createAppletRoutes } from './applet-routes'

type AppletProvider = {
  render(options: { dom: Element; props: { runtime: AppletRuntime } }): void
  destroy(options: { dom: Element }): void
}
type MountedFrame = {
  prepare(): void
  mount(provider: AppletProvider): void
  changed(): void
  error(error: unknown): void
}
type AppletHostWindow = Window & {
  __ANKOLE_APPLET_HOST__?: {
    prepare(frame: Window): void
    mount(frame: Window, provider: AppletProvider): void
    changed(frame: Window): void
    error(frame: Window, error: unknown): void
  }
}
const frames = new WeakMap<Window, MountedFrame>()

function host() {
  return ((window as AppletHostWindow).__ANKOLE_APPLET_HOST__ ??= {
    prepare: frame => frames.get(frame)?.prepare(),
    mount: (frame, provider) => frames.get(frame)?.mount(provider),
    changed: frame => frames.get(frame)?.changed(),
    error: (frame, error) => frames.get(frame)?.error(error)
  })
}

function appletStorage(storage: Storage, principal: string, pageID: string): Storage {
  const prefix = `ankole:applet:${principal}:${pageID}:`
  const keys = () => Object.keys(storage).filter(key => key.startsWith(prefix))
  const scoped: Storage = {
    get length() {
      return keys().length
    },
    key: index => keys()[index]?.slice(prefix.length) ?? null,
    getItem: key => storage.getItem(prefix + key),
    setItem: (key, value) => storage.setItem(prefix + key, value),
    removeItem: key => storage.removeItem(prefix + key),
    clear() {
      for (const key of keys()) storage.removeItem(key)
    }
  }
  const prototype = Object.getPrototypeOf(storage)
  return new Proxy(storage, {
    get(_target, key) {
      if (Object.hasOwn(scoped, key)) return Reflect.get(scoped, key)
      if (typeof key !== 'string' || Reflect.has(prototype, key)) return Reflect.get(storage, key, storage)
      return scoped.getItem(key) ?? undefined
    },
    set(_target, key, value) {
      if (typeof key !== 'string') return Reflect.set(storage, key, value, storage)
      scoped.setItem(key, value)
      return true
    },
    deleteProperty(_target, key) {
      if (typeof key !== 'string') return Reflect.deleteProperty(storage, key)
      scoped.removeItem(key)
      return true
    },
    has(_target, key) {
      return (
        Object.hasOwn(scoped, key) ||
        Reflect.has(prototype, key) ||
        (typeof key === 'string' && scoped.getItem(key) !== null)
      )
    },
    ownKeys: () => keys().map(key => key.slice(prefix.length)),
    getOwnPropertyDescriptor(_target, key) {
      const value = typeof key === 'string' ? scoped.getItem(key) : null
      return value === null ? undefined : { value, writable: true, enumerable: true, configurable: true }
    }
  })
}

function appletFrameURL(pageID: string, revision: number) {
  const reference = authenticationRef()
  if (!reference) throw new Error('The applet requires this document’s authenticated session')
  return `/pod/applet-frame/${encodeURIComponent(reference)}/${encodeURIComponent(pageID)}/${revision}/index.html`
}

/** One mount owns one publication and all resources created by that generation. */
export function mountApplet(
  pageID: string,
  revision: number,
  container: HTMLElement,
  runtime: Omit<AppletRuntime, 'revision' | 'routes'>,
  onError: (error: unknown) => void,
  onReady?: () => void,
  onRevisionChanged?: () => void
) {
  const principal = principalUID()
  if (!principal) throw new Error('The applet requires this document’s authenticated Principal')
  host()
  const frame = document.createElement('iframe')
  frame.title = t('pod.content.applet')
  frame.className = 'block w-full min-h-32 border-0'
  const viewport = container.closest<HTMLElement>('.pod-page-scroll')
  const resize = () => {
    frame.style.height = `${Math.max(128, viewport?.clientHeight ?? window.innerHeight)}px`
  }
  resize()
  frame.src = appletFrameURL(pageID, revision)
  container.append(frame)
  const frameWindow = frame.contentWindow!
  let disposed = false
  let provider: AppletProvider | undefined
  let observer: ResizeObserver | undefined
  const cleanup = new Set<() => void>()
  const controller = new AbortController()
  const current = () => {
    if (disposed) throw new Error('This applet publication is inactive')
  }
  const changed = () => {
    if (disposed) return
    dispose()
    onRevisionChanged?.()
  }
  const report = (error: unknown) => {
    if (disposed) return
    void fetch(frame.src, { credentials: 'same-origin', signal: controller.signal })
      .then(response => {
        if (disposed) return
        if (response.status === 409) changed()
        else onError(error)
      })
      .catch(() => {
        if (!disposed) onError(error)
      })
  }
  const base = {
    ...runtime.base,
    schema(tableID: string) {
      current()
      return runtime.base.schema(tableID)
    },
    records(...args: Parameters<AppletRuntime['base']['records']>) {
      current()
      return runtime.base.records(...args)
    },
    aggregate(...args: Parameters<AppletRuntime['base']['aggregate']>) {
      current()
      return runtime.base.aggregate(...args)
    },
    async write(...args: Parameters<AppletRuntime['base']['write']>) {
      current()
      return runtime.base.write(...args)
    },
    subscribe(tableID: string, callback: Parameters<AppletRuntime['base']['subscribe']>[1]) {
      current()
      const unsubscribe = runtime.base.subscribe(tableID, event => {
        if (!disposed) callback(event)
      })
      const stop = () => {
        cleanup.delete(stop)
        unsubscribe()
      }
      cleanup.add(stop)
      return stop
    }
  }
  const routes = createAppletRoutes(pageID, revision, changed)
  let bound: AppletRuntime = {
    ...runtime,
    get principal() {
      return runtime.principal
    },
    get theme() {
      return runtime.theme
    },
    revision,
    base,
    routes: {
      key: routes.key,
      call(request) {
        current()
        return routes.call(request)
      }
    },
    pod: {
      request(...args) {
        current()
        return runtime.pod.request(...args)
      }
    },
    channel(name) {
      current()
      const channel = runtime.channel(name)
      const close = () => {
        cleanup.delete(close)
        channel.close()
      }
      cleanup.add(close)
      return { ...channel, close }
    }
  }
  frames.set(frameWindow, {
    prepare() {
      if (disposed) return
      Object.defineProperty(frameWindow, 'localStorage', {
        value: appletStorage(frameWindow.localStorage, principal, pageID),
        configurable: true
      })
      Object.defineProperty(frameWindow, 'sessionStorage', {
        value: appletStorage(frameWindow.sessionStorage, principal, pageID),
        configurable: true
      })
      const doc = frameWindow.document
      doc.documentElement.lang = document.documentElement.lang
      const syncTheme = () => {
        if (runtime.theme) doc.documentElement.dataset.theme = runtime.theme
        else delete doc.documentElement.dataset.theme
      }
      syncTheme()
      const theme = new MutationObserver(syncTheme)
      theme.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] })
      cleanup.add(() => theme.disconnect())
      const error = (event: Event) => {
        if (disposed) return
        if ('message' in event) {
          const failure = event as ErrorEvent
          report(failure.error ?? new Error(failure.message))
        } else if ((event.target as Element | null)?.tagName === 'SCRIPT') {
          report(new Error(t('pod.content.the_applet_could_not_be_loaded')))
        }
      }
      frameWindow.addEventListener('error', error, true)
      cleanup.add(() => frameWindow.removeEventListener('error', error, true))
      const rejected = (event: PromiseRejectionEvent) => {
        if (!disposed) report(event.reason)
      }
      frameWindow.addEventListener('unhandledrejection', rejected)
      cleanup.add(() => frameWindow.removeEventListener('unhandledrejection', rejected))
    },
    mount(entry) {
      if (disposed || provider) return
      try {
        provider = entry
        const doc = frameWindow.document
        provider.render({ dom: doc.body, props: { runtime: bound } })
        observer = new ResizeObserver(resize)
        observer.observe(viewport ?? document.documentElement)
        window.addEventListener('resize', resize, { signal: controller.signal })
        resize()
        onReady?.()
      } catch (error) {
        report(error)
      }
    },
    changed,
    error: report
  })
  frame.addEventListener(
    'load',
    () => {
      if (disposed || provider) return
      void fetch(frame.src, { credentials: 'same-origin', signal: controller.signal })
        .then(response => {
          if (disposed || provider) return
          if (response.status === 409) changed()
          else if (!response.ok) onError(new InternalAPIError(response.status, response.statusText, {}))
        })
        .catch(error => {
          if (!disposed) onError(error)
        })
    },
    { signal: controller.signal }
  )
  function dispose() {
    if (disposed) return
    disposed = true
    controller.abort()
    frames.delete(frameWindow)
    observer?.disconnect()
    for (const close of cleanup) close()
    cleanup.clear()
    try {
      provider?.destroy({ dom: frameWindow.document.body })
    } finally {
      frame.remove()
    }
  }
  return {
    dispose,
    update(next: Omit<AppletRuntime, 'revision' | 'routes'>) {
      if (disposed || next.pageID !== pageID) return
      bound = { ...bound, actions: next.actions }
      if (!provider) return
      try {
        provider.render({ dom: frameWindow.document.body, props: { runtime: bound } })
      } catch (error) {
        report(error)
      }
    }
  }
}
