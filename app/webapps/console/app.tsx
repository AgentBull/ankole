import type { QueryClient } from '@tanstack/react-query'
import {
  createRootRoute,
  createRoute,
  createRouter,
  lazyRouteComponent,
  Navigate,
  RouterProvider
} from '@tanstack/react-router'
import { configureConsoleAPIClient } from './api/client'
import { applyDataTenantNavigation } from '../common/browser-session'
import { parseRouterSearch, stringifyRouterSearch } from '../common/router'
import { createConsoleRouteLoaders } from './console-route-loaders'
import { ConsoleLayout } from './console-shell-chrome'
import { HomePage, NotFoundPage, RouteErrorPage } from './pages/home'
import { SlotBoundary, SlotGate } from '../common/slots'
import { ConsoleSlotsContext, normalizeConsoleSlotPath, validateConsoleSlots, type ConsoleAppSlots } from './slots'

const AgentEditorPage = lazyRouteComponent(() => import('./pages/agents'), 'AgentEditorPage')
const AgentsListPage = lazyRouteComponent(() => import('./pages/agents'), 'AgentsListPage')
const AgentFilesPage = lazyRouteComponent(() => import('./pages/agent-files'), 'AgentFilesPage')
const IdentityProviderEditorPage = lazyRouteComponent(() => import('./pages/identity'), 'IdentityProviderEditorPage')
const IdentityProvidersListPage = lazyRouteComponent(() => import('./pages/identity'), 'IdentityProvidersListPage')
const IdentityMappingCreatePage = lazyRouteComponent(
  () => import('./pages/identity-mappings'),
  'IdentityMappingCreatePage'
)
const IdentityMappingsPage = lazyRouteComponent(() => import('./pages/identity-mappings'), 'IdentityMappingsPage')
const ProviderEditorPage = lazyRouteComponent(() => import('./pages/providers'), 'ProviderEditorPage')
const ProvidersListPage = lazyRouteComponent(() => import('./pages/providers'), 'ProvidersListPage')
const ModelProfilesPage = lazyRouteComponent(() => import('./pages/model-profiles'), 'ModelProfilesPage')
const SettingEditorDrawer = lazyRouteComponent(() => import('./pages/settings'), 'SettingEditorDrawer')
const SettingGroupDrawer = lazyRouteComponent(() => import('./pages/settings'), 'SettingGroupDrawer')
const SettingsPage = lazyRouteComponent(() => import('./pages/settings'), 'SettingsPage')
const SignalBindingEditorPage = lazyRouteComponent(() => import('./pages/signals'), 'SignalBindingEditorPage')
const SignalsListPage = lazyRouteComponent(() => import('./pages/signals'), 'SignalsListPage')
const ScheduleCheckbacksPage = lazyRouteComponent(() => import('./pages/schedules'), 'ScheduleCheckbacksPage')
const ScheduleCronEditorPage = lazyRouteComponent(() => import('./pages/schedules'), 'ScheduleCronEditorPage')
const SchedulesListPage = lazyRouteComponent(() => import('./pages/schedules'), 'SchedulesListPage')
const WebhooksPage = lazyRouteComponent(() => import('./pages/webhooks'), 'WebhooksPage')
const AutomationJobsPage = lazyRouteComponent(() => import('./pages/automation-jobs'), 'AutomationJobsPage')
const WorkerEnvEditorPage = lazyRouteComponent(() => import('./pages/worker-envs'), 'WorkerEnvEditorPage')
const WorkerEnvsListPage = lazyRouteComponent(() => import('./pages/worker-envs'), 'WorkerEnvsListPage')
const WorkersListPage = lazyRouteComponent(() => import('./pages/workers'), 'WorkersListPage')
const WorkerProviderEditorPage = lazyRouteComponent(
  () => import('./pages/worker-providers'),
  'WorkerProviderEditorPage'
)
const WorkerProvidersListPage = lazyRouteComponent(() => import('./pages/worker-providers'), 'WorkerProvidersListPage')
const BackgroundAgentJobsPage = lazyRouteComponent(
  () => import('./pages/background-agent-jobs'),
  'BackgroundAgentJobsPage'
)
const ConversationDetailPage = lazyRouteComponent(() => import('./pages/conversations'), 'ConversationDetailPage')
const ConversationsListPage = lazyRouteComponent(() => import('./pages/conversations'), 'ConversationsListPage')
const AgentLibraryPage = lazyRouteComponent(() => import('./pages/agent-library'), 'AgentLibraryPage')
const AgentPluginDetailPage = lazyRouteComponent(() => import('./pages/agent-library'), 'AgentPluginDetailPage')
const BrainObjectDrawer = lazyRouteComponent(() => import('./pages/brain/objects'), 'BrainObjectDrawer')
const BrainObjectsPage = lazyRouteComponent(() => import('./pages/brain/objects'), 'BrainObjectsPage')
const BrainObjectEditorPage = lazyRouteComponent(() => import('./pages/brain/object-editor'), 'BrainObjectEditorPage')
const BrainClaimsPage = lazyRouteComponent(() => import('./pages/brain/claims'), 'BrainClaimsPage')
const BrainContradictionsPage = lazyRouteComponent(
  () => import('./pages/brain/contradictions'),
  'BrainContradictionsPage'
)
const BrainMergeSuggestionsPage = lazyRouteComponent(
  () => import('./pages/brain/merge-suggestions'),
  'BrainMergeSuggestionsPage'
)
const BrainSourcesPage = lazyRouteComponent(() => import('./pages/brain/sources'), 'BrainSourcesPage')
const BrainSuggestionsPage = lazyRouteComponent(() => import('./pages/brain/suggestions'), 'BrainSuggestionsPage')
const BrainSearchPreviewPage = lazyRouteComponent(
  () => import('./pages/brain/search-preview'),
  'BrainSearchPreviewPage'
)
const BrainPrincipalAuditPage = lazyRouteComponent(
  () => import('./pages/brain/principal-audit'),
  'BrainPrincipalAuditPage'
)
const BrainHealthPage = lazyRouteComponent(() => import('./pages/brain/health'), 'BrainHealthPage')
const PrincipalGroupEditorPage = lazyRouteComponent(
  () => import('./pages/principal-groups'),
  'PrincipalGroupEditorPage'
)
const PrincipalGroupsListPage = lazyRouteComponent(() => import('./pages/principal-groups'), 'PrincipalGroupsListPage')
const PrincipalCreatePage = lazyRouteComponent(() => import('./pages/principal-create'), 'PrincipalCreatePage')
const PrincipalEditPage = lazyRouteComponent(() => import('./pages/principal-edit'), 'PrincipalEditPage')
const PrincipalDetailPage = lazyRouteComponent(() => import('./pages/principals'), 'PrincipalDetailPage')
const PrincipalsListPage = lazyRouteComponent(() => import('./pages/principals'), 'PrincipalsListPage')
const PermissionGrantEditorPage = lazyRouteComponent(
  () => import('./pages/permission-grant-editor'),
  'PermissionGrantEditorPage'
)
const OIDCClientEditorPage = lazyRouteComponent(() => import('./pages/oidc-clients'), 'OIDCClientEditorPage')
const OIDCClientsListPage = lazyRouteComponent(() => import('./pages/oidc-clients'), 'OIDCClientsListPage')
const TenantsListPage = lazyRouteComponent(() => import('./pages/tenants'), 'TenantsListPage')
const TenantEditorPage = lazyRouteComponent(() => import('./pages/tenants'), 'TenantEditorPage')

