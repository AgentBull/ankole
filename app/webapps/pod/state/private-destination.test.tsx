import { t } from 'i18next'
import { describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { parseRouterSearch, stringifyRouterSearch } from '../../common/router'
import { contentKeys } from '../content-api'
import { ContentListRoute, ContentNavigation } from '../page-navigation'

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
          expect(buttons).toHaveLength(state === 'guest' ? 1 : 3)
          if (state === 'guest') expect(html).not.toContain('<section aria-label="Private"')
          expect(buttons[0]).not.toMatch(/\sdisabled(?:=|\s|>)/)
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
