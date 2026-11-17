import { describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../../common/i18n'
import { parseRouterSearch, stringifyRouterSearch } from '../../common/router'
import {
  getPermissionGrantOptions,
  getPrincipalGroupOptions,
  getPrincipalOptions,
  listGrantsOfPrincipalOptions,
  listGroupsOfPrincipalOptions,
  listPrincipalGroupGrantsOptions,
  listPrincipalGroupMembersOptions,
  listPrincipalGroupsOptions,
  listPrincipalsOptions
} from '../api/v2/generated/@tanstack/react-query.gen'
import { tenantQueryOptions } from '../state/tenant-scope'
import { ConsoleBoundTenantIDContext } from '../tenant-context'
import { PermissionGrantEditorPage } from './permission-grant-editor'
import { PrincipalEditPage } from './principal-edit'
import { PrincipalGroupEditorPage, PrincipalGroupsListPage } from './principal-groups'
import { PrincipalDetailPage } from './principals'

async function renderConsoleAccessRoute(
  tenantID: string,
  initialEntry: string,
  path: string,
  element: React.ReactNode,
  setup: (client: QueryClient) => void
): Promise<string> {
  await loadLocale('en-US')
  const client = new QueryClient({
    defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity, retry: false } }
  })
  setup(client)

  const rootRoute = createRootRoute()
  const route = createRoute({
    getParentRoute: () => rootRoute,
    path,
    component: () => <ConsoleBoundTenantIDContext value={tenantID}>{element}</ConsoleBoundTenantIDContext>
  })
  const router = createRouter({
    routeTree: rootRoute.addChildren([route]),
    history: createMemoryHistory({ initialEntries: [initialEntry] }),
    parseSearch: parseRouterSearch,
    stringifySearch: stringifyRouterSearch
  })
  await router.load()
  try {
    return renderToStaticMarkup(
      <I18nextProvider i18n={i18n}>
        <QueryClientProvider client={client}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      </I18nextProvider>
    )
  } finally {
    client.clear()
  }
}

