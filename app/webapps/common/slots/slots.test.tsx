import { afterAll, expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { lazy } from 'react'
import { OpenFeatureProvider } from '@openfeature/react-sdk'
import { OpenFeature } from '@openfeature/web-sdk'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  consoleSlotCollectionPath,
  consoleSlotPageKind,
  consoleSlotTenantPage,
  mergeConsoleSlots,
  resolveConsoleSlots,
  validateConsoleSlots,
  type ConsoleRouteLoaderContext
} from '../../console/slots'
import { mergePodSlots, resolvePodSlots } from '../../pod/slots'
import { editionWebappModules, prepareEditionModules } from '../../scripts/edition'
import { initializeFeatures } from '../features'
import { ActivePluginsContext, defineWebappModule, SlotGate, validateSlotIDs } from './index'

const originalProvider = OpenFeature.getProvider()
afterAll(async () => {
  await OpenFeature.setProviderAndWait(originalProvider)
})

test('slot IDs reject duplicate and built-in claims', () => {
  expect(() => validateSlotIDs([{ id: 'general' }], ['general'])).toThrow('reserved slot ID')
  expect(() => validateSlotIDs([{ id: 'fixture' }, { id: 'fixture' }], [])).toThrow('slot ID')
  expect(() => validateSlotIDs([{ id: 'fixture' }], ['general'])).not.toThrow()
})

test('Console slot declarations reject reserved routes', () => {
  const load = async () => ({ default: () => null })
  expect(() =>
    validateConsoleSlots({
      routes: [{ id: 'custom', pluginId: 'saas', path: '/tenants/extra', scope: 'site', load }]
    })
  ).toThrow('Console route path')

  const routes = [
    { id: 'codes', pluginId: 'saas', path: '/invitation-codes', scope: 'site' as const, load },
    { id: 'codes-new', pluginId: 'saas', path: '/invitation-codes/new', scope: 'site' as const, load },
    {
      id: 'codes-edit',
      pluginId: 'saas',
      path: '/invitation-codes/$codeID',
      scope: 'tenant' as const,
      load
    }
  ]
  expect(() => validateConsoleSlots({ routes })).not.toThrow()
})

test('resolveConsoleSlots merges module routes, combines matching nav sections, and resolves parameterized paths', () => {
  const load = async () => ({ default: () => null })
  const Icon = () => null
  const firstVisible = true
  let secondVisible = true

  const modA = defineWebappModule({
    id: 'relay',
    console: {
      routes: [
        { id: 'relay-upstreams', pluginId: 'relay', path: '/relay/upstreams', scope: 'site', load },
        { id: 'relay-upstream-edit', pluginId: 'relay', path: '/relay/upstreams/$accountID', scope: 'site', load },
        { id: 'relay-policies', pluginId: 'relay', path: '/relay/policies', scope: 'tenant', load },
        {
          id: 'relay-policy-edit',
          pluginId: 'relay',
          path: '/relay/policies/$policyID',
          scope: 'tenant',
          collectionPath: '/relay/policies',
          load
        }
      ],
      navSections: [
        {
          id: 'relay-section',
          pluginId: 'relay',
          label: 'relay.nav.group',
          isVisible: () => firstVisible,
          items: [{ id: 'relay-upstreams-nav', to: '/relay/upstreams', label: 'relay.nav.upstreams', icon: Icon }]
        }
      ]
    }
  })

  const modB = defineWebappModule({
    id: 'relay-extra',
    console: {
      navSections: [
        {
          id: 'relay-section',
          pluginId: 'relay',
          isVisible: () => secondVisible,
          items: [{ id: 'relay-policies-nav', to: '/relay/policies', label: 'relay.nav.policies', icon: Icon }]
        }
      ]
    }
  })

  try {
    const resolved = resolveConsoleSlots(undefined, [modA, modB])
    expect(resolved.routes?.map(route => route.id)).toEqual([
      'relay-upstreams',
      'relay-upstream-edit',
      'relay-policies',
      'relay-policy-edit'
    ])
    expect(resolved.navSections).toHaveLength(1)
    expect(resolved.navSections?.[0]?.label).toBe('relay.nav.group')
    expect(resolved.navSections?.[0]?.items.map(item => item.id)).toEqual(['relay-upstreams-nav', 'relay-policies-nav'])
    expect(resolved.navSections?.[0]?.isVisible?.()).toBe(true)
    secondVisible = false
    expect(resolved.navSections?.[0]?.isVisible?.()).toBe(false)

    expect(consoleSlotPageKind({ path: '/relay/policies' })).toBe('collection')
    expect(consoleSlotPageKind({ path: '/relay/policies/$policyID' })).toBe('record')
    expect(consoleSlotPageKind({ path: '/relay/policies/new' })).toBe('record')
    expect(consoleSlotPageKind({ path: '/relay/policies/$policyID', tenantPage: 'collection' })).toBe('collection')

    expect(consoleSlotTenantPage('/relay/upstreams')).toBe('site')
    expect(consoleSlotTenantPage('/relay/upstreams/acct_01')).toBe('site')
    expect(consoleSlotTenantPage('/relay/policies')).toBe('collection')
    expect(consoleSlotTenantPage('/relay/policies/pol_01')).toBe('record')
    expect(consoleSlotCollectionPath('/relay/upstreams/acct_01')).toBeUndefined()
    expect(consoleSlotCollectionPath('/relay/policies/pol_01')).toBe('/relay/policies')
  } finally {
    validateConsoleSlots({})
  }

  expect(() =>
    mergeConsoleSlots(
      { navSections: [{ id: 'sec', pluginId: 'relay', label: 'a', items: [] }] },
      { navSections: [{ id: 'sec', pluginId: 'relay', label: 'b', items: [] }] }
    )
  ).toThrow('Conflicting Console navSection label')

  expect(() =>
    mergeConsoleSlots(
      { navSections: [{ id: 'sec', pluginId: 'relay', when: 'flag.a', items: [] }] },
      { navSections: [{ id: 'sec', pluginId: 'relay', when: 'flag.b', items: [] }] }
    )
  ).toThrow('Conflicting Console navSection when flag')
})

