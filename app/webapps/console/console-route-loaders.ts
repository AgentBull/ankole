import { listIdentityProvidersOptions } from './api/v2/generated/@tanstack/react-query.gen'
import type { QueryClient } from '@tanstack/react-query'
import {
  listSignalBindingsOptions,
  getBackgroundAgentJobTurnsOptions,
  getAgentLibraryCapabilitiesOptions,
  getGlobalLibraryCapabilitiesOptions
} from './api/v2/generated/@tanstack/react-query.gen'
import {
  listControlPlanePluginsOptions,
  listSiteAppConfigurationsOptions,
  listSiteWorkerEnvsOptions
} from './api/v2-site/generated/@tanstack/react-query.gen'
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
import { automationJobListOptions } from './pages/automation-jobs'
import { backgroundAgentJobListOptions } from './pages/background-agent-jobs'
import { conversationListOptions } from './pages/conversations'
import { principalListOptions } from './pages/principals'
import { resourceID } from './console-primitives'
import { checkbackListOptions, cronScheduleListOptions } from './pages/schedules'
import { webhookEndpointListOptions } from './pages/webhooks'
import { GLOBAL_LIBRARY_SCOPE, isSiteLibraryDefaults } from './state/agent-library-capabilities'

export interface ConsoleRouteLoaderContext {
  location: { searchStr: string }
}

/**
 * Critical route reads complete before TanStack Router commits the destination.
 * TanStack Query still owns the cache and all later background refreshes.
 */
export function createConsoleRouteLoaders(queryClient: QueryClient) {
  const ensure = queryClient.ensureQueryData.bind(queryClient)
  const all = (...queries: Promise<unknown>[]) => Promise.all(queries).then(() => null)

  // The agent-scoped lists cover every agent unless `?agent=` narrows them.
  const agentFilter = (location: { searchStr: string }) =>
    new URLSearchParams(location.searchStr).get('agent')?.trim() || undefined

  return {
    home: () =>
      all(
        ensure(agentListOptions()),
        ensure(agentWorkerListOptions()),
        ensure(listAiGatewayProvidersOptions()),
        ensure(listIdentityProvidersOptions()),
        ensure(backgroundAgentJobsOptions({ limit: 20 })),
        ensure(aiGatewayConversationsOptions({ limit: 5, min_messages: 2 }))
      ),
    agents: () => ensure(agentListOptions()).then(() => null),
    agentLibrary: ({ location }: ConsoleRouteLoaderContext) => {
      const params = new URLSearchParams(location.searchStr)
      const scope = params.get('scope') || GLOBAL_LIBRARY_SCOPE
      const defaultsScope = params.get('defaults_scope') === 'global' ? 'global' : 'tenant'
      const agents = isSiteLibraryDefaults(scope, defaultsScope) ? Promise.resolve() : ensure(agentListOptions())

      return scope === GLOBAL_LIBRARY_SCOPE
        ? all(
            agents,
            ensure(getGlobalLibraryCapabilitiesOptions({ query: { defaults_scope: defaultsScope } })),
            ensure(listControlPlanePluginsOptions())
          )
        : all(
            agents,
            ensure(getAgentLibraryCapabilitiesOptions({ path: { agent_uid: scope } })),
            ensure(listAgentSkillLessonsOptions({ path: { agent_uid: scope } }))
          )
    },
    providers: () => ensure(listAiGatewayProvidersOptions()).then(() => null),
    identity: () => ensure(listIdentityProvidersOptions()).then(() => null),
    oidcClients: () => all(ensure(listOidcClientsOptions()), ensure(listPrincipalGroupsOptions())),
    identityMappings: () => all(ensure(listIdentityMappingRequestsOptions()), ensure(listPrincipalsOptions())),
    principalGroups: () => ensure(listPrincipalGroupsOptions()).then(() => null),
    principals: () => ensure(principalListOptions()).then(() => null),
    signals: ({ location }: ConsoleRouteLoaderContext) =>
      all(ensure(agentListOptions()), ensure(listSignalBindingsOptions({ query: { agent: agentFilter(location) } }))),
    schedules: ({ location }: ConsoleRouteLoaderContext) =>
      all(ensure(agentListOptions()), ensure(cronScheduleListOptions(agentFilter(location)))),
    scheduleCheckbacks: ({ location }: ConsoleRouteLoaderContext) =>
      all(ensure(agentListOptions()), ensure(checkbackListOptions(agentFilter(location)))),
    webhooks: ({ location }: ConsoleRouteLoaderContext) =>
      all(ensure(agentListOptions()), ensure(webhookEndpointListOptions(agentFilter(location)))),
    automationJobs: ({ location }: ConsoleRouteLoaderContext) =>
      all(ensure(agentListOptions()), ensure(automationJobListOptions(agentFilter(location)))),
    settings: () => ensure(listSiteAppConfigurationsOptions()).then(() => null),
    workerEnvs: () => ensure(listSiteWorkerEnvsOptions()).then(() => null),
    workers: () => ensure(agentWorkerListOptions()).then(() => null),
    backgroundAgentJobs: ({ location }: ConsoleRouteLoaderContext) => {
      const searchParams = new URLSearchParams(location.searchStr)
      const selectedID = resourceID(searchParams.get('job'), 1000)
      const list = ensure(
        backgroundAgentJobListOptions(searchParams.get('agent')?.trim() ?? '', searchParams.get('q') ?? '')
      )

      return selectedID
        ? all(
            list,
            ensure(backgroundAgentJobOptions(selectedID)),
            ensure(
              getBackgroundAgentJobTurnsOptions({
                path: { job_id: selectedID },
                query: { cursor: searchParams.get('cursor') ?? undefined }
              })
            )
          )
        : list.then(() => null)
    },
    conversations: ({ location }: ConsoleRouteLoaderContext) => {
      const searchParams = new URLSearchParams(location.searchStr)

      return ensure(
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
