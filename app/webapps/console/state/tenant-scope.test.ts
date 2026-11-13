import { afterEach, expect, test } from 'bun:test'
import { QueryClient } from '@tanstack/react-query'
import { client } from '../api/v2/generated/client.gen'
import {
  listIdentityProvidersOptions,
  saveIdentityProviderMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import { validateConsoleSlots } from '../slots'
import {
  consoleTenantPage,
  tenantCollectionPath,
  replaceTenantSearch,
  tenantMutationOptions,
  tenantQueryOptions,
  tenantSearchParams,
  tenantSwitchPath
} from './tenant-scope'

const previousConfig = client.getConfig()
afterEach(() => client.setConfig(previousConfig))

test('tenant collections aggregate, records require a tenant, and site settings keep their scope', () => {
  expect(consoleTenantPage('/identity', new URLSearchParams())).toBe('collection')
  expect(consoleTenantPage('/identity/shared', new URLSearchParams())).toBe('record')
  expect(consoleTenantPage('/identity/new', new URLSearchParams())).toBe('record')
  expect(consoleTenantPage('/providers', new URLSearchParams())).toBe('site')
  expect(consoleTenantPage('/model-profiles', new URLSearchParams())).toBe('site')
  expect(consoleTenantPage('/model-profiles', new URLSearchParams('defaults_scope=tenant'))).toBe('record')
  expect(consoleTenantPage('/model-profiles', new URLSearchParams('defaults_scope=global'))).toBe('site')
  expect(consoleTenantPage('/tenants/new', new URLSearchParams())).toBe('site')
  expect(consoleTenantPage('/settings/i18n.default_locale', new URLSearchParams('scope=tenant'))).toBe('record')
  expect(consoleTenantPage('/settings/brain.embedding_model', new URLSearchParams('scope=global'))).toBe('site')
  expect(consoleTenantPage('/settings', new URLSearchParams('scope=global'))).toBe('site')
  expect(consoleTenantPage('/agent-library', new URLSearchParams('defaults_scope=global'))).toBe('site')
  expect(consoleTenantPage('/agent-library', new URLSearchParams('defaults_scope=global&scope=agent-a'))).toBe('record')
  expect(consoleTenantPage('/agent-library/agent-plugins/office', new URLSearchParams('defaults_scope=global'))).toBe(
    'site'
  )
  expect(tenantCollectionPath('/identity/shared')).toBe('/identity')
  expect(tenantCollectionPath('/identity/mappings/new')).toBe('/identity/mappings')
})

test('dynamic Console route slots integrate with consoleTenantPage, tenantCollectionPath, and tenantSwitchPath', () => {
  const load = async () => ({ default: () => null })
  validateConsoleSlots({
    routes: [
      { id: 'relay-upstreams', pluginId: 'relay', path: '/relay/upstreams', scope: 'site', load },
      { id: 'relay-upstream-edit', pluginId: 'relay', path: '/relay/upstreams/$accountID', scope: 'site', load },
      { id: 'relay-policies', pluginId: 'relay', path: '/relay/policies', scope: 'tenant', load },
      { id: 'relay-policies-new', pluginId: 'relay', path: '/relay/policies/new', scope: 'tenant', load },
      {
        id: 'relay-policy-edit',
        pluginId: 'relay',
        path: '/relay/policies/$policyID',
        scope: 'tenant',
        collectionPath: '/relay/policies',
        load
      }
    ]
  })
  try {
    expect(consoleTenantPage('/relay/upstreams', new URLSearchParams())).toBe('site')
    expect(consoleTenantPage('/relay/upstreams/acct_01', new URLSearchParams())).toBe('site')
    expect(consoleTenantPage('/relay/policies', new URLSearchParams())).toBe('collection')
    expect(consoleTenantPage('/relay/policies/new', new URLSearchParams())).toBe('record')
    expect(consoleTenantPage('/relay/policies/pol_01', new URLSearchParams())).toBe('record')

    expect(tenantCollectionPath('/relay/policies/pol_01')).toBe('/relay/policies')
    expect(tenantCollectionPath('/relay/policies/new')).toBe('/relay/policies')
    expect(tenantSwitchPath('/relay/policies/pol_01', false)).toBe('/relay/policies/pol_01')
    expect(tenantSwitchPath('/relay/policies/pol_01', true)).toBe('/relay/policies')
    expect(tenantSwitchPath('/relay/policies/new', true)).toBe('/relay/policies/new')
  } finally {
    validateConsoleSlots({})
  }
})

test('choosing an editor tenant binds a direct link and switching an owned record returns to its collection', () => {
  expect(tenantSwitchPath('/identity/shared', false)).toBe('/identity/shared')
  expect(tenantSwitchPath('/identity/shared', true)).toBe('/identity')
  expect(tenantSwitchPath('/identity/new', true)).toBe('/identity/new')
  expect(tenantSwitchPath('/access/principals/person-a/grants/new', true)).toBe('/access/principals')
  expect(tenantSwitchPath('/access/grants/grant-a', true)).toBe('/access/principals')
})

test('the same provider ID in two tenants has separate requests and cached results', async () => {
  const requests: string[] = []
  client.setConfig({
    baseUrl: 'https://ankole.test',
    fetch: (async (request: Request) => {
      const tenant = request.headers.get('x-ankole-tenant')!
      requests.push(tenant)
      return Response.json({ identity_providers: [{ provider_id: 'shared', adapter_id: tenant }] })
    }) as typeof fetch
  })
  const queries = new QueryClient({ defaultOptions: { queries: { staleTime: Infinity, retry: false } } })
  try {
    const first = tenantQueryOptions(listIdentityProvidersOptions(), 'tenant-a')
    const second = tenantQueryOptions(listIdentityProvidersOptions(), 'tenant-b')
    expect((await queries.fetchQuery(first)).identity_providers[0]?.adapter_id).toBe('tenant-a')
    expect((await queries.fetchQuery(second)).identity_providers[0]?.adapter_id).toBe('tenant-b')
    expect((await queries.fetchQuery(first)).identity_providers[0]?.adapter_id).toBe('tenant-a')
    expect(requests).toEqual(['tenant-a', 'tenant-b'])
  } finally {
    queries.clear()
  }
})

test('an aggregate row mutation pins its tenant without changing the caller input', async () => {
  const targets: Array<string | null> = []
  client.setConfig({
    baseUrl: 'https://ankole.test',
    fetch: (async (request: Request) => {
      targets.push(request.headers.get('x-ankole-tenant'))
      return Response.json({ identity_provider: { provider_id: 'shared' } })
    }) as typeof fetch
  })
  const options = tenantMutationOptions(saveIdentityProviderMutation(), 'tenant-b')
  const variables = {
    path: { provider_id: 'shared' },
    body: { data: { adapter_id: 'lark', config: {}, enabled: true } }
  }
  await options.mutationFn!(variables, { client: new QueryClient(), meta: undefined, mutationKey: undefined })
  expect(targets).toEqual(['tenant-b'])
  expect(variables).not.toHaveProperty('headers')
})

test('aggregate searches and cursors stay with their tenant section', () => {
  const search = new URLSearchParams('tenant-a.q=alice&tenant-a.cursor=page-a&tenant-b.cursor=page-b')
  expect(tenantSearchParams(search, 'tenant-a').toString()).toBe('q=alice&cursor=page-a')
  const next = replaceTenantSearch(search, 'tenant-a', new URLSearchParams('q=bob'))
  expect(tenantSearchParams(next, 'tenant-a').toString()).toBe('q=bob')
  expect(tenantSearchParams(next, 'tenant-b').get('cursor')).toBe('page-b')
})
