import { t } from 'i18next'
import type { AppletRuntime, AppletTheme } from '@ankole/applet-sdk'
import { InternalAPIError } from '../common/internal-api-client'
import { authenticationRef, principalUID } from '../common/browser-context'
import { createAppletRoutes } from './applet-routes'

export function readDocumentTheme(
  doc: Document | undefined = typeof document === 'undefined' ? undefined : document
): AppletTheme {
  return doc?.documentElement.dataset.theme === 'dark' ? 'dark' : 'light'
}

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
  runtime: Omit<AppletRuntime, 'revision' | 'routes' | 'embedded'>,
  onError: (error: unknown) => void,
  onReady?: () => void,
  onRevisionChanged?: () => void
) {
  const principal = principalUID()
  if (!principal) throw new Error('The applet requires this document’s authenticated Principal')
  host()
  const frame = document.createElement('iframe')
  frame.title = t('pod.content.applet')
  frame.className = 'block w-full min-h-32 border-0 bg-transparent'
  let currentTheme = readDocumentTheme()
  frame.style.colorScheme = currentTheme
  const viewport = container.closest<HTMLElement>('.pod-page-scroll')
  // An Applet Page's gutters pad the frame's document, so they scroll with the Applet and its scrollbar reaches the
  // sheet's edge. An Applet embedded in a document has none.
  const pageStyle = getComputedStyle(container)
  const gutterTop = pageStyle.getPropertyValue('--pod-applet-gutter-top').trim()
  const gutterInline = pageStyle.getPropertyValue('--pod-applet-gutter-inline').trim()
  // A document gives an embedded Applet its content's height, up to the workspace panel's. Content laid out from the
  // viewport and an open modal dialog, drawer or sheet keep the whole panel.
  const embedded = !container.closest(".pod-page[data-page-type='applet']")
  let measure: (() => number | undefined) | undefined
  let modal = false
  let viewportSized = false
  let lastChange: { frame: number; content: number } | undefined
  const resize = () => {
    // A full-screen Applet section gives the frame the screen's height instead of the workspace panel's.
    const fullScreen = !!document.fullscreenElement?.contains(frame)
    const stage = fullScreen ? document.fullscreenElement : viewport
    const limit = Math.max(128, stage?.clientHeight ?? window.innerHeight)
    const content = embedded && !fullScreen && !modal && !viewportSized ? measure?.() : undefined
    // Content that changes by exactly as much as the frame just did follows the viewport, so it keeps the whole panel.
    if (lastChange && content !== undefined && Math.abs(content - lastChange.content - lastChange.frame) <= 2) {
      viewportSized = true
    }
    const height = content === undefined || viewportSized ? limit : Math.min(limit, Math.max(128, content))
    const previous = frame.offsetHeight
    lastChange =
      content !== undefined && Math.abs(height - previous) > 2 ? { frame: height - previous, content } : undefined
    frame.style.height = `${height}px`
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
  // An embedded frame follows its content's height and gives an open modal the whole panel.
  function fitContent(body: HTMLElement) {
    const frameGlobal = frameWindow as Window & typeof globalThis
    measure = () => {
      // The Applet has not rendered while its root is still empty.
      if (!body.querySelector(':scope > .ankole-applet > *')) return undefined
      const box = body.getBoundingClientRect()
      const margin = Number.parseFloat(frameGlobal.getComputedStyle(body).marginBottom) || 0
      return Math.ceil(Math.max(box.bottom, box.top + body.scrollHeight) + frameGlobal.scrollY + margin)
    }
    let scheduled = 0
    const update = () => {
      scheduled = 0
      const opened = !!body.querySelector('[data-slot$="-overlay"]')
      const expanding = opened && !modal
      modal = opened
      resize()
      // A modal centers in the frame, so the expanded frame comes fully into view.
      if (expanding) frame.scrollIntoView({ block: 'nearest' })
    }
    const schedule = () => {
      scheduled ||= frameGlobal.requestAnimationFrame(update)
    }
    const content = new frameGlobal.ResizeObserver(schedule)
    content.observe(body)
    // UIKit portals attach to the frame's body, so a modal's overlay arrives and leaves with a body child.
    const portals = new frameGlobal.MutationObserver(schedule)
    portals.observe(body, { childList: true })
    cleanup.add(() => {
      content.disconnect()
      portals.disconnect()
      frameGlobal.cancelAnimationFrame(scheduled)
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
    embedded,
    get principal() {
      return runtime.principal
    },
    theme: currentTheme,
    revision,
    base,
    runs: {
      key: runtime.runs.key,
      get(...args) {
        current()
        return runtime.runs.get(...args)
      },
      subscribe(runID, callback) {
        current()
        const unsubscribe = runtime.runs.subscribe(runID, event => {
          if (!disposed) callback(event)
        })
        const stop = () => {
          cleanup.delete(stop)
          unsubscribe()
        }
        cleanup.add(stop)
        return stop
      }
    },
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
      },
      fileURL(target) {
        current()
        return runtime.pod.fileURL(target)
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
      if (gutterTop) doc.documentElement.style.paddingTop = gutterTop
      if (gutterInline) doc.documentElement.style.paddingInline = gutterInline
      const syncTheme = () => {
        const nextTheme = readDocumentTheme()
        frame.style.colorScheme = nextTheme
        doc.documentElement.dataset.theme = nextTheme
        doc.documentElement.style.colorScheme = nextTheme
        if (nextTheme === currentTheme) return
        currentTheme = nextTheme
        bound = { ...bound, theme: nextTheme }
        if (!provider) return
        try {
          provider.render({ dom: doc.body, props: { runtime: bound } })
        } catch (error) {
          report(error)
        }
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
        document.addEventListener('fullscreenchange', resize, { signal: controller.signal })
        if (embedded) fitContent(doc.body)
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
    update(next: Omit<AppletRuntime, 'revision' | 'routes' | 'embedded'>) {
      if (disposed || next.pageID !== pageID) return
      bound = { ...bound, actions: next.actions, title: next.title, theme: currentTheme }
      if (!provider) return
      try {
        provider.render({ dom: frameWindow.document.body, props: { runtime: bound } })
      } catch (error) {
        report(error)
      }
    }
  }
}
