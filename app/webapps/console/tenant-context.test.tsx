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
import { ConsoleTenantContext, Link, TableRow, TenantTableRows } from './tenant-context'

test.each([
  { path: '/identity/shared', search: { view: 'config' }, tenant: true },
  { path: '/worker-envs/new', search: { scope: 'global' }, tenant: false }
])('a record link keeps the owner scope of $path', async ({ path, search, tenant }) => {
  const root = createRootRoute({ component: Outlet })
  const index = createRoute({
    getParentRoute: () => root,
    path: '/identity',
    component: () => (
      <ConsoleTenantContext value={{ id: 'tenant-b', display_name: 'Tenant B', slug: 'tenant-b', first: true }}>
        <Link to={path} search={search}>
          Edit record
        </Link>
      </ConsoleTenantContext>
    )
  })
  const detail = createRoute({ getParentRoute: () => root, path, component: () => null })
  const router = createRouter({
    isServer: true,
    routeTree: root.addChildren([index, detail]),
    history: createMemoryHistory({ initialEntries: ['/identity'] })
  })
  await router.load()
  const html = renderToStaticMarkup(<RouterProvider router={router} />)
  expect(html.includes('data_tenant=tenant-b')).toBe(tenant)
  expect(html).toContain(tenant ? 'view=config' : 'scope=global')
})

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
