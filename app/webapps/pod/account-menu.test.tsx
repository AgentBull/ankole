import { expect, spyOn, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import * as browserContext from '../common/browser-context'
import i18n, { loadLocale } from '../common/i18n'
import { AccountMenu } from './account-menu'
import { profileAvatarURL } from './native-transfers'

for (const [locale, menuLabel, tenantName] of [
  ['en-US', 'Account menu:', 'Harbor Pod'],
  ['zh-Hans-CN', '账户菜单：', '']
] as const) {
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

test('profileAvatarURL binds each Space avatar to its own Pod origin and authenticationRef without leaking cross-Space credentials', () => {
  expect(
    profileAvatarURL('/api/v2/pod/avatars/space?v=harbor-sha', {
      podURL: 'https://harbor.pod.example/pages',
      authenticationRef: 'auth-harbor'
    })
  ).toBe('https://harbor.pod.example/api/v2/pod/avatars/space?v=harbor-sha&authentication_ref=auth-harbor')

  expect(
    profileAvatarURL('/api/v2/pod/avatars/space?v=beacon-sha&authentication_ref=stale-ref', {
      podURL: 'https://beacon.pod.example',
      authenticationRef: 'auth-beacon'
    })
  ).toBe('https://beacon.pod.example/api/v2/pod/avatars/space?v=beacon-sha&authentication_ref=auth-beacon')

  expect(
    profileAvatarURL('/api/v2/pod/avatars/member%3Aalice?v=member-sha&authentication_ref=stale-ref', {
      podURL: 'https://beacon.pod.example',
      authenticationRef: undefined
    })
  ).toBe('https://beacon.pod.example/api/v2/pod/avatars/member%3Aalice?v=member-sha')

  expect(
    profileAvatarURL('https://cdn.example.com/avatar.png', {
      podURL: 'https://harbor.pod.example',
      authenticationRef: 'auth-harbor'
    })
  ).toBe('https://cdn.example.com/avatar.png')
})

test('AccountMenu trigger resolves the active Space avatar against its own podURL and authenticationRef', async () => {
  await loadLocale('en-US')
  const harborID = '00112233-4455-6677-8899-aabbccddeeff'
  const beaconID = '11223344-5566-7788-99aa-bbccddeeff00'
  const podSpy = spyOn(browserContext, 'podID').mockReturnValue(harborID)
  const authSpy = spyOn(browserContext, 'authenticationRef').mockReturnValue('auth-harbor')
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity } } })
  const session: BrowserSessionResponse = {
    authenticated: true,
    canManagePod: false,
    displayName: 'Alice Reviewer',
    principalUID: 'alice',
    tenant: {
      id: harborID,
      slug: 'harbor',
      displayName: 'Harbor Pod',
      avatarURL: '/api/v2/pod/avatars/space?v=harbor-v1'
    },
    accounts: [
      {
        authenticationRef: 'auth-harbor',
        podURL: 'https://harbor.pod.example',
        principalUID: 'alice',
        displayName: 'Alice Reviewer',
        providerID: 'email_otp',
        tenant: {
          id: harborID,
          slug: 'harbor',
          displayName: 'Harbor Pod',
          avatarURL: '/api/v2/pod/avatars/space?v=harbor-v1'
        }
      },
      {
        authenticationRef: 'auth-beacon',
        podURL: 'https://beacon.pod.example',
        principalUID: 'alice',
        displayName: 'Alice Reviewer',
        providerID: 'email_otp',
        tenant: {
          id: beaconID,
          slug: 'beacon',
          displayName: 'Beacon Pod',
          avatarURL: '/api/v2/pod/avatars/space?v=beacon-v1'
        }
      }
    ],
    pendingAccounts: [],
    siteAuthentications: []
  }
  client.setQueryData(['pod-session', 'auth-harbor', harborID], session)
  const rootRoute = createRootRoute({ component: AccountMenu })
  const router = createRouter({ routeTree: rootRoute, history: createMemoryHistory({ initialEntries: ['/'] }) })
  await router.load()
  try {
    const html = renderToStaticMarkup(
      <I18nextProvider i18n={i18n.cloneInstance({ lng: 'en-US', initAsync: false })}>
        <QueryClientProvider client={client}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      </I18nextProvider>
    )
    const sources: string[] = []
    await new HTMLRewriter()
      .on('button.pod-account-trigger img', {
        element: element => {
          const src = element.getAttribute('src')
          if (src) sources.push(src.replaceAll('&amp;', '&'))
        }
      })
      .transform(new Response(html))
      .text()
    expect(sources).toEqual([
      'https://harbor.pod.example/api/v2/pod/avatars/space?v=harbor-v1&authentication_ref=auth-harbor'
    ])
  } finally {
    podSpy.mockRestore()
    authSpy.mockRestore()
    client.clear()
  }
})
