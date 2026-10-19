import { GarfishBrowserVm } from '@garfish/browser-vm'
import Garfish from '@garfish/core'
import { GarfishCssScope } from '@garfish/css-scope'
import * as react from 'react'
import * as jsxRuntime from 'react/jsx-runtime'
import * as jsxDevRuntime from 'react/jsx-dev-runtime'
import * as reactDom from 'react-dom'
import * as reactDomClient from 'react-dom/client'
import * as uikit from '@ankole/uikit'

/** One Garfish runtime per host page. Each React slot owns its application lifecycle. */
export function createHost() {
  const instance = new Garfish({ plugins: [GarfishBrowserVm(), GarfishCssScope()] })
  instance.setExternal({
    react,
    'react/jsx-runtime': jsxRuntime,
    'react/jsx-dev-runtime': jsxDevRuntime,
    'react-dom': reactDom,
    'react-dom/client': reactDomClient,
    '@ankole/uikit': uikit
  })
  // The CSS plugin installs its transformer in beforeBootstrap, which loadApp does not emit.
  instance.run()

  return {
    mount(name: string, entry: string, container: HTMLElement, onError: (message: string) => void) {
      let disposed = false
      let app: Awaited<ReturnType<typeof instance.loadApp>>
      let mountError: Error | undefined
      void (async () => {
        app = await instance.loadApp(name, {
          entry,
          cache: false,
          domGetter: () => container,
          sandbox: { strictIsolation: false },
          props: { applet: { react, uikit, instance: name } },
          errorMountApp(error) {
            mountError = error
          }
        })
        if (disposed) return
        if (!app) throw new Error('Garfish returned no application')
        if (!(await app.mount())) throw mountError ?? new Error('Garfish did not mount the applet')
        if (disposed) app.unmount()
      })().catch(error => {
        app?.unmount()
        if (!disposed) onError(error instanceof Error ? error.message : String(error))
      })
      return () => {
        disposed = true
        // React must finish its host commit before the separate applet root unmounts.
        queueMicrotask(() => app?.unmount())
      }
    }
  }
}

export type Host = ReturnType<typeof createHost>