test('createConsoleRouter registers extension routes and invokes route.loader with scope and params', async () => {
  const previousDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: {
      querySelector: (selector: string) => {
        if (selector.includes('ankole-site-admin-console-path')) return { content: '/' }
        if (selector.includes('csrf-token')) return { content: 'test-csrf-token' }
        return null
      }
    }
  })
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: {
      location: new URL('https://console.ankole.test/relay/upstreams/acct_01?mode=edit'),
      document: { baseURI: 'https://console.ankole.test/' },
      addEventListener: () => {},
      removeEventListener: () => {},
      sessionStorage: {
        getItem: () => 'tenant-x',
        setItem: () => {},
        removeItem: () => {}
      },
      history: {
        state: null,
        pushState: () => {},
        replaceState: () => {},
        go: () => {},
        back: () => {},
        forward: () => {}
      }
    }
  })

  try {
    const { QueryClient } = await import('@tanstack/react-query')
    const { createConsoleRouter } = await import('../../console/app')
    let capturedContext: ConsoleRouteLoaderContext | undefined
    let componentLoaded = false
    const queryClient = new QueryClient()
    const router = createConsoleRouter(queryClient, {
      routes: [
        {
          id: 'relay-upstream-edit',
          pluginId: 'relay',
          path: '/relay/upstreams/$accountID',
          scope: 'site',
          loader: async ctx => {
            capturedContext = ctx
          },
          load: async () => {
            componentLoaded = true
            return { default: () => <div>Relay Upstream Editor</div> }
          }
        }
      ]
    })

    const matches = router.matchRoutes('/relay/upstreams/acct_01', { mode: 'edit' })
    const leaf = matches.at(-1)
    expect(leaf?.staticData?.consoleSlot?.id).toBe('relay-upstream-edit')
    const route = leaf
      ? (router.routesById as Record<string, { options?: { loader?: (...args: unknown[]) => unknown } }>)[leaf.routeId]
      : undefined
    await route?.options?.loader?.({
      params: { accountID: 'acct_01' },
      location: { pathname: '/relay/upstreams/acct_01', searchStr: '?mode=edit' }
    })

    expect(componentLoaded).toBe(true)
    expect(capturedContext).toEqual({
      queryClient,
      params: { accountID: 'acct_01' },
      location: { pathname: '/relay/upstreams/acct_01', searchStr: '?mode=edit' },
      scope: 'site',
      tenantID: 'tenant-x'
    })
  } finally {
    validateConsoleSlots({})
    if (previousDocument) Object.defineProperty(globalThis, 'document', previousDocument)
    else Reflect.deleteProperty(globalThis, 'document')
    if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow)
    else Reflect.deleteProperty(globalThis, 'window')
  }
})

test('resolvePodSlots merges singular and plural account navigations and validates settings tab IDs', () => {
  const LazyTab = lazy(async () => ({ default: () => null }))
  const modA = defineWebappModule({
    id: 'cloud',
    pod: {
      accountNavigation: { pluginId: 'cloud', content: 'Cloud Account' },
      settingsTabs: [{ id: 'cloud-tab', pluginId: 'cloud', labelKey: 'cloud.tab', Component: LazyTab }]
    }
  })
  const modB = defineWebappModule({
    id: 'relay',
    pod: {
      accountNavigations: [{ pluginId: 'relay', content: 'Relay Account' }],
      settingsTabs: [{ id: 'relay-tab', pluginId: 'relay', labelKey: 'relay.tab', Component: LazyTab }]
    }
  })

  const resolved = resolvePodSlots({ accountNavigation: { pluginId: 'override', content: 'Override Account' } }, [
    modA,
    modB
  ])
  expect(resolved.accountNavigations?.map(item => item.pluginId)).toEqual(['cloud', 'relay', 'override'])
  expect(resolved.settingsTabs?.map(tab => tab.id)).toEqual(['cloud-tab', 'relay-tab'])

  expect(() =>
    resolvePodSlots({
      settingsTabs: [{ id: 'connectors', pluginId: 'relay', labelKey: 'relay.tab', Component: LazyTab }]
    })
  ).toThrow('reserved slot ID: connectors')

  expect(mergePodSlots()).toEqual({})
})

