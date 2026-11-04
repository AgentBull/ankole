import { expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../common/i18n'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import type {
  PodConnectorAccountsListResponse,
  PodConnectorAuthConfigsListResponse,
  PodConnectorTriggersListResponse,
  PodConnectorsCatalogResponse
} from './api/generated/types.gen'
import { Connectors } from './connectors'

test('subscription polling exposes reauthorization when the account query still has its earlier active snapshot', async () => {
  await loadLocale('en-US')
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity } } })
  const session: BrowserSessionResponse = {
    authenticated: true,
    principalUID: 'alice',
    displayName: 'Alice',
    canManagePod: false,
    accounts: [],
    pendingAccounts: [],
    siteAuthentications: []
  }
  const connections: PodConnectorAuthConfigsListResponse = {
    connections: [
      {
        id: 'calendar-connection',
        slug: 'calendar',
        plugin_id: 'googlecalendar',
        display_name: 'Calendar',
        auth_scheme: 'oauth2',
        mode: 'cloud',
        status: 'active',
        is_default: false,
        public_metadata: {},
        configured_credential_fields: []
      }
    ]
  }
  const accounts: PodConnectorAccountsListResponse = {
    accounts: [
      {
        id: 'alice-calendar',
        auth_config_id: 'calendar-connection',
        account_key: 'alice',
        plugin_id: 'googlecalendar',
        owner_principal_uid: 'alice',
        subject_kind: 'human',
        status: 'active',
        granted_scopes: [],
        public_metadata: { name: 'Alice calendar' },
        updated_at: '2026-11-04T10:00:00Z'
      }
    ]
  }
  const catalog: PodConnectorsCatalogResponse = {
    can_manage: false,
    oauth_callback_url: 'https://console.example/oauth/cloud/connectors/callback',
    connectors: [
      {
        id: 'googlecalendar',
        plugin_id: 'googlecalendar',
        display_name: 'Google Calendar',
        auth_schemes: ['oauth2'],
        personal_credentials: false,
        toolkits: ['googlecalendar'],
        trigger_types: [
          {
            id: 'googlecalendar.event.created',
            label: 'Event created',
            supports_personal_account: true
          }
        ]
      }
    ]
  }
  const trigger: PodConnectorTriggersListResponse['triggers'][number] = {
    id: 'calendar-subscription',
    auth_config_id: 'calendar-connection',
    connected_account_id: 'alice-calendar',
    connected_account_status: 'active',
    owner_principal_uid: 'alice',
    plugin_id: 'googlecalendar',
    trigger_type: 'googlecalendar.event.created',
    scope_key: 'primary',
    status: 'provisioning',
    config: {},
    config_ref: 'connector-trigger://calendar-subscription',
    updated_at: '2026-11-04T10:00:00Z'
  }
  const key = ['connectors', '', '']
  client.setQueryData(['pod-session', '', ''], session)
  client.setQueryData([...key, 'catalog'], catalog)
  client.setQueryData([...key, 'connections'], connections)
  client.setQueryData([...key, 'accounts', 'mine'], accounts)
  client.setQueryData([...key, 'accounts', 'team'], { accounts: [] })
  client.setQueryData([...key, 'triggers'], { triggers: [trigger] })
  const rootRoute = createRootRoute({ component: Connectors })
  const router = createRouter({ routeTree: rootRoute, history: createMemoryHistory({ initialEntries: ['/'] }) })
  await router.load()
  const originalWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: { location: new URL('https://pod.example/connectors') }
  })
  const render = () =>
    renderToStaticMarkup(
      <I18nextProvider i18n={i18n.cloneInstance({ lng: 'en-US', initAsync: false })}>
        <QueryClientProvider client={client}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      </I18nextProvider>
    )
  try {
    expect(render()).not.toContain('Authorize and continue')
    // Reconciliation expires the account. Only the trigger query polls; its response
    // includes the account status read by Triggers.list during that request.
    client.setQueryData([...key, 'triggers'], {
      triggers: [
        {
          ...trigger,
          status: 'degraded',
          connected_account_status: 'expired',
          last_error: { code: 'oauth_reauthorization_required' },
          updated_at: '2026-11-04T10:00:02Z'
        }
      ]
    })
    expect(client.getQueryData([...key, 'accounts', 'mine'])).toEqual(accounts)
    expect(render()).toContain('Authorize and continue')
  } finally {
    client.clear()
    if (originalWindow) Object.defineProperty(globalThis, 'window', originalWindow)
    else Reflect.deleteProperty(globalThis, 'window')
  }
})
