import type { QueryClient } from '@tanstack/react-query'
import type { LoaderFunctionArgs } from 'react-router'
import {
  ankoleWebAgentComputerWorkerControllerIndexOptions,
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAgentLibraryCapabilityControllerAgentIndexOptions,
  ankoleWebAgentLibraryCapabilityControllerGlobalIndexOptions,
  ankoleWebAgentLibrarySkillOverlayControllerIndexOptions,
  ankoleWebAppConfigurationControllerIndexOptions,
  ankoleWebAuthZGroupControllerIndexOptions,
  ankoleWebAutomationJobControllerIndexOptions,
  ankoleWebBackgroundAgentJobControllerIndexOptions,
  ankoleWebBackgroundAgentJobControllerShowOptions,
  ankoleWebControlPlanePluginControllerIndexOptions,
  ankoleWebIdentityMappingRequestControllerIndexOptions,
  ankoleWebIdentityProviderControllerIndexOptions,
  ankoleWebPrincipalControllerIndexOptions,
  ankoleWebScheduleControllerIndexCheckbacksOptions,
  ankoleWebScheduleControllerIndexCronOptions,
  ankoleWebSignalBindingControllerIndexOptions,
  ankoleWebAiGatewayConversationControllerIndexOptions as ankoleWebAIGatewayConversationControllerIndexOptions,
  ankoleWebAiGatewayProviderControllerIndexOptions as ankoleWebAIGatewayProviderControllerIndexOptions,
  ankoleWebWebhookEndpointControllerIndexOptions,
  ankoleWebWorkerEnvControllerIndexOptions
} from './api/generated/@tanstack/react-query.gen'
import { backgroundAgentJobListOptions } from './pages/background-agent-jobs'
import { conversationListOptions } from './pages/conversations'
import { GLOBAL_LIBRARY_SCOPE } from './state/agent-library-capabilities'

/**
 * Critical route reads complete before React Router commits the destination.
 * TanStack Query still owns the cache and all later background refreshes.
 */
export function createConsoleRouteLoaders(queryClient: QueryClient) {
  const ensure = queryClient.ensureQueryData.bind(queryClient)
  const all = (...queries: Promise<unknown>[]) => Promise.all(queries).then(() => null)

  // The agent-scoped lists cover every agent unless `?agent=` narrows them.
  const agentFilter = (request: Request) => new URL(request.url).searchParams.get('agent')?.trim() || undefined

  return {
    home: () =>
      all(
        ensure(ankoleWebAgentControllerIndexOptions()),
        ensure(ankoleWebAgentComputerWorkerControllerIndexOptions()),
        ensure(ankoleWebAIGatewayProviderControllerIndexOptions()),
        ensure(ankoleWebIdentityProviderControllerIndexOptions()),
        ensure(ankoleWebBackgroundAgentJobControllerIndexOptions({ query: { limit: 20 } })),
        ensure(ankoleWebAIGatewayConversationControllerIndexOptions({ query: { limit: 5, min_messages: 2 } }))
      ),
    agents: () => ensure(ankoleWebAgentControllerIndexOptions()).then(() => null),
    agentLibrary: ({ request }: LoaderFunctionArgs) => {
      const scope = new URL(request.url).searchParams.get('scope') || GLOBAL_LIBRARY_SCOPE
      const agents = ensure(ankoleWebAgentControllerIndexOptions())

      return scope === GLOBAL_LIBRARY_SCOPE
        ? all(
            agents,
            ensure(ankoleWebAgentLibraryCapabilityControllerGlobalIndexOptions()),
            ensure(ankoleWebControlPlanePluginControllerIndexOptions())
          )
        : all(
            agents,
            ensure(ankoleWebAgentLibraryCapabilityControllerAgentIndexOptions({ path: { agent_uid: scope } })),
            ensure(ankoleWebAgentLibrarySkillOverlayControllerIndexOptions({ path: { agent_uid: scope } }))
          )
    },
    providers: () => ensure(ankoleWebAIGatewayProviderControllerIndexOptions()).then(() => null),
    identity: () => ensure(ankoleWebIdentityProviderControllerIndexOptions()).then(() => null),
    identityMappings: () =>
      all(
        ensure(ankoleWebIdentityMappingRequestControllerIndexOptions()),
        ensure(ankoleWebPrincipalControllerIndexOptions())
      ),
    principalGroups: () => ensure(ankoleWebAuthZGroupControllerIndexOptions()).then(() => null),
    principals: () => ensure(ankoleWebPrincipalControllerIndexOptions()).then(() => null),
    signals: ({ request }: LoaderFunctionArgs) =>
      all(
        ensure(ankoleWebAgentControllerIndexOptions()),
        ensure(ankoleWebSignalBindingControllerIndexOptions({ query: { agent: agentFilter(request) } }))
      ),
    schedules: ({ request }: LoaderFunctionArgs) =>
      all(
        ensure(ankoleWebAgentControllerIndexOptions()),
        ensure(ankoleWebScheduleControllerIndexCronOptions({ query: { agent: agentFilter(request) } }))
      ),
    scheduleCheckbacks: ({ request }: LoaderFunctionArgs) =>
      all(
        ensure(ankoleWebAgentControllerIndexOptions()),
        ensure(ankoleWebScheduleControllerIndexCheckbacksOptions({ query: { agent: agentFilter(request) } }))
      ),
    webhooks: ({ request }: LoaderFunctionArgs) =>
      all(
        ensure(ankoleWebAgentControllerIndexOptions()),
        ensure(ankoleWebWebhookEndpointControllerIndexOptions({ query: { agent: agentFilter(request) } }))
      ),
    automationJobs: ({ request }: LoaderFunctionArgs) =>
      all(
        ensure(ankoleWebAgentControllerIndexOptions()),
        ensure(
          ankoleWebAutomationJobControllerIndexOptions({
            query: { agent: agentFilter(request), limit: 100 }
          })
        )
      ),
    settings: () => ensure(ankoleWebAppConfigurationControllerIndexOptions()).then(() => null),
    workerEnvs: () => ensure(ankoleWebWorkerEnvControllerIndexOptions()).then(() => null),
    workers: () => ensure(ankoleWebAgentComputerWorkerControllerIndexOptions()).then(() => null),
    backgroundAgentJobs: ({ request }: LoaderFunctionArgs) => {
      const searchParams = new URL(request.url).searchParams
      const selectedID = resourceID(searchParams.get('job'), 1000)
      const list = ensure(
        backgroundAgentJobListOptions(searchParams.get('agent')?.trim() ?? '', searchParams.get('q') ?? '')
      )

      return selectedID
        ? all(list, ensure(ankoleWebBackgroundAgentJobControllerShowOptions({ path: { job_id: selectedID } })))
        : list.then(() => null)
    },
    conversations: ({ request }: LoaderFunctionArgs) => {
      const searchParams = new URL(request.url).searchParams

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

/** Parses a decimal route identifier and applies the owning API's lower bound. */
export function resourceID(value: string | null, minimum: number): number | undefined {
  if (!value || !/^[1-9][0-9]*$/.test(value)) return undefined

  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed >= minimum ? parsed : undefined
}