test('editionWebappModules and prepareEditionModules discover modules in SaaS and emit empty registry in FOSS', () => {
  const tempRoot = mkdtempSync(path.join(os.tmpdir(), 'ankole-edition-modules-'))
  try {
    expect(editionWebappModules(tempRoot, 'foss')).toEqual([])

    const emptyRegistry = path.join(tempRoot, 'empty-edition-modules.gen.ts')
    prepareEditionModules(emptyRegistry, [])
    expect(readFileSync(emptyRegistry, 'utf8')).toContain('export const editionModules = [] as const')

    const webappsDir = path.join(tempRoot, 'webapps')
    const relayDir = path.join(webappsDir, 'modules/relay')
    const pluginDir = path.join(tempRoot, 'plugins/billing/webapps')
    const customFile = path.join(webappsDir, 'custom-ext.tsx')
    mkdirSync(relayDir, { recursive: true })
    mkdirSync(pluginDir, { recursive: true })

    writeFileSync(path.join(relayDir, 'extension.tsx'), 'export default {}\n')
    writeFileSync(path.join(pluginDir, 'extension.ts'), 'export default {}\n')
    writeFileSync(customFile, 'export default {}\n')
    writeFileSync(
      path.join(webappsDir, 'entries.json'),
      JSON.stringify({ entries: {}, modules: { alpha: './custom-ext.tsx' } })
    )

    const discovered = editionWebappModules(tempRoot, 'saas')
    expect(discovered).toEqual([
      { id: 'alpha', file: customFile },
      { id: 'billing', file: path.join(pluginDir, 'extension.ts') },
      { id: 'relay', file: path.join(relayDir, 'extension.tsx') }
    ])

    const populatedRegistry = path.join(tempRoot, 'populated-edition-modules.gen.ts')
    prepareEditionModules(populatedRegistry, discovered)
    const generatedText = readFileSync(populatedRegistry, 'utf8')
    expect(generatedText).toContain(`import module0 from ${JSON.stringify(customFile)}`)
    expect(generatedText).toContain('id: entry0.id ?? "alpha"')
    expect(generatedText).toContain('id: entry2.id ?? "relay"')

    writeFileSync(path.join(relayDir, 'extension.ts'), 'export default {}\n')
    expect(() => editionWebappModules(tempRoot, 'saas')).toThrow('Multiple extension entrypoints')
    rmSync(path.join(relayDir, 'extension.ts'))

    const duplicatePluginDir = path.join(tempRoot, 'plugins/relay/webapps')
    mkdirSync(duplicatePluginDir, { recursive: true })
    writeFileSync(path.join(duplicatePluginDir, 'extension.tsx'), 'export default {}\n')
    expect(() => editionWebappModules(tempRoot, 'saas')).toThrow('Duplicate webapp module: relay')
  } finally {
    rmSync(tempRoot, { recursive: true, force: true })
  }
})

test('active Plugin slots use the mounted snapshot and official SDK conditions', async () => {
  await initializeFeatures({ 'fixture.off': false, 'fixture.on': true })

  function Fixture({ pluginId, when, label }: { pluginId: string; when?: string; label: string }) {
    return <SlotGate slot={{ pluginId, when }}>{enabled => (enabled ? <span>{label}</span> : null)}</SlotGate>
  }
  const html = renderToStaticMarkup(
    <OpenFeatureProvider>
      <ActivePluginsContext value={['fixture-active']}>
        <Fixture pluginId="fixture-active" when="fixture.on" label="Enabled" />
        <Fixture pluginId="fixture-active" when="fixture.off" label="Disabled" />
        <Fixture pluginId="fixture-active" when="fixture.missing" label="Unknown" />
        <Fixture pluginId="fixture-active" label="Unconditional" />
        <Fixture pluginId="fixture-inactive" when="fixture.on" label="Inactive" />
        <SlotGate>{enabled => (enabled ? <span>Absent</span> : null)}</SlotGate>
      </ActivePluginsContext>
    </OpenFeatureProvider>
  )
  expect(html).toBe('<span>Enabled</span><span>Unconditional</span>')
})
