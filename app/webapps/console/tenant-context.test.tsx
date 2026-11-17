import { expect, test } from 'bun:test'
import { useModel } from '@preact/signals-react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
  RouterProvider
} from '@tanstack/react-router'
import { isValidElement, type ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import '../common/i18n'
import { dataTenantID, setDataTenantSoft } from '../common/browser-session'
import { parseRouterSearch, stringifyRouterSearch } from '../common/router'
import { client as v2Client } from './api/v2/generated/client.gen'
import {
  createAgentMutation,
  listAgentsOptions,
  listAgentsQueryKey
} from './api/v2/generated/@tanstack/react-query.gen'
import {
  getAiGatewayProviderQueryKey,
  listControlPlanePluginsOptions,
  listControlPlanePluginsQueryKey,
  listTenantsQueryKey,
  listWorkerProvidersQueryKey
} from './api/v2-site/generated/@tanstack/react-query.gen'
import { shouldBlockEditorNavigation } from './console-form'
import { validateConsoleSlots } from './slots'
import { AgentEditorModel, type AgentEditorDraft } from './state/agent-editor-model'
import { tenantQueryOptions } from './state/tenant-scope'
import {
  ConsoleBoundTenantIDContext,
  ConsoleTenantContext,
  createHistoryTenantTracker,
  evictTenantScopedQueries,
  Link,
  SITE_QUERY_IDS,
  TableRow,
  TenantTableRows,
  useBoundTenantID,
  useConsoleTenant,
  useMutation,
  useQuery
} from './tenant-context'
import { ConsoleTenantContent } from './tenant-switcher'
import { seedEditorDraft } from './use-editor-draft'

test.each(
  [
    { path: '/identity/shared', search: { view: 'config' }, query: 'view=config', tenant: true },
    { path: '/worker-envs/new', search: { scope: 'global' }, query: 'scope=global', tenant: false },
    { path: '/providers', search: { view: 'catalog' }, query: 'view=catalog', tenant: false },
    { path: '/relay/upstreams/acct_01', search: { tab: 'probes' }, query: 'tab=probes', tenant: false },
    { path: '/relay/policies/pol_01', search: { tab: 'quota' }, query: 'tab=quota', tenant: true }
  ].flatMap(example => [true, false].map(aggregate => ({ ...example, aggregate })))
)(
  'a record link keeps the owner scope of $path (aggregate=$aggregate)',
  async ({ path, search, query, tenant, aggregate }) => {
    const load = async () => ({ default: () => null })
    validateConsoleSlots({
      routes: [
        { id: 'relay-upstreams', pluginId: 'relay', path: '/relay/upstreams', scope: 'site', load },
        { id: 'relay-upstream-edit', pluginId: 'relay', path: '/relay/upstreams/$accountID', scope: 'site', load },
        { id: 'relay-policies', pluginId: 'relay', path: '/relay/policies', scope: 'tenant', load },
        { id: 'relay-policy-edit', pluginId: 'relay', path: '/relay/policies/$policyID', scope: 'tenant', load }
      ]
    })
    const previous = Object.getOwnPropertyDescriptor(globalThis, 'window')
    if (!aggregate) {
      Object.defineProperty(globalThis, 'window', {
        configurable: true,
        value: { sessionStorage: { getItem: () => 'tenant-b' } }
      })
    }
    try {
      const root = createRootRoute({ component: Outlet })
      const index = createRoute({
        getParentRoute: () => root,
        path: '/identity',
        component: () => (
          <ConsoleTenantContext
            value={aggregate ? { id: 'tenant-b', display_name: 'Tenant B', slug: 'tenant-b', first: true } : null}>
            <Link to={path} search={search}>
              Edit record
            </Link>
          </ConsoleTenantContext>
        )
      })
      const detail = createRoute({ getParentRoute: () => root, path, component: () => null })
      const router = createRouter({
        isServer: true,
        basepath: '/operator',
        routeTree: root.addChildren([index, detail]),
        history: createMemoryHistory({ initialEntries: ['/operator/identity'] })
      })
      await router.load()
      const html = renderToStaticMarkup(<RouterProvider router={router} />)
      expect(html.includes('data_tenant=tenant-b')).toBe(tenant)
      expect(html).toContain(query)
    } finally {
      validateConsoleSlots({})
      if (!aggregate) {
        if (previous) Object.defineProperty(globalThis, 'window', previous)
        else Reflect.deleteProperty(globalThis, 'window')
      }
    }
  }
)

test('aggregate table rows expose their tenant without changing the resource cells', () => {
  const html = renderToStaticMarkup(
    <ConsoleTenantContext value={{ id: 'tenant-b', display_name: 'Tenant B', slug: 'tenant-b', first: true }}>
      <table>
        <tbody>
          <TenantTableRows>
            <TableRow>
              <td>shared</td>
            </TableRow>
          </TenantTableRows>
        </tbody>
      </table>
    </ConsoleTenantContext>
  )
  expect(html).toContain('Tenant B</td><td>shared</td>')
})

test('SITE_QUERY_IDS derives site-scoped query keys from generated v2-site helpers without string heuristics', () => {
  expect(SITE_QUERY_IDS.has('listTenants')).toBe(true)
  expect(SITE_QUERY_IDS.has('listWorkerProviders')).toBe(true)
  expect(SITE_QUERY_IDS.has('getAiGatewayProvider')).toBe(true)
  expect(SITE_QUERY_IDS.has('getSiteOverview')).toBe(true)
  // Must not match a tenant-scoped query whose name happens to contain "Site".
  expect(SITE_QUERY_IDS.has('listAgentsForSiteDemo')).toBe(false)

  const queryClient = new QueryClient()
  queryClient.setQueryData(listTenantsQueryKey(), { data: [] })
  queryClient.setQueryData(listWorkerProvidersQueryKey(), { data: [] })
  queryClient.setQueryData(getAiGatewayProviderQueryKey({ path: { provider_id: 'openai' } }), {
    data: { id: 'openai', type: 'ai_gateway_provider' }
  })
  queryClient.setQueryData(listAgentsQueryKey(), { data: [{ id: 'bot-a', type: 'agent' }] })
  queryClient.setQueryData([{ _id: 'listAgentsForSiteDemo' }], { data: ['tenant-only'] })
  queryClient.setQueryData([{ _id: 'listAgents', headers: { 'x-ankole-tenant': 'tenant-explicit' } }], {
    data: ['explicit-header']
  })
  queryClient.setQueryData(['console-session', 'auth-1', 'pod-1'], { ok: true })

  evictTenantScopedQueries(queryClient)

  expect(queryClient.getQueryData(listTenantsQueryKey())).toBeDefined()
  expect(queryClient.getQueryData(listWorkerProvidersQueryKey())).toBeDefined()
  expect(queryClient.getQueryData(getAiGatewayProviderQueryKey({ path: { provider_id: 'openai' } }))).toBeDefined()
  expect(queryClient.getQueryData(['console-session', 'auth-1', 'pod-1'])).toEqual({ ok: true })
  expect(
    queryClient.getQueryData([{ _id: 'listAgents', headers: { 'x-ankole-tenant': 'tenant-explicit' } }])
  ).toBeDefined()
  expect(queryClient.getQueryData(listAgentsQueryKey())).toBeUndefined()
  expect(queryClient.getQueryData([{ _id: 'listAgentsForSiteDemo' }])).toBeUndefined()
})

test('soft tenant navigation commits before route loaders without wiping prefetched data afterwards and syncs Back/Forward', async () => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'window')
  const backing = new Map<string, string>()
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: {
      sessionStorage: {
        getItem: (key: string) => backing.get(key) ?? null,
        setItem: (key: string, value: string) => backing.set(key, value),
        removeItem: (key: string) => backing.delete(key)
      }
    }
  })

  try {
    const queryClient = new QueryClient()
    const historyTenants = createHistoryTenantTracker(null)
    let evictions = 0

    const root = createRootRoute({
      beforeLoad: ({ location, preload }) => {
        if (preload) return
        const nextTenant = historyTenants.resolve(location)
        if (nextTenant !== dataTenantID()) {
          setDataTenantSoft(nextTenant)
          evictions += 1
          evictTenantScopedQueries(queryClient)
        }
      },
      component: Outlet
    })

    const homeRoute = createRoute({
      getParentRoute: () => root,
      path: '/',
      component: () => null
    })

    const agentsRoute = createRoute({
      getParentRoute: () => root,
      path: '/agents',
      loader: () => {
        const tenant = dataTenantID()
        if (tenant) {
          queryClient.setQueryData(listAgentsQueryKey(), { tenant })
        }
        return null
      },
      component: () => null
    })

    const providersRoute = createRoute({
      getParentRoute: () => root,
      path: '/providers',
      component: () => null
    })

    const router = createRouter({
      isServer: false,
      basepath: '/operator',
      routeTree: root.addChildren([homeRoute, agentsRoute, providersRoute]),
      history: createMemoryHistory({ initialEntries: ['/operator/'] }),
      parseSearch: parseRouterSearch,
      stringifySearch: stringifyRouterSearch
    })

    await router.load()
    expect(dataTenantID()).toBeNull()
    expect(evictions).toBe(0)

    await router.navigate({ to: '/agents', search: { data_tenant: 'tenant-b' } })
    expect(dataTenantID()).toBe('tenant-b')
    expect(evictions).toBe(1)
    // Loader-prefetched query data for tenant-b remains intact after navigation resolves (no post-loader second wipe).
    expect(queryClient.getQueryData(listAgentsQueryKey())).toEqual({ tenant: 'tenant-b' })

    // Visiting a site-scoped page without ?data_tenant keeps the selected tenant.
    await router.navigate({ to: '/providers' })
    expect(dataTenantID()).toBe('tenant-b')
    expect(evictions).toBe(1)

    // Navigating Back twice returns to initial All Tenants entry (/operator/) and restores null tenant.
    router.history.back()
    await router.load()
    expect(dataTenantID()).toBe('tenant-b')

    router.history.back()
    await router.load()
    expect(dataTenantID()).toBeNull()
    expect(evictions).toBe(2)
    expect(queryClient.getQueryData(listAgentsQueryKey())).toBeUndefined()
  } finally {
    if (previous) Object.defineProperty(globalThis, 'window', previous)
    else Reflect.deleteProperty(globalThis, 'window')
  }
})

