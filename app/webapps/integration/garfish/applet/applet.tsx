/** The labeled SDK stand-in exports Garfish's named CommonJS provider. */
import * as React from 'react'
import { Component, useState, type ReactNode } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import * as uikit from '@ankole/uikit'
import { Button } from '@ankole/uikit'

declare const BUILD_REVISION: string
declare const FAIL_RENDER: boolean

type AppletProps = { react: typeof React; uikit: typeof uikit; instance: string }
type RenderArgs = { dom: Element; props: { applet: AppletProps } }
const roots = new WeakMap<Element, Root>()

function Applet({ host }: { host: AppletProps }) {
  if (FAIL_RENDER) throw new Error('applet render failure')
  const [count, setCount] = useState(0)
  const [global, setGlobal] = useState('')
  return (
    <section className="ankole-applet-box grid gap-2 p-4 rounded-lg" data-build={BUILD_REVISION}>
      <h2 className="applet-title">Applet tools</h2>
      <p className="applet-detail">{BUILD_REVISION}</p>
      <p className="shared-modules">
        {host.react.useState === React.useState && host.uikit.Button === Button ? 'shared' : 'duplicate'}
      </p>
      <Button onClick={() => setCount(value => value + 1)}>Increment</Button>
      <output className="applet-count">{count}</output>
      <Button onClick={() => setGlobal(String(Reflect.get(window, '__appletInstance')))}>Read global</Button>
      <output className="applet-global">{global}</output>
    </section>
  )
}

/** React errors are contained inside the applet root; Garfish handles load and lifecycle errors. */
class AppletBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false }
  static getDerivedStateFromError() {
    return { failed: true }
  }
  render() {
    return this.state.failed ? <p role="alert">Applet failed</p> : this.props.children
  }
}

export const provider = {
  render({ dom, props: { applet } }: RenderArgs) {
    Reflect.set(window, '__appletInstance', applet.instance)
    const telemetry = document.documentElement
    const record = (kind: string) => {
      const key = `${kind}-${applet.instance}`
      telemetry.setAttribute(`data-${key}`, String(Number(telemetry.getAttribute('data-' + key) ?? 0) + 1))
    }
    // Deliberately leave these effects to the sandbox so the check can prove its cleanup.
    window.setInterval(() => record('ticks'), 100)
    window.addEventListener('applet-probe', () => record('events'))
    const node = document.createElement('aside')
    node.dataset.effectOwner = applet.instance
    node.textContent = 'Sandbox DOM probe'
    dom.appendChild(node)
    const style = document.createElement('style')
    style.dataset.effectOwner = applet.instance
    style.textContent = '.sandbox-probe { color: teal }'
    document.head.appendChild(style)

    const rootNode = document.createElement('div')
    dom.appendChild(rootNode)
    const root = createRoot(rootNode)
    roots.set(dom, root)
    root.render(
      <AppletBoundary>
        <Applet host={applet} />
      </AppletBoundary>
    )
  },
  destroy({ dom }: RenderArgs) {
    roots.get(dom)?.unmount()
    roots.delete(dom)
  }
}
