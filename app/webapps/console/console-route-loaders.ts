import { listIdentityProvidersOptions } from './api/v2/generated/@tanstack/react-query.gen'
import type { QueryClient, QueryKey } from '@tanstack/react-query'
import {
  listSignalBindingsOptions,
  getBackgroundAgentJobTurnsOptions,
  getAgentLibraryCapabilitiesOptions,
  getGlobalLibraryCapabilitiesOptions
} from './api/v2/generated/@tanstack/react-query.gen'
import {
  getSiteOverviewOptions,
  listControlPlanePluginsOptions,
  listSiteAppConfigurationsOptions,
  listSiteWorkerEnvsOptions,
  listTenantsOptions
} from './api/v2-site/generated/@tanstack/react-query.gen'
import { dataTenantID, setDataTenantSoft } from '../common/browser-session'
import { agentWorkerListOptions } from './api/agent-workers'
import { agentListOptions } from './api/agents'
import { aiGatewayConversationsOptions } from './api/ai-gateway-conversations'
import { backgroundAgentJobOptions, backgroundAgentJobsOptions } from './api/background-agent-jobs'
import {
  listAgentSkillLessonsOptions,
  listIdentityMappingRequestsOptions,
  listOidcClientsOptions,
  listPrincipalGroupsOptions,
  listPrincipalsOptions
} from './api/v2/generated/@tanstack/react-query.gen'
import { listAiGatewayProvidersOptions } from './api/v2-site/generated/@tanstack/react-query.gen'
import { resourceID } from './console-primitives'
import { GLOBAL_LIBRARY_SCOPE, isSiteLibraryDefaults } from './state/agent-library-capabilities'
import { tenantQueryOptions } from './state/tenant-scope'

export interface ConsoleRouteLoaderContext {
  location: { searchStr: string }
}

/**
 * Critical route reads complete before TanStack Router commits the destination.
 * TanStack Query still owns the cache and all later background refreshes.
 */