test('EditorNavigationGuard normalizes effective tenant so same-tenant links pass and real switches block', () => {
  // Same-tenant <Link> carrying explicit ?data_tenant=tenant-a when current URL stripped data_tenant
  expect(
    shouldBlockEditorNavigation({
      action: 'PUSH',
      activeTenantID: 'tenant-a',
      blocked: true,
      current: { pathname: '/agents/new', search: {} },
      next: { pathname: '/agents/new', search: { template: 'support', data_tenant: 'tenant-a' } }
    })
  ).toBe(false)

  // In-page search param update omitting data_tenant stays in the active tenant
  expect(
    shouldBlockEditorNavigation({
      action: 'REPLACE',
      activeTenantID: 'tenant-a',
      blocked: true,
      current: { pathname: '/agents/new', search: {} },
      next: { pathname: '/agents/new', search: { tab: 'tools' } }
    })
  ).toBe(false)

  // Switching to another tenant or All Tenants on the same pathname blocks dirty drafts
  expect(
    shouldBlockEditorNavigation({
      action: 'PUSH',
      activeTenantID: 'tenant-a',
      blocked: true,
      current: { pathname: '/agents/new', search: {} },
      next: { pathname: '/agents/new', search: { data_tenant: 'tenant-b' } }
    })
  ).toBe(true)
  expect(
    shouldBlockEditorNavigation({
      action: 'PUSH',
      activeTenantID: 'tenant-a',
      blocked: true,
      current: { pathname: '/agents/new', search: { data_tenant: 'tenant-a' } },
      next: { pathname: '/agents/new', search: { data_tenant: '' } }
    })
  ).toBe(true)

  // Browser Back (POP) to an All Tenants entry without data_tenant blocks dirty drafts
  expect(
    shouldBlockEditorNavigation({
      action: 'BACK',
      activeTenantID: 'tenant-b',
      blocked: true,
      current: { pathname: '/agents/new', search: { data_tenant: 'tenant-b' } },
      next: { pathname: '/agents/new', search: {} }
    })
  ).toBe(true)
})

