import { t } from 'i18next'
import { afterEach, beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../common/i18n'
import { setPodRuntimeBootstrap } from '../common/pod-bootstrap'
import { PageBreadcrumbs } from './page-breadcrumbs'

beforeAll(() => loadLocale('en-US'))
afterEach(() => setPodRuntimeBootstrap(undefined))

function signIn(principalUid: string) {
  setPodRuntimeBootstrap({
    mode: 'desktop',
    platform: 'macos',
    workspaceKey: 'ws-1',
    podOrigin: 'https://pod.example.test',
    siteOrigin: 'https://site.example.test',
    tenantId: 'tenant-1',
    principalUid,
    activePlugins: [],
    features: {},
    locale: 'en-US'
  })
}

async function rootCrumb(privateOwnerUID?: string) {
  const router = createRouter({
    routeTree: createRootRoute({
      component: () => <PageBreadcrumbs ancestors={[]} privateOwnerUID={privateOwnerUID} title="Plan" compact={false} />
    }),
    history: createMemoryHistory({ initialEntries: ['/'] })
  })
  await router.load()
  const html = renderToStaticMarkup(
    <QueryClientProvider client={new QueryClient()}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  )
  const [, href, label] = /<a\b[^>]*href="([^"]+)"[^>]*><span>([^<]*)<\/span><\/a>/.exec(html) ?? []
  return { href, label }
}

test('the root crumb names and opens the list that holds the Page', async () => {
  signIn('me')
  expect(await rootCrumb()).toEqual({ href: '/content/space', label: t('pod.content.space') })
  expect(await rootCrumb('me')).toEqual({ href: '/content/private', label: t('pod.content.private') })
  expect(await rootCrumb('someone')).toEqual({ href: '/content/shared', label: t('pod.content.shared_with_me') })
})

test('without a known viewer, a Private Page crumb says it searches all pages', async () => {
  expect(await rootCrumb('someone')).toEqual({ href: '/content/search', label: t('pod.content.search_all_pages') })
})
