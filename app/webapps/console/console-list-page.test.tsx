import { beforeAll, describe, expect, test } from 'bun:test'
import { InfiniteQueryObserver, QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { TableCell, TableRow } from '@ankole/uikit'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../common/i18n'
import { parseRouterSearch, stringifyRouterSearch } from '../common/router'
import { listAgentsQueryKey } from './api/v2/generated/@tanstack/react-query.gen'
import { AgentCell, ResourceListPage, RowActions, RowViewAction, SubNav } from './console-list-page'
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

describe('ResourceListPage pagination', () => {
  test('a failed continuation keeps loaded rows and a retry appends the next rows', async () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } })
    const requests: (string | undefined)[] = []
    const query = new InfiniteQueryObserver(client, {
      queryKey: ['list-pagination'],
      initialPageParam: undefined as string | undefined,
      queryFn: async ({ pageParam }) => {
        requests.push(pageParam)
        if (requests.length === 2) throw new Error('The next page is unavailable')
        return { rows: [pageParam ? 'Second object' : 'First object'], next: pageParam ? undefined : 'next' }
      },
      getNextPageParam: page => page.next
    })
    const render = () => {
      const result = query.getCurrentResult()
      const rows = result.data?.pages.flatMap(page => page.rows) ?? []
      return renderWithRouter(
        <QueryClientProvider client={client}>
          <ResourceListPage
            title="Objects"
            columns={['Name']}
            isLoading={result.isPending}
            isEmpty={rows.length === 0}
            pagination={result}>
            {rows.map(row => (
              <TableRow key={row}>
                <TableCell>{row}</TableCell>
              </TableRow>
            ))}
          </ResourceListPage>
        </QueryClientProvider>
      )
    }
    try {
      await query.fetchNextPage()
      expect(await render()).toContain('First object')

      await query.fetchNextPage()
      expect(query.getCurrentResult().isFetchNextPageError).toBe(true)
      const failed = await render()
      expect(failed).toContain('First object')
      expect(failed.match(/The next page is unavailable/g)).toHaveLength(1)
      expect(failed.indexOf('</table>')).toBeLessThan(failed.indexOf('The next page is unavailable'))
      expect(failed).toMatch(/<button\b[^>]*>Retry<\/button>/)

      await query.fetchNextPage()
      const retried = await render()
      expect(retried).toContain('First object')
      expect(retried).toContain('Second object')
      expect(retried).not.toContain('The next page is unavailable')
      expect(retried).not.toMatch(/<button\b[^>]*>Retry<\/button>/)
      expect(requests).toEqual([undefined, 'next', 'next'])
    } finally {
      client.clear()
    }
  })

  test('an initial error shows the error without a data table or a continuation control', async () => {
    const client = new QueryClient()
    try {
      const html = await renderWithRouter(
        <QueryClientProvider client={client}>
          <ResourceListPage
            title="Objects"
            columns={['Name']}
            isLoading={false}
            isEmpty
            error={new Error('Unavailable')}>
            {null}
          </ResourceListPage>
        </QueryClientProvider>
      )
      expect(html).toContain('Unavailable')
      expect(html).not.toContain('<table')
    } finally {
      client.clear()
    }
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

describe('AgentCell', () => {
  test('links to the Agent by display name when resolved and falls back to UID when absent', async () => {
    const emptyClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
    const fallbackHTML = await renderWithRouter(
      <QueryClientProvider client={emptyClient}>
        <table>
          <tbody>
            <tr>
              <AgentCell uid="agent-raw-uid" />
            </tr>
          </tbody>
        </table>
      </QueryClientProvider>
    )
    expect(fallbackHTML).toContain('agent-raw-uid')
    emptyClient.clear()

    const populatedClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
    populatedClient.setQueryData(listAgentsQueryKey(), {
      data: [
        {
          id: 'agent-raw-uid',
          type: 'agent',
          attributes: { display_name: 'Research Bot', handle: 'research-bot', status: 'active' }
        }
      ]
    })
    const resolvedHTML = await renderWithRouter(
      <QueryClientProvider client={populatedClient}>
        <table>
          <tbody>
            <tr>
              <AgentCell uid="agent-raw-uid" />
            </tr>
          </tbody>
        </table>
      </QueryClientProvider>
    )
    expect(resolvedHTML).toContain('Research Bot')
    expect(resolvedHTML).toContain('href="/agents/agent-raw-uid"')
    populatedClient.clear()
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
