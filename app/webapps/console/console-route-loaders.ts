import type { QueryClient } from '@tanstack/react-query'
import {
  ankoleWebAgentLibraryCapabilityControllerAgentIndexOptions,
  ankoleWebAgentLibraryCapabilityControllerGlobalIndexOptions,
  ankoleWebAppConfigurationControllerIndexOptions,
  ankoleWebAuthZGroupControllerIndexOptions,
  ankoleWebControlPlanePluginControllerIndexOptions,
  ankoleWebIdentityMappingRequestControllerIndexOptions,
  ankoleWebIdentityProviderControllerIndexOptions,
  ankoleWebPrincipalControllerIndexOptions,
  ankoleWebSignalBindingControllerIndexOptions,
  ankoleWebAiGatewayProviderControllerIndexOptions as ankoleWebAIGatewayProviderControllerIndexOptions,
  ankoleWebBackgroundAgentJobControllerTurnsOptions,
  ankoleWebWorkerEnvControllerIndexOptions
} from './api/generated/@tanstack/react-query.gen'
import { agentWorkerListOptions } from './api/agent-workers'
import { agentListOptions } from './api/agents'
import { aiGatewayConversationsOptions } from './api/ai-gateway-conversations'
import { backgroundAgentJobOptions, backgroundAgentJobsOptions } from './api/background-agent-jobs'
import { listAgentSkillLessonsOptions, listOidcClientsOptions } from './api/v2/generated/@tanstack/react-query.gen'
import { automationJobListOptions } from './pages/automation-jobs'
import { backgroundAgentJobListOptions } from './pages/background-agent-jobs'
import { conversationListOptions } from './pages/conversations'
import { resourceID } from './console-primitives'
import { checkbackListOptions, cronScheduleListOptions } from './pages/schedules'
import { webhookEndpointListOptions } from './pages/webhooks'
import { GLOBAL_LIBRARY_SCOPE } from './state/agent-library-capabilities'

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
        ensure(ankoleWebAIGatewayProviderControllerIndexOptions()),
        ensure(ankoleWebIdentityProviderControllerIndexOptions()),
        ensure(backgroundAgentJobsOptions({ limit: 20 })),
        ensure(aiGatewayConversationsOptions({ limit: 5, min_messages: 2 }))
      ),
    agents: () => ensure(agentListOptions()).then(() => null),
    agentLibrary: ({ location }: ConsoleRouteLoaderContext) => {
      const scope = new URLSearchParams(location.searchStr).get('scope') || GLOBAL_LIBRARY_SCOPE
      const agents = ensure(agentListOptions())

      return scope === GLOBAL_LIBRARY_SCOPE
        ? all(
            agents,
            ensure(ankoleWebAgentLibraryCapabilityControllerGlobalIndexOptions()),
            ensure(ankoleWebControlPlanePluginControllerIndexOptions())
          )
        : all(
            agents,
            ensure(ankoleWebAgentLibraryCapabilityControllerAgentIndexOptions({ path: { agent_uid: scope } })),
            ensure(listAgentSkillLessonsOptions({ path: { agent_uid: scope } }))
          )
    },
    providers: () => ensure(ankoleWebAIGatewayProviderControllerIndexOptions()).then(() => null),
    identity: () => ensure(ankoleWebIdentityProviderControllerIndexOptions()).then(() => null),
    oidcClients: () => all(ensure(listOidcClientsOptions()), ensure(ankoleWebAuthZGroupControllerIndexOptions())),
    identityMappings: () =>
      all(
        ensure(ankoleWebIdentityMappingRequestControllerIndexOptions()),
        ensure(ankoleWebPrincipalControllerIndexOptions())
      ),
    principalGroups: () => ensure(ankoleWebAuthZGroupControllerIndexOptions()).then(() => null),
    principals: () => ensure(ankoleWebPrincipalControllerIndexOptions()).then(() => null),
    signals: ({ location }: ConsoleRouteLoaderContext) =>
      all(
        ensure(agentListOptions()),
        ensure(ankoleWebSignalBindingControllerIndexOptions({ query: { agent: agentFilter(location) } }))
      ),
    schedules: ({ location }: ConsoleRouteLoaderContext) =>
      all(ensure(agentListOptions()), ensure(cronScheduleListOptions(agentFilter(location)))),
    scheduleCheckbacks: ({ location }: ConsoleRouteLoaderContext) =>
      all(ensure(agentListOptions()), ensure(checkbackListOptions(agentFilter(location)))),
    webhooks: ({ location }: ConsoleRouteLoaderContext) =>
      all(ensure(agentListOptions()), ensure(webhookEndpointListOptions(agentFilter(location)))),
    automationJobs: ({ location }: ConsoleRouteLoaderContext) =>
      all(ensure(agentListOptions()), ensure(automationJobListOptions(agentFilter(location)))),
    settings: () => ensure(ankoleWebAppConfigurationControllerIndexOptions()).then(() => null),
    workerEnvs: () => ensure(ankoleWebWorkerEnvControllerIndexOptions()).then(() => null),
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
              ankoleWebBackgroundAgentJobControllerTurnsOptions({
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
