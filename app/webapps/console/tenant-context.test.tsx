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

test('a link to a same-named resource carries the section tenant into its new document', async () => {
  const root = createRootRoute({ component: Outlet })
  const index = createRoute({
    getParentRoute: () => root,
    path: '/identity',
    component: () => (
      <ConsoleTenantContext value={{ id: 'tenant-b', display_name: 'Tenant B', slug: 'tenant-b', first: true }}>
        <Link to="/identity/shared" search={{ view: 'config' }}>
          Shared provider
        </Link>
      </ConsoleTenantContext>
    )
  })
  const detail = createRoute({ getParentRoute: () => root, path: '/identity/$provider', component: () => null })
  const router = createRouter({
    isServer: true,
    routeTree: root.addChildren([index, detail]),
    history: createMemoryHistory({ initialEntries: ['/identity'] })
  })
  await router.load()
  const html = renderToStaticMarkup(<RouterProvider router={router} />)
  expect(html).toContain('data_tenant=tenant-b')
  expect(html).toContain('view=config')
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
