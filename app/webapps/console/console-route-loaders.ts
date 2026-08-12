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
  ankoleWebAutomationJobControllerShowOptions,
  ankoleWebBackgroundAgentJobControllerIndexOptions,
  ankoleWebBackgroundAgentJobControllerShowOptions,
  ankoleWebBrainControllerIndexOptions,
  ankoleWebControlPlanePluginControllerIndexOptions,
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
import { localDateStartISO } from './pages/brain-shared'
import { GLOBAL_LIBRARY_SCOPE } from './state/agent-library-capabilities'
import { defaultBrainOwnerUID } from './state/brain-editor-model'

/**
 * Critical route reads complete before React Router commits the destination.
 * TanStack Query still owns the cache and all later background refreshes.
 */
export function createConsoleRouteLoaders(queryClient: QueryClient) {
  const ensure = queryClient.ensureQueryData.bind(queryClient)
  const all = (...queries: Promise<unknown>[]) => Promise.all(queries).then(() => null)

  const scopedAgentUID = async (request: Request) => {
    const agents = await ensure(ankoleWebAgentControllerIndexOptions())
    const requested = new URL(request.url).searchParams.get('agent')?.trim()
    return requested || agents.agents[0]?.uid || ''
  }

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
    principalGroups: () => ensure(ankoleWebAuthZGroupControllerIndexOptions()).then(() => null),
    principals: () => ensure(ankoleWebPrincipalControllerIndexOptions()).then(() => null),
    signals: async ({ request }: LoaderFunctionArgs) => {
      const agentUID = await scopedAgentUID(request)
      if (agentUID) await ensure(ankoleWebSignalBindingControllerIndexOptions({ path: { agent_uid: agentUID } }))
      return null
    },
    schedules: async ({ request }: LoaderFunctionArgs) => {
      const agentUID = await scopedAgentUID(request)
      if (!agentUID) return null

      return all(
        ensure(ankoleWebScheduleControllerIndexCronOptions({ path: { agent_uid: agentUID } })),
        ensure(ankoleWebScheduleControllerIndexCheckbacksOptions({ path: { agent_uid: agentUID } }))
      )
    },
    webhooks: async ({ request }: LoaderFunctionArgs) => {
      const agentUID = await scopedAgentUID(request)
      if (agentUID) await ensure(ankoleWebWebhookEndpointControllerIndexOptions({ path: { agent_uid: agentUID } }))
      return null
    },
    automationJobs: async ({ request }: LoaderFunctionArgs) => {
      const agentUID = await scopedAgentUID(request)
      if (!agentUID) return null

      const selectedID = resourceID(new URL(request.url).searchParams.get('job'))
      const jobs = ensure(
        ankoleWebAutomationJobControllerIndexOptions({ path: { agent_uid: agentUID }, query: { limit: 100 } })
      )

      return selectedID
        ? all(
            jobs,
            ensure(
              ankoleWebAutomationJobControllerShowOptions({
                path: { agent_uid: agentUID, automation_job_id: selectedID },
                query: { runs: 20 }
              })
            )
          )
        : jobs.then(() => null)
    },
    settings: () => ensure(ankoleWebAppConfigurationControllerIndexOptions()).then(() => null),
    workerEnvs: () => ensure(ankoleWebWorkerEnvControllerIndexOptions()).then(() => null),
    workers: () => ensure(ankoleWebAgentComputerWorkerControllerIndexOptions()).then(() => null),
    backgroundAgentJobs: ({ request }: LoaderFunctionArgs) => {
      const searchParams = new URL(request.url).searchParams
      const selectedID = resourceID(searchParams.get('job'))
      const list = ensure(
        ankoleWebBackgroundAgentJobControllerIndexOptions({
          query: { agent: searchParams.get('agent')?.trim() || undefined, limit: 100 }
        })
      )

      return selectedID
        ? all(list, ensure(ankoleWebBackgroundAgentJobControllerShowOptions({ path: { job_id: selectedID } })))
        : list.then(() => null)
    },
    conversations: ({ request }: LoaderFunctionArgs) => {
      const searchParams = new URL(request.url).searchParams
      const active = searchParams.get('active')
      const showAll = searchParams.get('min_messages') === '0'

      return ensure(
        ankoleWebAIGatewayConversationControllerIndexOptions({
          query: {
            subject: searchParams.get('subject')?.trim() || undefined,
            active: active === 'true' ? true : active === 'false' ? false : undefined,
            min_messages: showAll ? undefined : 2,
            cursor: searchParams.get('cursor') || undefined,
            limit: 50
          }
        })
      ).then(() => null)
    },
    brain: async ({ request }: LoaderFunctionArgs) => {
      const searchParams = new URL(request.url).searchParams
      const principals = await ensure(ankoleWebPrincipalControllerIndexOptions())
      const ownerUID = searchParams.get('owner') || defaultBrainOwnerUID(principals.principals)
      if (!ownerUID) return null

      return all(
        ensure(
          ankoleWebBrainControllerIndexOptions({
            query: {
              owner_uid: ownerUID,
              query: searchParams.get('q') || undefined,
              type: searchParams.get('type') || undefined,
              store: searchParams.get('store') || undefined,
              author: searchParams.get('author') || undefined,
              updated: localDateStartISO(searchParams.get('updated') || ''),
              cursor: searchParams.get('cursor') || undefined,
              limit: 50
            }
          })
        ),
        ensure(
          ankoleWebBrainControllerIndexOptions({
            query: { owner_uid: ownerUID, store: 'self', type: 'brain_curation_guide', limit: 1 }
          })
        )
      )
    }
  }
}

/** Parses a route or search parameter into a resource id. Real resource ids
 * are integers that start at 1000; anything else means "nothing selected". */
export function resourceID(value: string | null): number | undefined {
  if (!value || !/^[1-9][0-9]*$/.test(value)) return undefined

  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed >= 1000 ? parsed : undefined
}
