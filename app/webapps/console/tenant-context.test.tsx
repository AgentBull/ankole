import { expect, test } from 'bun:test'
import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
  RouterProvider
} from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { validateConsoleSlots } from './slots'
import { ConsoleTenantContext, Link, TableRow, TenantTableRows } from './tenant-context'

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
