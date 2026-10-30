import { t } from 'i18next'
import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { parseRouterSearch, stringifyRouterSearch } from '../../common/router'
import { contentKeys } from '../content-api'
import { ContentListRoute } from '../content-list'
import { ContentNavigation } from '../page-navigation'
import { loadLocale } from '../../common/i18n'

beforeAll(() => loadLocale('en-US'))

describe('Private page creation', () => {
  for (const state of ['pending', 'error', 'ready', 'guest'] as const) {
    test(
      state === 'guest'
        ? 'guest navigation and the Private list omit Private creation'
        : `both navigation and the Private list retain their destination while identity is ${state}`,
      async () => {
        const client = new QueryClient({
          defaultOptions: { queries: { gcTime: Infinity, retry: false, staleTime: Infinity } }
        })
        client.setQueryData(contentKeys.children('space'), {
          pages: [
            { pages: [], principal_uid: 'current-human', can_create_space: state !== 'guest', next_cursor: null }
          ],
          pageParams: [undefined]
        })
        if (state === 'ready' || state === 'guest') {
          client.setQueryData(contentKeys.list('private'), {
            pages: [],
            principal_uid: 'current-human',
            can_create_private: state === 'ready'
          })
          client.setQueryData(contentKeys.children('private'), {
            pages: [
              { pages: [], principal_uid: 'current-human', can_create_private: state === 'ready', next_cursor: null }
            ],
            pageParams: [undefined]
          })
        } else if (state === 'error') {
          client
            .getQueryCache()
            .build(client, { queryKey: contentKeys.list('private') })
            .setState({ status: 'error', error: new Error('Private unavailable') })
        }
        const rootRoute = createRootRoute()
        const contentRoute = createRoute({
          getParentRoute: () => rootRoute,
          path: '/content/$scope',
          component: () => (
            <>
              <ContentNavigation />
              <ContentListRoute />
            </>
          )
        })
        const router = createRouter({
          routeTree: rootRoute.addChildren([contentRoute]),
          history: createMemoryHistory({ initialEntries: ['/content/private'] }),
          parseSearch: parseRouterSearch,
          stringifySearch: stringifyRouterSearch
        })
        await router.load()
        try {
          const html = renderToStaticMarkup(
            <QueryClientProvider client={client}>
              <RouterProvider router={router} />
            </QueryClientProvider>
          )
          const buttons =
            html.match(
              new RegExp(`<button\\b[^>]*aria-label="${RegExp.escape(t('pod.content.new_page'))}"[^>]*>`, 'g')
            ) ?? []
          expect(buttons).toHaveLength(state === 'guest' ? 0 : 3)
          if (state === 'guest') expect(html).not.toContain('<section aria-label="Private"')
          if (state !== 'guest') expect(buttons[0]).not.toMatch(/\sdisabled(?:=|\s|>)/)
          for (const button of buttons.slice(1)) {
            expect(/\sdisabled(?:=|\s|>)/.test(button)).toBe(state !== 'ready')
          }
        } finally {
          client.clear()
        }
      }
    )
  }
})

test('content lists disable cached creation permissions when the directory read fails', async () => {
  for (const scope of ['space', 'private', 'favorites', 'shared', 'search']) {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
    const key = contentKeys.children(scope === 'private' ? 'private' : 'space')
    client.setQueryData(key, {
      pages: [
        {
          pages: [],
          principal_uid: 'current-human',
          can_create_space: true,
          can_create_private: true,
          next_cursor: null
        }
      ],
      pageParams: [undefined]
    })
    client
      .getQueryCache()
      .find({ queryKey: key, exact: true })!
      .setState({ status: 'error', error: new Error('Directory unavailable') })
    const rootRoute = createRootRoute()
    const route = createRoute({
      getParentRoute: () => rootRoute,
      path: '/content/$scope',
      component: ContentListRoute
    })
    const router = createRouter({
      routeTree: rootRoute.addChildren([route]),
      history: createMemoryHistory({ initialEntries: [`/content/${scope}`] }),
      parseSearch: parseRouterSearch,
      stringifySearch: stringifyRouterSearch
    })
    await router.load()
    try {
      const html = renderToStaticMarkup(
        <QueryClientProvider client={client}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      )
      const create = html.match(
        new RegExp(`<button\\b[^>]*aria-label="${RegExp.escape(t('pod.content.new_page'))}"[^>]*>`)
      )?.[0]
      expect(create).toBeDefined()
      expect(create).toMatch(/\sdisabled(?:=|\s|>)/)
      expect(html).toContain('role="alert"')
    } finally {
      client.clear()
    }
  }
})
