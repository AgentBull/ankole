import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../common/i18n'
import { parseRouterSearch, stringifyRouterSearch } from '../common/router'
import { RowActions, RowViewAction, SubNav } from './console-list-page'
import { brainObjectPath } from './pages/brain/brain-nav'
import { BrainObjectDrawer } from './pages/brain/objects'

// Catalogs load on demand; these assertions render translated en-US copy.
beforeAll(() => loadLocale('en-US'))

async function renderWithRouter(node: ReactNode, initialEntry = '/', path = '$') {
  const rootRoute = createRootRoute()
  const route = createRoute({
    getParentRoute: () => rootRoute,
    path,
    component: () => node
  })
  const router = createRouter({
    routeTree: rootRoute.addChildren([route]),
    history: createMemoryHistory({ initialEntries: [initialEntry] }),
    parseSearch: parseRouterSearch,
    stringifySearch: stringifyRouterSearch
  })
  await router.load()
  return renderToStaticMarkup(<RouterProvider router={router} />)
}

describe('SubNav', () => {
  test('gives sibling resource links a named navigation landmark', async () => {
    const html = await renderWithRouter(
      <SubNav
        ariaLabel="Access sections"
        items={[
          { to: '/access/groups', label: 'Groups' },
          { to: '/access/principals', label: 'Principals' }
        ]}
      />
    )

    expect(html).toContain('<nav aria-label="Access sections"')
  })
})

describe('RowActions', () => {
  test('keeps a reversible row action beside edit in the row menu', async () => {
    const html = await renderWithRouter(
      <table>
        <tbody>
          <tr>
            <RowActions actions={[{ label: 'Enable', onAction: () => {} }]} editLabel="Edit" editTo="/resources/one" />
          </tr>
        </tbody>
      </table>
    )

    expect(html).toContain('aria-label="More actions"')
    expect(html).not.toContain('aria-label="Edit"')
  })
})

describe('RowViewAction', () => {
  test('uses the same compact trailing control for routes and local detail views', async () => {
    const linkHTML = await renderWithRouter(
      <table>
        <tbody>
          <tr>
            <RowViewAction label="View resource details" to="/resources/one" />
          </tr>
        </tbody>
      </table>
    )
    const buttonHTML = renderToStaticMarkup(
      <table>
        <tbody>
          <tr>
            <RowViewAction label="View resource details" onOpen={() => {}} />
          </tr>
        </tbody>
      </table>
    )

    expect(linkHTML).toContain('aria-label="View resource details"')
    expect(linkHTML).toContain('href="/resources/one"')
    expect(buttonHTML).toContain('aria-label="View resource details"')
  })
})

describe('BrainObjectDrawer', () => {
  test('accepts a decoded Unicode slug with a bare percent sign', async () => {
    const html = await renderWithRouter(
      <QueryClientProvider client={new QueryClient()}>
        <BrainObjectDrawer />
      </QueryClientProvider>,
      brainObjectPath('concepts/增长20%'),
      '/brain/objects/$'
    )

    expect(html).toBeDefined()
  })
})