export function createConsoleRouteLoaders(queryClient: QueryClient) {
  const ensure = queryClient.ensureQueryData.bind(queryClient)
  const ensureTenant = <T extends { queryKey: QueryKey }>(tenantID: string | null, options: T) =>
    ensure((tenantID ? tenantQueryOptions(options, tenantID) : options) as Parameters<typeof ensure>[0])
  const canPrefetchTenant = (tenantID: string | null) => Boolean(tenantID) || typeof window === 'undefined'
  const all = (...queries: Promise<unknown>[]) => Promise.all(queries).then(() => null)

  // In a live browser session without a selected data tenant, check whether the
  // site has a single active tenant (auto-bind) or multiple tenants (aggregate).
  const resolveEffectiveTenantID = async (searchStr = ''): Promise<string | null> => {
    if (typeof window === 'undefined') return null
    const current = dataTenantID()
    if (current) return current
    const explicitAll = new URLSearchParams(searchStr).get('data_tenant') === ''
    const tenants = await ensure(listTenantsOptions())
    const active = (tenants.data ?? []).filter(tenant => !tenant.attributes?.deleting_at)
    if (!explicitAll && active.length === 1 && active[0]?.id) {
      setDataTenantSoft(active[0].id)
      return active[0].id
    }
    return null
  }

  // The agent-scoped lists cover every agent unless `?agent=` narrows them.
  const agentFilter = (location: { searchStr: string }) =>
    new URLSearchParams(location.searchStr).get('agent')?.trim() || undefined

  return {
    home: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      return canPrefetchTenant(tenantID)
        ? all(
            ensureTenant(tenantID, agentListOptions()),
            ensureTenant(tenantID, agentWorkerListOptions()),
            ensure(listAiGatewayProvidersOptions()),
            ensureTenant(tenantID, listIdentityProvidersOptions()),
            ensureTenant(tenantID, backgroundAgentJobsOptions({ limit: 20 })),
            ensureTenant(tenantID, aiGatewayConversationsOptions({ limit: 5, min_messages: 2 }))
          )
        : all(ensure(getSiteOverviewOptions()), ensure(listAiGatewayProvidersOptions()))
    },
    agents: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      return canPrefetchTenant(tenantID) ? ensureTenant(tenantID, agentListOptions()).then(() => null) : null
    },
    agentLibrary: async ({ location }: ConsoleRouteLoaderContext) => {
      const params = new URLSearchParams(location.searchStr)
      const scope = params.get('scope') || GLOBAL_LIBRARY_SCOPE
      const defaultsScope = params.get('defaults_scope') === 'global' ? 'global' : 'tenant'
      if (isSiteLibraryDefaults(scope, defaultsScope)) {
        return all(
          ensure(getGlobalLibraryCapabilitiesOptions({ query: { defaults_scope: defaultsScope } })),
          ensure(listControlPlanePluginsOptions())
        )
      }
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      if (!canPrefetchTenant(tenantID)) return null
      const agents = ensureTenant(tenantID, agentListOptions())

      return scope === GLOBAL_LIBRARY_SCOPE
        ? all(
            agents,
            ensureTenant(tenantID, getGlobalLibraryCapabilitiesOptions({ query: { defaults_scope: defaultsScope } })),
            ensure(listControlPlanePluginsOptions())
          )
        : all(
            agents,
            ensureTenant(tenantID, getAgentLibraryCapabilitiesOptions({ path: { agent_uid: scope } })),
            ensureTenant(tenantID, listAgentSkillLessonsOptions({ path: { agent_uid: scope } }))
          )
    },
    providers: () => ensure(listAiGatewayProvidersOptions()).then(() => null),
    identity: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      return canPrefetchTenant(tenantID)
        ? ensureTenant(tenantID, listIdentityProvidersOptions()).then(() => null)
        : null
    },
    oidcClients: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      return canPrefetchTenant(tenantID)
        ? all(ensureTenant(tenantID, listOidcClientsOptions()), ensureTenant(tenantID, listPrincipalGroupsOptions()))
        : null
    },
    identityMappings: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      return canPrefetchTenant(tenantID)
        ? all(
            ensureTenant(tenantID, listIdentityMappingRequestsOptions()),
            ensureTenant(tenantID, listPrincipalsOptions())
          )
        : null
    },
    principalGroups: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      return canPrefetchTenant(tenantID) ? ensureTenant(tenantID, listPrincipalGroupsOptions()).then(() => null) : null
    },
    principals: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      if (!canPrefetchTenant(tenantID)) return null
      const { principalListOptions } = await import('./pages/principals')
      await ensureTenant(tenantID, principalListOptions())
      return null
    },
    signals: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      return canPrefetchTenant(tenantID)
        ? all(
            ensureTenant(tenantID, agentListOptions()),
            ensureTenant(tenantID, listSignalBindingsOptions({ query: { agent: agentFilter(location) } }))
          )
        : null
    },
    schedules: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      if (!canPrefetchTenant(tenantID)) return null
      const { cronScheduleListOptions } = await import('./pages/schedules')
      return all(
        ensureTenant(tenantID, agentListOptions()),
        ensureTenant(tenantID, cronScheduleListOptions(agentFilter(location)))
      )
    },
    scheduleCheckbacks: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      if (!canPrefetchTenant(tenantID)) return null
      const { checkbackListOptions } = await import('./pages/schedules')
      return all(
        ensureTenant(tenantID, agentListOptions()),
        ensureTenant(tenantID, checkbackListOptions(agentFilter(location)))
      )
    },
    webhooks: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      if (!canPrefetchTenant(tenantID)) return null
      const { webhookEndpointListOptions } = await import('./pages/webhooks')
      return all(
        ensureTenant(tenantID, agentListOptions()),
        ensureTenant(tenantID, webhookEndpointListOptions(agentFilter(location)))
      )
    },
    automationJobs: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      if (!canPrefetchTenant(tenantID)) return null
      const { automationJobListOptions } = await import('./pages/automation-jobs')
      return ensureTenant(tenantID, automationJobListOptions()).then(() => null)
    },
    settings: () => ensure(listSiteAppConfigurationsOptions()).then(() => null),
    workerEnvs: () => ensure(listSiteWorkerEnvsOptions()).then(() => null),
    workers: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      return canPrefetchTenant(tenantID) ? ensureTenant(tenantID, agentWorkerListOptions()).then(() => null) : null
    },
    backgroundAgentJobs: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      if (!canPrefetchTenant(tenantID)) return null
      const { backgroundAgentJobListOptions, backgroundAgentJobStatusParam } =
        await import('./pages/background-agent-jobs')
      const searchParams = new URLSearchParams(location.searchStr)
      const selectedID = resourceID(searchParams.get('job'), 1000)
      const list = ensureTenant(
        tenantID,
        backgroundAgentJobListOptions(
          searchParams.get('agent')?.trim() ?? '',
          searchParams.get('q') ?? '',
          backgroundAgentJobStatusParam(searchParams.get('status'))
        )
      )

      return selectedID
        ? all(
            list,
            ensureTenant(tenantID, backgroundAgentJobOptions(selectedID)),
            ensureTenant(
              tenantID,
              getBackgroundAgentJobTurnsOptions({
                path: { job_id: selectedID },
                query: { cursor: searchParams.get('cursor') ?? undefined }
              })
            )
          )
        : list.then(() => null)
    },
    conversations: async ({ location }: ConsoleRouteLoaderContext) => {
      const tenantID = await resolveEffectiveTenantID(location.searchStr)
      if (!canPrefetchTenant(tenantID)) return null
      const { conversationListOptions } = await import('./pages/conversations')
      const searchParams = new URLSearchParams(location.searchStr)

      return ensureTenant(
        tenantID,
        conversationListOptions({
          q: searchParams.get('q'),
          subject: searchParams.get('agent'),
          active: searchParams.get('active'),
          showAll: searchParams.get('min_messages') === '0',
          cursor: searchParams.get('cursor')
        })
      ).then(() => null)
    }
  }
}
