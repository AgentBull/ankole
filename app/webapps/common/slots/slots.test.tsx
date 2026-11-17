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

test('Console modules contribute settings through the shared slot context', () => {
  const settingGroups = [{ id: 'fixture', prefix: 'extension.fixture.' }]
  const settingOwners = [{ key: 'extension.owner', route: '/extension/owner', label: 'fixture.owner' }]
  const module = defineWebappModule({ console: { settingGroups } })
  expect(resolveConsoleSlots({ settingOwners }, [module])).toEqual({ settingGroups, settingOwners })
  expect(resolveConsoleSlots()).toEqual({})
})

test('Console slot declarations reject reserved routes', () => {
  const load = async () => ({ default: () => null })
  expect(() =>
    validateConsoleSlots({
      routes: [{ id: 'custom', pluginId: 'fixture', path: '/tenants/extra', scope: 'site', load }]
    })
  ).toThrow('Console route path')

  const routes = [
    { id: 'items', pluginId: 'fixture', path: '/fixture-items', scope: 'site' as const, load },
    { id: 'items-new', pluginId: 'fixture', path: '/fixture-items/new', scope: 'site' as const, load },
    {
      id: 'items-edit',
      pluginId: 'fixture',
      path: '/fixture-items/$itemID',
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
    id: 'fixture',
    console: {
      routes: [
        { id: 'fixture-upstreams', pluginId: 'fixture', path: '/fixture/upstreams', scope: 'site', load },
        {
          id: 'fixture-upstream-edit',
          pluginId: 'fixture',
          path: '/fixture/upstreams/$accountID',
          scope: 'site',
          load
        },
        { id: 'fixture-policies', pluginId: 'fixture', path: '/fixture/policies', scope: 'tenant', load },
        {
          id: 'fixture-policy-edit',
          pluginId: 'fixture',
          path: '/fixture/policies/$policyID',
          scope: 'tenant',
          collectionPath: '/fixture/policies',
          load
        }
      ],
      navSections: [
        {
          id: 'fixture-section',
          pluginId: 'fixture',
          label: 'fixture.nav.group',
          isVisible: () => firstVisible,
          items: [{ id: 'fixture-upstreams-nav', to: '/fixture/upstreams', label: 'fixture.nav.upstreams', icon: Icon }]
        }
      ]
    }
  })

  const modB = defineWebappModule({
    id: 'fixture-extra',
    console: {
      navSections: [
        {
          id: 'fixture-section',
          pluginId: 'fixture',
          isVisible: () => secondVisible,
          items: [{ id: 'fixture-policies-nav', to: '/fixture/policies', label: 'fixture.nav.policies', icon: Icon }]
        }
      ]
    }
  })

  try {
    const resolved = resolveConsoleSlots(undefined, [modA, modB])
    expect(resolved.routes?.map(route => route.id)).toEqual([
      'fixture-upstreams',
      'fixture-upstream-edit',
      'fixture-policies',
      'fixture-policy-edit'
    ])
    expect(resolved.navSections).toHaveLength(1)
    expect(resolved.navSections?.[0]?.label).toBe('fixture.nav.group')
    expect(resolved.navSections?.[0]?.items.map(item => item.id)).toEqual([
      'fixture-upstreams-nav',
      'fixture-policies-nav'
    ])
    expect(resolved.navSections?.[0]?.isVisible?.()).toBe(true)
    secondVisible = false
    expect(resolved.navSections?.[0]?.isVisible?.()).toBe(false)

    expect(consoleSlotPageKind({ path: '/fixture/policies' })).toBe('collection')
    expect(consoleSlotPageKind({ path: '/fixture/policies/$policyID' })).toBe('record')
    expect(consoleSlotPageKind({ path: '/fixture/policies/new' })).toBe('record')
    expect(consoleSlotPageKind({ path: '/fixture/policies/$policyID', tenantPage: 'collection' })).toBe('collection')

    expect(consoleSlotTenantPage('/fixture/upstreams')).toBe('site')
    expect(consoleSlotTenantPage('/fixture/upstreams/acct_01')).toBe('site')
    expect(consoleSlotTenantPage('/fixture/policies')).toBe('collection')
    expect(consoleSlotTenantPage('/fixture/policies/pol_01')).toBe('record')
    expect(consoleSlotCollectionPath('/fixture/upstreams/acct_01')).toBeUndefined()
    expect(consoleSlotCollectionPath('/fixture/policies/pol_01')).toBe('/fixture/policies')
  } finally {
    validateConsoleSlots({})
  }

  expect(() =>
    mergeConsoleSlots(
      { navSections: [{ id: 'sec', pluginId: 'fixture', label: 'a', items: [] }] },
      { navSections: [{ id: 'sec', pluginId: 'fixture', label: 'b', items: [] }] }
    )
  ).toThrow('Conflicting Console navSection label')

  expect(() =>
    mergeConsoleSlots(
      { navSections: [{ id: 'sec', pluginId: 'fixture', when: 'flag.a', items: [] }] },
      { navSections: [{ id: 'sec', pluginId: 'fixture', when: 'flag.b', items: [] }] }
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
      location: new URL('https://console.ankole.test/extension/upstreams/acct_01?mode=edit'),
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
          id: 'extension-upstream-edit',
          pluginId: 'extension',
          path: '/extension/upstreams/$accountID',
          scope: 'site',
          loader: async ctx => {
            capturedContext = ctx
          },
          load: async () => {
            componentLoaded = true
            return { default: () => <div>Extension Upstream Editor</div> }
          }
        }
      ]
    })

    const matches = router.matchRoutes('/extension/upstreams/acct_01', { mode: 'edit' })
    const leaf = matches.at(-1)
    expect(leaf?.staticData?.consoleSlot?.id).toBe('extension-upstream-edit')
    const route = leaf
      ? (router.routesById as Record<string, { options?: { loader?: (...args: unknown[]) => unknown } }>)[leaf.routeId]
      : undefined
    await route?.options?.loader?.({
      params: { accountID: 'acct_01' },
      location: { pathname: '/extension/upstreams/acct_01', searchStr: '?mode=edit' }
    })

    expect(componentLoaded).toBe(true)
    expect(capturedContext).toEqual({
      queryClient,
      params: { accountID: 'acct_01' },
      location: { pathname: '/extension/upstreams/acct_01', searchStr: '?mode=edit' },
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
    id: 'fixture',
    pod: {
      accountNavigations: [{ pluginId: 'fixture', content: 'Fixture Account' }],
      settingsTabs: [{ id: 'fixture-tab', pluginId: 'fixture', labelKey: 'fixture.tab', Component: LazyTab }]
    }
  })

  const resolved = resolvePodSlots({ accountNavigation: { pluginId: 'override', content: 'Override Account' } }, [
    modA,
    modB
  ])
  expect(resolved.accountNavigations?.map(item => item.pluginId)).toEqual(['cloud', 'fixture', 'override'])
  expect(resolved.settingsTabs?.map(tab => tab.id)).toEqual(['cloud-tab', 'fixture-tab'])

  expect(() =>
    resolvePodSlots({
      settingsTabs: [{ id: 'connectors', pluginId: 'fixture', labelKey: 'fixture.tab', Component: LazyTab }]
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
    const fixtureDir = path.join(webappsDir, 'modules/fixture')
    const pluginDir = path.join(tempRoot, 'plugins/beta/webapps')
    const customFile = path.join(webappsDir, 'custom-ext.tsx')
    mkdirSync(fixtureDir, { recursive: true })
    mkdirSync(pluginDir, { recursive: true })

    writeFileSync(path.join(fixtureDir, 'extension.tsx'), 'export default {}\n')
    writeFileSync(path.join(pluginDir, 'extension.ts'), 'export default {}\n')
    writeFileSync(customFile, 'export default {}\n')
    writeFileSync(
      path.join(webappsDir, 'entries.json'),
      JSON.stringify({ entries: {}, modules: { alpha: './custom-ext.tsx' } })
    )

    const discovered = editionWebappModules(tempRoot, 'saas')
    expect(discovered).toEqual([
      { id: 'alpha', file: customFile },
      { id: 'beta', file: path.join(pluginDir, 'extension.ts') },
      { id: 'fixture', file: path.join(fixtureDir, 'extension.tsx') }
    ])

    const populatedRegistry = path.join(tempRoot, 'populated-edition-modules.gen.ts')
    prepareEditionModules(populatedRegistry, discovered)
    const generatedText = readFileSync(populatedRegistry, 'utf8')
    expect(generatedText).toContain(`import module0 from ${JSON.stringify(customFile)}`)
    expect(generatedText).toContain('id: entry0.id ?? "alpha"')
    expect(generatedText).toContain('id: entry2.id ?? "fixture"')

    writeFileSync(path.join(fixtureDir, 'extension.ts'), 'export default {}\n')
    expect(() => editionWebappModules(tempRoot, 'saas')).toThrow('Multiple extension entrypoints')
    rmSync(path.join(fixtureDir, 'extension.ts'))

    const duplicatePluginDir = path.join(tempRoot, 'plugins/fixture/webapps')
    mkdirSync(duplicatePluginDir, { recursive: true })
    writeFileSync(path.join(duplicatePluginDir, 'extension.tsx'), 'export default {}\n')
    expect(() => editionWebappModules(tempRoot, 'saas')).toThrow('Duplicate webapp module: fixture')
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

test('editionWebappModules discovers generated extension.gen.ts entrypoints and rejects mixed duplicates', () => {
  const tempRoot = mkdtempSync(path.join(os.tmpdir(), 'ankole-edition-gen-'))
  try {
    const genDir = path.join(tempRoot, 'plugins/generated_fixture/webapps')
    mkdirSync(genDir, { recursive: true })
    writeFileSync(path.join(genDir, 'extension.gen.ts'), 'export default { id: "generated_fixture" }\n')

    const discovered = editionWebappModules(tempRoot, 'saas')
    expect(discovered).toEqual([{ id: 'generated_fixture', file: path.join(genDir, 'extension.gen.ts') }])

    writeFileSync(path.join(genDir, 'extension.ts'), 'export default { id: "generated_fixture" }\n')
    expect(() => editionWebappModules(tempRoot, 'saas')).toThrow('Multiple extension entrypoints')
  } finally {
    rmSync(tempRoot, { recursive: true, force: true })
  }
})

test('SlotGate evaluates optional reactive useVisible hook alongside plugin activation', async () => {
  await initializeFeatures({ 'fixture.on': true })

  function ReactiveFixture({ useVisible, label }: { useVisible: () => boolean; label: string }) {
    return (
      <SlotGate slot={{ pluginId: 'fixture-active', when: 'fixture.on', useVisible }}>
        {enabled => (enabled ? <span>{label}</span> : null)}
      </SlotGate>
    )
  }

  const html = renderToStaticMarkup(
    <OpenFeatureProvider>
      <ActivePluginsContext value={['fixture-active']}>
        <ReactiveFixture useVisible={() => true} label="Visible" />
        <ReactiveFixture useVisible={() => false} label="Hidden" />
      </ActivePluginsContext>
    </OpenFeatureProvider>
  )
  expect(html).toBe('<span>Visible</span>')
})