test('ConsoleTenantContent keys its subtree by selected tenant, resets "new" drafts across switches, and binds queries and mutations', async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
  const previousV2Config = v2Client.getConfig()
  const backing = new Map<string, string>()
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: {
      sessionStorage: {
        getItem: (key: string) => backing.get(key) ?? null,
        setItem: (key: string, value: string) => backing.set(key, value),
        removeItem: (key: string) => backing.delete(key)
      }
    }
  })

  const blankDraft: AgentEditorDraft = {
    uid: '',
    displayName: '',
    avatarURL: '',
    role: '',
    ownerPrincipalUID: '',
    workerProviderID: '',
    groupMemoryDisclosureMode: 'strict'
  }

  const submittedTenants: Array<{ uid: string; tenantHeader: string | null }> = []
  v2Client.setConfig({
    baseUrl: 'https://ankole.test',
    fetch: (async (request: Request) => {
      const payload = (await request.json()) as { data?: { uid?: string; attributes?: { uid?: string } } }
      const uid = payload.data?.uid ?? payload.data?.attributes?.uid ?? 'created'
      submittedTenants.push({
        uid,
        tenantHeader: request.headers.get('x-ankole-tenant')
      })
      return Response.json({
        data: {
          id: uid,
          type: 'agent',
          attributes: { uid, display_name: 'Created', status: 'active' }
        }
      })
    }) as typeof fetch
  })

  const agentRow = (uid: string, displayName: string) => ({
    id: uid,
    type: 'agent' as const,
    attributes: {
      uid,
      type: 'ai_colleague' as const,
      display_name: displayName,
      role: 'Assistant',
      owner_principal_uid: 'admin',
      status: 'active' as const,
      group_memory_disclosure_mode: 'strict' as const,
      options: {},
      inserted_at: '2026-11-17T00:00:00Z',
      updated_at: '2026-11-17T00:00:00Z'
    }
  })

  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false, staleTime: Infinity }, mutations: { retry: false } }
  })
  queryClient.setQueryData(listTenantsQueryKey(), {
    data: [
      { id: 'tenant-a', type: 'tenant', attributes: { display_name: 'Tenant A', slug: 'tenant-a', deleting_at: null } },
      { id: 'tenant-b', type: 'tenant', attributes: { display_name: 'Tenant B', slug: 'tenant-b', deleting_at: null } }
    ]
  })
  queryClient.setQueryData(tenantQueryOptions(listAgentsOptions(), 'tenant-a').queryKey, {
    data: [agentRow('bot-a', 'Bot A')]
  })
  queryClient.setQueryData(tenantQueryOptions(listAgentsOptions(), 'tenant-b').queryKey, {
    data: [agentRow('bot-b', 'Bot B')]
  })
  queryClient.setQueryData(listControlPlanePluginsQueryKey(), { plugins: [] })

  try {
    const renderForSelectedTenant = async (selectedTenant: string, dirtyDraftUID?: string) => {
      setDataTenantSoft(selectedTenant)
      const observed = {
        renderedWrapperKey: null as string | null,
        renderedWrapperType: null as unknown,
        renderedWrapperValue: null as unknown,
        capturedBoundTenantID: null as string | null,
        capturedConsoleTenantNull: false,
        capturedDraftUID: '',
        capturedVisibleAgentUID: undefined as string | undefined,
        capturedSitePluginsDefined: false
      }
      let submitCapturedMutation: ((uid: string) => Promise<unknown>) | undefined

      function InspectTenantContent({ children }: { children: ReactNode }) {
        const rendered = ConsoleTenantContent({ children })
        if (isValidElement(rendered)) {
          const innerChildren = (rendered.props as { children?: unknown[] }).children
          const contentNode = Array.isArray(innerChildren) ? innerChildren[1] : undefined
          if (isValidElement(contentNode)) {
            observed.renderedWrapperKey = contentNode.key
            observed.renderedWrapperType = contentNode.type
            observed.renderedWrapperValue = (contentNode.props as { value?: unknown }).value
          }
        }
        return rendered
      }

      function DraftEditorProbe() {
        const model = useModel(AgentEditorModel)
        seedEditorDraft(model, 'new', blankDraft, false)
        if (dirtyDraftUID && model.uid.value === '') {
          model.setUID(dirtyDraftUID)
        }
        observed.capturedBoundTenantID = useBoundTenantID()
        observed.capturedConsoleTenantNull = useConsoleTenant() === null
        observed.capturedDraftUID = model.uid.value

        const agents = useQuery(listAgentsOptions())
        const sitePlugins = useQuery(listControlPlanePluginsOptions())
        const createAgent = useMutation(createAgentMutation())

        observed.capturedVisibleAgentUID = agents.data?.data?.[0]?.attributes?.uid
        observed.capturedSitePluginsDefined = sitePlugins.data !== undefined
        submitCapturedMutation = (uid: string) =>
          createAgent.mutateAsync({
            body: {
              data: {
                uid,
                display_name: uid,
                role: 'Assistant',
                owner_principal_uid: 'admin'
              }
            }
          })

        return <div data-tenant={observed.capturedBoundTenantID ?? ''} data-draft={model.uid.value} />
      }

      const root = createRootRoute({
        component: () => (
          <InspectTenantContent>
            <DraftEditorProbe />
          </InspectTenantContent>
        )
      })
      const createPage = createRoute({ getParentRoute: () => root, path: '/agents/new', component: () => null })
      const router = createRouter({
        isServer: true,
        routeTree: root.addChildren([createPage]),
        history: createMemoryHistory({ initialEntries: ['/agents/new'] }),
        parseSearch: parseRouterSearch,
        stringifySearch: stringifyRouterSearch
      })
      await router.load()

      renderToStaticMarkup(
        <QueryClientProvider client={queryClient}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      )

      return {
        ...observed,
        submitCapturedMutation: submitCapturedMutation!
      }
    }

    const tenantA = await renderForSelectedTenant('tenant-a', 'draft-in-tenant-a')
    expect(tenantA.renderedWrapperType).toBe(ConsoleBoundTenantIDContext)
    expect(tenantA.renderedWrapperKey).toBe('tenant-a')
    expect(tenantA.renderedWrapperValue).toBe('tenant-a')
    expect(tenantA.capturedConsoleTenantNull).toBe(true)
    expect(tenantA.capturedBoundTenantID).toBe('tenant-a')
    expect(tenantA.capturedDraftUID).toBe('draft-in-tenant-a')
    expect(tenantA.capturedVisibleAgentUID).toBe('bot-a')
    expect(tenantA.capturedSitePluginsDefined).toBe(true)

    const tenantB = await renderForSelectedTenant('tenant-b')
    expect(tenantB.renderedWrapperType).toBe(ConsoleBoundTenantIDContext)
    expect(tenantB.renderedWrapperKey).toBe('tenant-b')
    expect(tenantB.renderedWrapperKey).not.toBe(tenantA.renderedWrapperKey)
    expect(tenantB.renderedWrapperValue).toBe('tenant-b')
    expect(tenantB.capturedConsoleTenantNull).toBe(true)
    expect(tenantB.capturedBoundTenantID).toBe('tenant-b')
    expect(tenantB.capturedDraftUID).toBe('')
    expect(tenantB.capturedVisibleAgentUID).toBe('bot-b')
    expect(tenantB.capturedSitePluginsDefined).toBe(true)

    // Even when sessionStorage changes afterwards, each mounted component's mutation stays pinned to its bound tenant!
    setDataTenantSoft('tenant-c')
    await tenantA.submitCapturedMutation('submitted-from-a')
    await tenantB.submitCapturedMutation('submitted-from-b')
    expect(submittedTenants).toEqual([
      { uid: 'submitted-from-a', tenantHeader: 'tenant-a' },
      { uid: 'submitted-from-b', tenantHeader: 'tenant-b' }
    ])
  } finally {
    queryClient.clear()
    v2Client.setConfig(previousV2Config)
    if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow)
    else Reflect.deleteProperty(globalThis, 'window')
  }
})
