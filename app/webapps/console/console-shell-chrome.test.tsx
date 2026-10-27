import { afterAll, beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { lazy } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import i18n, { loadLocale } from '../common/i18n'
import { ActivePluginsContext } from '../common/slots'
import { getPrivilegedTenantQueryKey, listTenantsQueryKey } from './api/v2-site/generated/@tanstack/react-query.gen'
import { ConsoleLayout } from './console-shell-chrome'
import type { ConsoleRouteSlot } from './slots'

const originalWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
const originalDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')

beforeAll(async () => {
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: { sessionStorage: { getItem: () => null } }
  })
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: { documentElement: { lang: 'en-US' }, querySelector: () => null }
  })
  await loadLocale('en-US')
})

afterAll(() => {
  if (originalWindow) Object.defineProperty(globalThis, 'window', originalWindow)
  else Reflect.deleteProperty(globalThis, 'window')
  if (originalDocument) Object.defineProperty(globalThis, 'document', originalDocument)
  else Reflect.deleteProperty(globalThis, 'document')
})

test.each([
  ['/extension/static/details', true, false],
  ['/extension/other/details', true, true],
  ['/extension/static/details', false, true]
])('tenant switcher follows the actual route at %s with active=%s', async (pathname, active, visible) => {
  const client = new QueryClient()
  client.setQueryData(listTenantsQueryKey(), {
    data: ['one', 'two'].map(id => ({ id, type: 'tenant', attributes: { display_name: id } }))
  })
  client.setQueryData(getPrivilegedTenantQueryKey(), { data: { id: 'one', type: 'tenant' } })

  const root = createRootRoute({ component: ConsoleLayout })
  const slots: ConsoleRouteSlot[] = [
    {
      id: 'static',
      pluginId: 'fixture',
      path: '/extension/static/$',
      scope: 'site',
      Component: lazy(async () => ({ default: () => null }))
    },
    {
      id: 'dynamic',
      pluginId: 'fixture',
      path: '/extension/$id/details',
      scope: 'tenant',
      Component: lazy(async () => ({ default: () => null }))
    }
  ]
  const router = createRouter({
    isServer: true,
    routeTree: root.addChildren(
      slots.map(slot =>
        createRoute({
          getParentRoute: () => root,
          path: slot.path,
          staticData: { consoleSlot: slot },
          component: () => null
        })
      )
    ),
    history: createMemoryHistory({ initialEntries: [pathname] })
  })
  await router.load()
  const html = renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <ActivePluginsContext value={active ? ['fixture'] : []}>
        <RouterProvider router={router} />
      </ActivePluginsContext>
    </QueryClientProvider>
  )
  expect(html.includes(`aria-label="${i18n.t('console.tenants.data_context')}"`)).toBe(visible)
  client.clear()
})
