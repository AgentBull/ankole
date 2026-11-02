import { expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import i18n, { loadLocale } from '../common/i18n'
import { AccountMenu } from './account-menu'

for (const [locale, menuLabel] of [
  ['en-US', 'Account menu:'],
  ['zh-Hans-CN', '账户菜单：'],
  ['ja-JP', 'アカウントメニュー：'],
  ['ko-KR', '계정 메뉴:']
] as const) {
  for (const tenantName of ['Harbor Pod', '']) {
    test(`${locale} account button includes the visible identity for tenant "${tenantName}"`, async () => {
      await loadLocale(locale)
      const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity } } })
      const session: BrowserSessionResponse = {
        authenticated: true,
        canManagePod: false,
        displayName: 'Alice Reviewer',
        principalUID: 'alice',
        tenant: { id: '00112233-4455-6677-8899-aabbccddeeff', slug: 'harbor', displayName: tenantName },
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      }
      client.setQueryData(['pod-session', '', ''], session)
      const rootRoute = createRootRoute({ component: AccountMenu })
      const router = createRouter({ routeTree: rootRoute, history: createMemoryHistory({ initialEntries: ['/'] }) })
      await router.load()
      try {
        const html = renderToStaticMarkup(
          <I18nextProvider i18n={i18n.cloneInstance({ lng: locale, initAsync: false })}>
            <QueryClientProvider client={client}>
              <RouterProvider router={router} />
            </QueryClientProvider>
          </I18nextProvider>
        )
        let accessibleName = ''
        let visibleText = ''
        await new HTMLRewriter()
          .on('button.pod-account-trigger', {
            element: element => {
              accessibleName = element.getAttribute('aria-label') ?? ''
            }
          })
          .on('button.pod-account-trigger .pod-account-text', {
            text: chunk => {
              visibleText += chunk.text
            }
          })
          .transform(new Response(html))
          .text()

        expect(visibleText).toBe(`${tenantName}Alice Reviewer`)
        expect(accessibleName).toStartWith(menuLabel)
        if (tenantName) {
          expect(accessibleName).toMatch(/Harbor Pod.*Alice Reviewer/u)
        } else {
          expect(
            accessibleName
              .slice(menuLabel.length)
              .replace(/[\u2068\u2069]/gu, '')
              .trim()
          ).toBe('Alice Reviewer')
        }
      } finally {
        client.clear()
      }
    })
  }
}