export type { ConsoleAppSlots } from './slots'

// Set the session and CSRF configuration before route components start queries.
configureConsoleAPIClient()

// The authenticated Phoenix shell supplies the runtime mount for client-side
// routing. Each resource is a list route plus its editor
// routes. Settings are the exception: the key route is nested so its editor can
// stay deep-linkable while opening as a drawer over the list.
export function createConsoleRouter(queryClient: QueryClient, slots: ConsoleAppSlots = {}) {
  validateConsoleSlots(slots)
  applyDataTenantNavigation()
  const basename = document.querySelector<HTMLMetaElement>('meta[name="ankole-site-admin-console-path"]')?.content
  if (!basename) throw new Error('The authenticated console shell did not provide its mount path')
  const loaders = createConsoleRouteLoaders(queryClient)

  // Without this the router shows its own built-in screen when the shell
  // throws: a stack trace with no navigation and no way back in.
  const rootRoute = createRootRoute({
    component: ConsoleLayout,
    errorComponent: RouteErrorPage
  })

  // Page and loader errors stay inside the persistent Console shell.
  const bodyRoute = createRoute({
    getParentRoute: () => rootRoute,
    id: 'console-body',
    errorComponent: RouteErrorPage
  })

  const brainObjectsRoute = createRoute({
    getParentRoute: () => bodyRoute,
    path: 'brain/objects',
    component: BrainObjectsPage
  })

  const settingsRoute = createRoute({
    getParentRoute: () => bodyRoute,
    path: 'settings',
    component: SettingsPage,
    loader: loaders.settings
  })

  const routeTree = rootRoute.addChildren([
    bodyRoute.addChildren([
      createRoute({ getParentRoute: () => bodyRoute, path: '/', component: HomePage, loader: loaders.home }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'agents',
        component: AgentsListPage,
        loader: loaders.agents
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'tenants', component: TenantsListPage }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'tenants/new', component: TenantEditorPage }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'tenants/$tenantID', component: TenantEditorPage }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'agents/new', component: AgentEditorPage }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'agents/$uid', component: AgentEditorPage }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'drive', component: AgentFilesPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'agent-library',
        component: AgentLibraryPage,
        loader: loaders.agentLibrary
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'agent-library/agent-plugins/$pluginID',
        component: AgentPluginDetailPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'brain',
        component: () => <Navigate to="/brain/objects" replace />
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'brain/objects/new', component: BrainObjectEditorPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'brain/objects/$slug/edit',
        component: BrainObjectEditorPage
      }),
      brainObjectsRoute.addChildren([
        createRoute({ getParentRoute: () => brainObjectsRoute, path: '/', component: () => null }),
        createRoute({ getParentRoute: () => brainObjectsRoute, path: '$', component: BrainObjectDrawer })
      ]),
      createRoute({ getParentRoute: () => bodyRoute, path: 'brain/claims', component: BrainClaimsPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'brain/contradictions',
        component: BrainContradictionsPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'brain/merge-suggestions',
        component: BrainMergeSuggestionsPage
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'brain/sources', component: BrainSourcesPage }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'brain/suggestions', component: BrainSuggestionsPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'brain/search-preview',
        component: BrainSearchPreviewPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'brain/principal-audit',
        component: BrainPrincipalAuditPage
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'brain/health', component: BrainHealthPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'providers',
        component: ProvidersListPage,
        loader: loaders.providers
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'model-profiles', component: ModelProfilesPage }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'providers/new', component: ProviderEditorPage }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'providers/$providerID', component: ProviderEditorPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'identity',
        component: IdentityProvidersListPage,
        loader: loaders.identity
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'identity/new', component: IdentityProviderEditorPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'identity/mappings',
        component: IdentityMappingsPage,
        loader: loaders.identityMappings
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'identity/mappings/new',
        component: IdentityMappingCreatePage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'identity/$providerID',
        component: IdentityProviderEditorPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'oidc-clients',
        component: OIDCClientsListPage,
        loader: loaders.oidcClients
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'oidc-clients/new', component: OIDCClientEditorPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'oidc-clients/$clientID',
        component: OIDCClientEditorPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'access',
        component: () => <Navigate to="/access/groups" replace />
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'access/groups',
        component: PrincipalGroupsListPage,
        loader: loaders.principalGroups
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'access/groups/new', component: PrincipalGroupEditorPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'access/groups/$name',
        component: PrincipalGroupEditorPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'access/groups/$name/grants/new',
        component: () => <PermissionGrantEditorPage createFor="group" />
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'access/principals',
        component: PrincipalsListPage,
        loader: loaders.principals
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'access/principals/new', component: PrincipalCreatePage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'access/principals/$uid',
        component: PrincipalDetailPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'access/principals/$uid/edit',
        component: PrincipalEditPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'access/principals/$uid/grants/new',
        component: () => <PermissionGrantEditorPage createFor="principal" />
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'access/grants/$grantID',
        component: PermissionGrantEditorPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'signals',
        component: SignalsListPage,
        loader: loaders.signals
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'signals/new', component: SignalBindingEditorPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'signals/$id',
        component: SignalBindingEditorPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'schedules',
        component: SchedulesListPage,
        loader: loaders.schedules
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'schedules/checkbacks',
        component: ScheduleCheckbacksPage,
        loader: loaders.scheduleCheckbacks
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'schedules/new', component: ScheduleCronEditorPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'schedules/$agent/$cronID',
        component: ScheduleCronEditorPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'webhooks',
        component: WebhooksPage,
        loader: loaders.webhooks
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'automation-jobs',
        component: AutomationJobsPage,
        loader: loaders.automationJobs
      }),
      settingsRoute.addChildren([
        createRoute({ getParentRoute: () => settingsRoute, path: 'group/$group', component: SettingGroupDrawer }),
        createRoute({ getParentRoute: () => settingsRoute, path: '$key', component: SettingEditorDrawer })
      ]),
      createRoute({ getParentRoute: () => bodyRoute, path: 'worker-providers', component: WorkerProvidersListPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'worker-providers/new',
        component: WorkerProviderEditorPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'worker-providers/$providerID',
        component: WorkerProviderEditorPage
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'worker-envs',
        component: WorkerEnvsListPage,
        loader: loaders.workerEnvs
      }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'worker-envs/new', component: WorkerEnvEditorPage }),
      createRoute({ getParentRoute: () => bodyRoute, path: 'worker-envs/$name', component: WorkerEnvEditorPage }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'workers',
        component: WorkersListPage,
        loader: loaders.workers
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'background-agent-jobs',
        component: BackgroundAgentJobsPage,
        loader: loaders.backgroundAgentJobs
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'conversations',
        component: ConversationsListPage,
        loader: loaders.conversations
      }),
      createRoute({
        getParentRoute: () => bodyRoute,
        path: 'conversations/$conversationID',
        component: ConversationDetailPage
      }),
      ...(slots.routes ?? []).map(route =>
        createRoute({
          getParentRoute: () => bodyRoute,
          path: normalizeConsoleSlotPath(route.path),
          staticData: { consoleSlot: route },
          component: () => (
            <SlotGate slot={route}>
              {enabled =>
                enabled ? (
                  <SlotBoundary variant="panel" resetKeys={[route.id]}>
                    <route.Component />
                  </SlotBoundary>
                ) : (
                  <NotFoundPage />
                )
              }
            </SlotGate>
          )
        })
      ),
      createRoute({ getParentRoute: () => bodyRoute, path: '$', component: NotFoundPage })
    ])
  ])

  return createRouter({
    routeTree,
    basepath: basename,
    defaultPendingMinMs: 0,
    parseSearch: parseRouterSearch,
    stringifySearch: stringifyRouterSearch
  })
}

export function ConsoleApp({
  router,
  slots = {}
}: {
  router: ReturnType<typeof createConsoleRouter>
  slots?: ConsoleAppSlots
}) {
  validateConsoleSlots(slots)
  return (
    <ConsoleSlotsContext value={slots}>
      <RouterProvider router={router} />
    </ConsoleSlotsContext>
  )
}
