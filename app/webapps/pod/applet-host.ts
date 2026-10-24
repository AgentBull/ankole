import { t } from 'i18next'
import { GarfishBrowserVm } from '@garfish/browser-vm'
import Garfish from '@garfish/core'
import { GarfishCssScope } from '@garfish/css-scope'
import * as react from 'react'
import * as jsxRuntime from 'react/jsx-runtime'
import * as jsxDevRuntime from 'react/jsx-dev-runtime'
import * as reactDom from 'react-dom'
import * as reactDomClient from 'react-dom/client'
import * as uikit from '@ankole/uikit'
import * as sdk from '@ankole/applet-sdk'
import type { AppletRuntime } from '@ankole/applet-sdk'
import { fileURL } from './content-api'
import { createAppletRoutes } from './applet-routes'
import { podFiles } from './api/generated/sdk.gen'
import { InternalAPIError } from '../common/internal-api-client'

let host: Garfish | undefined
function garfish() {
  if (!host) {
    host = new Garfish({ plugins: [GarfishBrowserVm(), GarfishCssScope()] })
    host.setExternal({
      react,
      'react/jsx-runtime': jsxRuntime,
      'react/jsx-dev-runtime': jsxDevRuntime,
      'react-dom': reactDom,
      'react-dom/client': reactDomClient,
      '@ankole/uikit': uikit,
      '@ankole/applet-sdk': sdk
    })
    host.run()
  }
  return host
}

class PublicationChanged extends Error {}

/** Garfish's instance namespace changes on every mount; storage belongs to the applet page. */
function appletStorage(storage: Storage, pageID: string): Storage {
  const prefix = `ankole:applet:${pageID}:`
  const keys = () => Object.keys(storage).filter(key => key.startsWith(prefix))
  return {
    get length() {
      return keys().length
    },
    key(index) {
      return keys()[index]?.slice(prefix.length) ?? null
    },
    getItem(key) {
      return storage.getItem(prefix + key)
    },
    setItem(key, value) {
      storage.setItem(prefix + key, value)
    },
    removeItem(key) {
      storage.removeItem(prefix + key)
    },
    clear() {
      for (const key of keys()) storage.removeItem(key)
    }
  }
}

/** Download one complete publication before Garfish executes any of its resources. */
export async function appletPublication(pageID: string, signal: AbortSignal) {
  const manifest = await podFiles({ path: { id: pageID }, signal })
  const files = manifest.files.filter(file => file.path.startsWith('dist/'))
  const entry = files.find(file => file.path === 'dist/index.html')
  if (!entry) throw new Error(t('pod.content.this_applet_has_not_been_published_yet'))
  const urls = new Map<string, string>()
  const revoke = () => {
    for (const url of urls.values()) URL.revokeObjectURL(url)
  }
  try {
    const downloaded = await Promise.all(
      files.map(async file => {
        const response = await fetch(fileURL(pageID, file.path, file.sha256), { signal, credentials: 'same-origin' })
        if (response.status === 409) throw new PublicationChanged()
        if (!response.ok) {
          throw new InternalAPIError(response.status, response.statusText, {
            error: t('pod.content.could_not_load_the_applet_file', { value1: response.status })
          })
        }
        return {
          file,
          blob: new Blob([await response.arrayBuffer()], { type: file.content_type ?? 'application/octet-stream' })
        }
      })
    )
    if (signal.aborted) throw signal.reason
    for (const { file, blob } of downloaded) if (file !== entry) urls.set(file.path, URL.createObjectURL(blob))
    const html = new DOMParser().parseFromString(
      await downloaded.find(item => item.file === entry)!.blob.text(),
      'text/html'
    )
    for (const element of html.querySelectorAll('script[src],link[href]')) {
      const attribute = element.tagName === 'SCRIPT' ? 'src' : 'href'
      const original = element.getAttribute(attribute)!
      const path = new URL(original, 'https://applet.invalid/dist/index.html')
      if (path.origin !== 'https://applet.invalid') continue
      const immutable = urls.get(decodeURIComponent(path.pathname.slice(1)))
      if (!immutable) throw new Error(t('pod.content.the_applet_publication_manifest_is_missing', { value1: original }))
      element.setAttribute(attribute, immutable)
    }
    const url = URL.createObjectURL(
      new Blob([`<!doctype html>${html.documentElement.outerHTML}`], { type: 'text/html' })
    )
    urls.set(entry.path, url)
    return { revision: manifest.revision, entry: url, revoke }
  } catch (error) {
    revoke()
    throw error
  }
}

export function mountApplet(
  pageID: string,
  instanceID: string,
  container: HTMLElement,
  runtime: Omit<AppletRuntime, 'revision' | 'routes'>,
  onError: (error: unknown) => void,
  onReady?: () => void,
  onRevisionChanged?: () => void
) {
  const controller = new AbortController()
  let app: Awaited<ReturnType<Garfish['loadApp']>>
  let publication: Awaited<ReturnType<typeof appletPublication>> | undefined
  let disposed = false
  void (async () => {
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        publication = await appletPublication(pageID, controller.signal)
        break
      } catch (error) {
        if (!(error instanceof PublicationChanged) || attempt === 2) throw error
      }
    }
    if (disposed) {
      publication?.revoke()
      return
    }
    if (!publication) return
    let mountError: Error | undefined
    app = await garfish().loadApp(`${pageID}-${publication.revision}-${instanceID}`, {
      entry: publication.entry,
      cache: false,
      domGetter: () => container,
      sandbox: {
        strictIsolation: false,
        modules: [
          () => ({
            override: {
              localStorage: appletStorage(localStorage, pageID),
              sessionStorage: appletStorage(sessionStorage, pageID)
            }
          })
        ]
      },
      props: {
        runtime: {
          ...runtime,
          get principal() {
            return runtime.principal
          },
          get theme() {
            return runtime.theme
          },
          revision: publication.revision,
          routes: createAppletRoutes(pageID, publication.revision, () => {
            if (disposed) return
            // A rejected write is never replayed. Stop this version before requesting its replacement.
            app?.unmount()
            onRevisionChanged?.()
          })
        }
      },
      errorMountApp(error) {
        mountError = error
      }
    })
    if (disposed) {
      app?.unmount()
      return
    }
    if (!app || !(await app.mount())) throw mountError ?? new Error(t('pod.content.the_applet_could_not_be_loaded'))
    if (disposed) app.unmount()
    else onReady?.()
  })().catch(error => {
    app?.unmount()
    if (!disposed) onError(error)
  })
  return () => {
    disposed = true
    controller.abort()
    queueMicrotask(() => {
      app?.unmount()
      publication?.revoke()
    })
  }
}
