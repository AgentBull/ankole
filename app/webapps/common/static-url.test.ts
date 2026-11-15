import { afterEach, describe, expect, it } from 'bun:test'
import { staticAssetBase, staticAssetURL } from './browser-context'
import { setPodRuntimeBootstrap } from './pod-bootstrap'

const originalDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')

function setMetaStaticBase(content: string | undefined): void {
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: {
      documentElement: { dataset: {}, lang: 'en-US' },
      querySelector: (selector: string) =>
        selector === 'meta[name="ankole-static-base"]' && content !== undefined ? { content } : null
    }
  })
}

describe('staticAssetBase and staticAssetURL', () => {
  afterEach(() => {
    setPodRuntimeBootstrap(undefined)
    if (originalDocument) Object.defineProperty(globalThis, 'document', originalDocument)
    else Reflect.deleteProperty(globalThis, 'document')
  })

  it('returns root-relative paths when ankole-static-base is absent', () => {
    setMetaStaticBase(undefined)
    expect(staticAssetBase()).toBe('')
    expect(staticAssetURL('/images/logo.svg')).toBe('/images/logo.svg')
    expect(staticAssetURL('fonts/office/manifest.json')).toBe('/fonts/office/manifest.json')
  })

  it('prefixes paths with protocol-relative CDN base and trims trailing slashes', () => {
    setMetaStaticBase('//ankole-static-files.cdn.agentbull.net/')

    expect(staticAssetBase()).toBe('//ankole-static-files.cdn.agentbull.net')
    expect(staticAssetURL('/images/logo.svg')).toBe('//ankole-static-files.cdn.agentbull.net/images/logo.svg')
    expect(staticAssetURL('/favicon.ico')).toBe('//ankole-static-files.cdn.agentbull.net/favicon.ico')
  })

  it('ignores malformed values and Desktop runtime bootstrap', () => {
    setMetaStaticBase('///evil')
    expect(staticAssetBase()).toBe('')

    setMetaStaticBase('//ankole-static-files.cdn.agentbull.net')
    setPodRuntimeBootstrap({
      mode: 'desktop',
      platform: 'macos',
      workspaceKey: 'demo',
      tenantId: '0195b6f0-0000-7000-8000-000000000001',
      podOrigin: 'https://demo.ankole.ai',
      siteOrigin: 'https://console.ankole.ai',
      principalUid: 'alice',
      activePlugins: [],
      features: {},
      locale: 'en-US'
    })
    expect(staticAssetBase()).toBe('')
    expect(staticAssetURL('/images/logo.svg')).toBe('/images/logo.svg')
  })
})