describe('Console Access editors & tenant-scoped links', () => {
  test('PrincipalGroupsListPage exposes group creation without the Pod Settings members banner, and PrincipalGroupEditorPage renders group CRUD + members + grants', async () => {
    const tenantID = 'tenant-alpha'
    const groupDoc = {
      id: 'grp-1',
      type: 'principal_group' as const,
      attributes: {
        name: 'research-ops',
        display_name: 'Research Ops',
        description: 'Research operators',
        kind: 'static' as const,
        domain: 'operator' as const,
        built_in: false,
        computed_condition: null,
        member_count: 1,
        grant_count: 1,
        metadata: {}
      }
    }

    const listHtml = await renderConsoleAccessRoute(
      tenantID,
      '/access/groups',
      'access/groups',
      <PrincipalGroupsListPage />,
      client => {
        client.setQueryData(tenantQueryOptions(listPrincipalGroupsOptions(), tenantID).queryKey, {
          data: [groupDoc]
        })
      }
    )

    expect(listHtml).toContain('href="/access/groups/new?data_tenant=tenant-alpha"')
    expect(listHtml).not.toContain('settings?section=members')
    expect(listHtml).not.toContain(i18n.t('console.human_access.open_pod_settings'))

    const editorHtml = await renderConsoleAccessRoute(
      tenantID,
      '/access/groups/research-ops',
      'access/groups/$name',
      <PrincipalGroupEditorPage />,
      client => {
        client.setQueryData(
          tenantQueryOptions(getPrincipalGroupOptions({ path: { name: 'research-ops' } }), tenantID).queryKey,
          { data: groupDoc }
        )
        client.setQueryData(
          tenantQueryOptions(listPrincipalGroupMembersOptions({ path: { name: 'research-ops' } }), tenantID).queryKey,
          [
            {
              uid: 'alice',
              type: 'human',
              status: 'active',
              display_name: 'Alice',
              avatar_url: null,
              member_since: '2026-11-01T00:00:00Z'
            }
          ]
        )
        client.setQueryData(tenantQueryOptions(listPrincipalsOptions(), tenantID).queryKey, { data: [] })
        client.setQueryData(
          tenantQueryOptions(listPrincipalGroupGrantsOptions({ path: { name: 'research-ops' } }), tenantID).queryKey,
          {
            data: [
              {
                id: 'grant-1',
                type: 'permission_grant',
                attributes: {
                  group_id: 'grp-1',
                  principal_uid: null,
                  resource_pattern: 'site_console:**',
                  action: 'read',
                  condition: 'true',
                  description: 'Console viewer',
                  metadata: {}
                }
              }
            ]
          }
        )
      }
    )

    expect(editorHtml).not.toContain(i18n.t('console.human_access.open_pod_settings'))
    expect(editorHtml).toContain('aria-label="Add member"')
    expect(editorHtml).toContain('href="/access/groups/research-ops/grants/new?data_tenant=tenant-alpha"')
    expect(editorHtml).toContain('site_console:**')
    expect(editorHtml).toContain('data-slot="dropdown-menu-trigger"')
  })

  test('PrincipalDetailPage links human profile edit, group membership controls, and grant creation while keeping Pod Settings banner', async () => {
    const tenantID = 'tenant-alpha'
    const html = await renderConsoleAccessRoute(
      tenantID,
      '/access/principals/alice',
      'access/principals/$uid',
      <PrincipalDetailPage />,
      client => {
        client.setQueryData(tenantQueryOptions(getPrincipalOptions({ path: { uid: 'alice' } }), tenantID).queryKey, {
          data: {
            id: 'alice',
            type: 'principal',
            attributes: {
              uid: 'alice',
              type: 'human',
              status: 'active',
              access_version: 1,
              membership: 'member',
              display_name: 'Alice Chen',
              email: 'alice@example.com',
              avatar_url: null
            }
          }
        })
        client.setQueryData(
          tenantQueryOptions(listGroupsOfPrincipalOptions({ path: { uid: 'alice' } }), tenantID).queryKey,
          { data: [] }
        )
        client.setQueryData(tenantQueryOptions(listPrincipalGroupsOptions(), tenantID).queryKey, { data: [] })
        client.setQueryData(
          tenantQueryOptions(listGrantsOfPrincipalOptions({ path: { uid: 'alice' } }), tenantID).queryKey,
          { data: [] }
        )
      }
    )

    expect(html).toContain('href="/access/principals/alice/edit?data_tenant=tenant-alpha"')
    expect(html).toContain('href="/access/principals/alice/grants/new?data_tenant=tenant-alpha"')
    expect(html).toContain(i18n.t('console.human_access.pod_settings_owner_hint'))
  })

  test('PermissionGrantEditorPage and PrincipalEditPage disable text autocorrect on identifier, email, and CEL fields', async () => {
    const tenantID = 'tenant-alpha'
    const grantHtml = await renderConsoleAccessRoute(
      tenantID,
      '/access/grants/grant-1',
      'access/grants/$grantID',
      <PermissionGrantEditorPage />,
      client => {
        client.setQueryData(
          tenantQueryOptions(getPermissionGrantOptions({ path: { id: 'grant-1' } }), tenantID).queryKey,
          {
            data: {
              id: 'grant-1',
              type: 'permission_grant',
              attributes: {
                group_id: null,
                principal_uid: 'alice',
                resource_pattern: 'site_console:**',
                action: 'read',
                condition: 'true',
                description: 'Read console',
                metadata: {}
              }
            }
          }
        )
        client.setQueryData(tenantQueryOptions(getPrincipalOptions({ path: { uid: 'alice' } }), tenantID).queryKey, {
          data: {
            id: 'alice',
            type: 'principal',
            attributes: {
              uid: 'alice',
              type: 'human',
              status: 'active',
              access_version: 1,
              display_name: 'Alice Chen',
              email: 'alice@example.com'
            }
          }
        })
      }
    )

    expect(grantHtml).toContain('autoCorrect="off"')
    expect(grantHtml).toContain('autoCapitalize="none"')
    expect(grantHtml).toContain('spellCheck="false"')
    expect(grantHtml).toContain('href="/access/principals/alice?data_tenant=tenant-alpha"')

    const editHtml = await renderConsoleAccessRoute(
      tenantID,
      '/access/principals/alice/edit',
      'access/principals/$uid/edit',
      <PrincipalEditPage />,
      client => {
        client.setQueryData(tenantQueryOptions(getPrincipalOptions({ path: { uid: 'alice' } }), tenantID).queryKey, {
          data: {
            id: 'alice',
            type: 'principal',
            attributes: {
              uid: 'alice',
              type: 'human',
              status: 'active',
              access_version: 1,
              display_name: 'Alice Chen',
              email: 'alice@example.com'
            }
          }
        })
      }
    )

    expect(editHtml).toContain('type="email"')
    expect(editHtml).toContain('autoCorrect="off"')
    expect(editHtml).toContain('href="/access/principals/alice?data_tenant=tenant-alpha"')
  })
})
