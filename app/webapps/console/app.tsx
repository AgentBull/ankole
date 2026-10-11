import type { QueryClient } from '@tanstack/react-query'
import { createBrowserRouter, Navigate, RouterProvider, type RouteObject } from 'react-router'
import { configureConsoleAPIClient } from './api/client'
import { applyDataTenantNavigation } from './api/data-context'
import { createConsoleRouteLoaders } from './console-route-loaders'
import { ConsoleLayout } from './console-shell-chrome'
import { AgentEditorPage, AgentsListPage } from './pages/agents'
import { AgentFilesPage } from './pages/agent-files'
import { IdentityProviderEditorPage, IdentityProvidersListPage } from './pages/identity'
import { IdentityMappingCreatePage, IdentityMappingsPage } from './pages/identity-mappings'
import { ProviderEditorPage, ProvidersListPage } from './pages/providers'
import { SettingEditorDrawer, SettingGroupDrawer, SettingsPage } from './pages/settings'
import { SignalBindingEditorPage, SignalsListPage } from './pages/signals'
import { ScheduleCheckbacksPage, ScheduleCronEditorPage, SchedulesListPage } from './pages/schedules'
import { WebhooksPage } from './pages/webhooks'
import { AutomationJobsPage } from './pages/automation-jobs'
import { WorkerEnvEditorPage, WorkerEnvsListPage } from './pages/worker-envs'
import { WorkersListPage } from './pages/workers'
import { WorkerProviderEditorPage, WorkerProvidersListPage } from './pages/worker-providers'
import { BackgroundAgentJobsPage } from './pages/background-agent-jobs'
import { ConversationDetailPage, ConversationsListPage } from './pages/conversations'
import { AgentLibraryPage, AgentPluginDetailPage } from './pages/agent-library'
import { BrainObjectDrawer, BrainObjectsPage } from './pages/brain/objects'
import { BrainObjectEditorPage } from './pages/brain/object-editor'
import { BrainClaimsPage } from './pages/brain/claims'
import { BrainContradictionsPage } from './pages/brain/contradictions'
import { BrainMergeSuggestionsPage } from './pages/brain/merge-suggestions'
import { BrainSourcesPage } from './pages/brain/sources'
import { BrainSuggestionsPage } from './pages/brain/suggestions'
import { BrainSearchPreviewPage } from './pages/brain/search-preview'
import { BrainPrincipalAuditPage } from './pages/brain/principal-audit'
import { BrainHealthPage } from './pages/brain/health'
import { PrincipalGroupEditorPage, PrincipalGroupsListPage } from './pages/principal-groups'
import { PrincipalCreatePage } from './pages/principal-create'
import { PrincipalEditPage } from './pages/principal-edit'
import { PrincipalDetailPage, PrincipalsListPage } from './pages/principals'
import { PermissionGrantEditorPage } from './pages/permission-grant-editor'
import { OIDCClientEditorPage, OIDCClientsListPage } from './pages/oidc-clients'
import { HomePage, NotFoundPage, RouteErrorPage } from './pages/home'
import { TenantsListPage, TenantEditorPage } from './pages/tenants'

// Set the session and CSRF configuration before route components start queries.
configureConsoleAPIClient()

const shouldPreloadRoute: NonNullable<RouteObject['shouldRevalidate']> = ({ currentUrl, nextUrl }) =>
  currentUrl.pathname !== nextUrl.pathname

function preloadRoute(loader: RouteObject['loader']) {
  return { loader, shouldRevalidate: shouldPreloadRoute }
}

// The authenticated Phoenix shell supplies the runtime mount for client-side
// routing. Each resource is a list route plus its editor
// routes. Settings are the exception: the key route is nested so its editor can
// stay deep-linkable while opening as a drawer over the list.
export function createConsoleRouter(queryClient: QueryClient) {
  applyDataTenantNavigation()
  const basename = document.querySelector<HTMLMetaElement>('meta[name="ankole-site-admin-console-path"]')?.content
  if (!basename) throw new Error('The authenticated console shell did not provide its mount path')
  const loaders = createConsoleRouteLoaders(queryClient)

  return createBrowserRouter(
    [
      {
        path: '/',
        element: <ConsoleLayout />,
        // Without this the router shows its own built-in screen when the shell
        // throws: a stack trace with no navigation and no way back in.
        errorElement: <RouteErrorPage />,
        children: [
          {
            // Page and loader errors stay inside the persistent Console shell.
            errorElement: <RouteErrorPage />,
            children: [
              { index: true, element: <HomePage />, ...preloadRoute(loaders.home) },
              { path: 'agents', element: <AgentsListPage />, ...preloadRoute(loaders.agents) },
              { path: 'tenants', element: <TenantsListPage /> },
              { path: 'tenants/new', element: <TenantEditorPage /> },
              { path: 'tenants/:tenantID', element: <TenantEditorPage /> },
              { path: 'agents/new', element: <AgentEditorPage /> },
              { path: 'agents/:uid', element: <AgentEditorPage /> },
              { path: 'agents/:uid/files', element: <AgentFilesPage /> },
              { path: 'agent-library', element: <AgentLibraryPage />, ...preloadRoute(loaders.agentLibrary) },
              { path: 'agent-library/agent-plugins/:pluginID', element: <AgentPluginDetailPage /> },
              { path: 'brain', element: <Navigate to="/brain/objects" replace /> },
              { path: 'brain/objects/new', element: <BrainObjectEditorPage /> },
              { path: 'brain/objects/:slug/edit', element: <BrainObjectEditorPage /> },
              {
                path: 'brain/objects',
                element: <BrainObjectsPage />,
                children: [{ path: '*', element: <BrainObjectDrawer /> }]
              },
              { path: 'brain/claims', element: <BrainClaimsPage /> },
              { path: 'brain/contradictions', element: <BrainContradictionsPage /> },
              { path: 'brain/merge-suggestions', element: <BrainMergeSuggestionsPage /> },
              { path: 'brain/sources', element: <BrainSourcesPage /> },
              { path: 'brain/suggestions', element: <BrainSuggestionsPage /> },
              { path: 'brain/search-preview', element: <BrainSearchPreviewPage /> },
              { path: 'brain/principal-audit', element: <BrainPrincipalAuditPage /> },
              { path: 'brain/health', element: <BrainHealthPage /> },
              { path: 'providers', element: <ProvidersListPage />, ...preloadRoute(loaders.providers) },
              { path: 'providers/new', element: <ProviderEditorPage /> },
              { path: 'providers/:providerID', element: <ProviderEditorPage /> },
              { path: 'identity', element: <IdentityProvidersListPage />, ...preloadRoute(loaders.identity) },
              { path: 'identity/new', element: <IdentityProviderEditorPage /> },
              {
                path: 'identity/mappings',
                element: <IdentityMappingsPage />,
                ...preloadRoute(loaders.identityMappings)
              },
              { path: 'identity/mappings/new', element: <IdentityMappingCreatePage /> },
              { path: 'identity/:providerID', element: <IdentityProviderEditorPage /> },
              { path: 'oidc-clients', element: <OIDCClientsListPage />, ...preloadRoute(loaders.oidcClients) },
              { path: 'oidc-clients/new', element: <OIDCClientEditorPage /> },
              { path: 'oidc-clients/:clientID', element: <OIDCClientEditorPage /> },
              { path: 'access', element: <Navigate to="/access/groups" replace /> },
              {
                path: 'access/groups',
                element: <PrincipalGroupsListPage />,
                ...preloadRoute(loaders.principalGroups)
              },
              { path: 'access/groups/new', element: <PrincipalGroupEditorPage /> },
              { path: 'access/groups/:name', element: <PrincipalGroupEditorPage /> },
              { path: 'access/groups/:name/grants/new', element: <PermissionGrantEditorPage createFor="group" /> },
              { path: 'access/principals', element: <PrincipalsListPage />, ...preloadRoute(loaders.principals) },
              { path: 'access/principals/new', element: <PrincipalCreatePage /> },
              { path: 'access/principals/:uid', element: <PrincipalDetailPage /> },
              { path: 'access/principals/:uid/edit', element: <PrincipalEditPage /> },
              {
                path: 'access/principals/:uid/grants/new',
                element: <PermissionGrantEditorPage createFor="principal" />
              },
              { path: 'access/grants/:grantID', element: <PermissionGrantEditorPage /> },
              { path: 'signals', element: <SignalsListPage />, ...preloadRoute(loaders.signals) },
              { path: 'signals/new', element: <SignalBindingEditorPage /> },
              { path: 'schedules', element: <SchedulesListPage />, ...preloadRoute(loaders.schedules) },
              {
                path: 'schedules/checkbacks',
                element: <ScheduleCheckbacksPage />,
                ...preloadRoute(loaders.scheduleCheckbacks)
              },
              { path: 'schedules/new', element: <ScheduleCronEditorPage /> },
              { path: 'webhooks', element: <WebhooksPage />, ...preloadRoute(loaders.webhooks) },
              {
                path: 'automation-jobs',
                element: <AutomationJobsPage />,
                ...preloadRoute(loaders.automationJobs)
              },
              {
                path: 'settings',
                element: <SettingsPage />,
                ...preloadRoute(loaders.settings),
                children: [
                  { path: 'group/:group', element: <SettingGroupDrawer /> },
                  { path: ':key', element: <SettingEditorDrawer /> }
                ]
              },
              { path: 'settings/worker-providers', element: <WorkerProvidersListPage /> },
              { path: 'settings/worker-providers/new', element: <WorkerProviderEditorPage /> },
              { path: 'settings/worker-providers/:providerID', element: <WorkerProviderEditorPage /> },
              { path: 'worker-envs', element: <WorkerEnvsListPage />, ...preloadRoute(loaders.workerEnvs) },
              { path: 'worker-envs/new', element: <WorkerEnvEditorPage /> },
              { path: 'worker-envs/:name', element: <WorkerEnvEditorPage /> },
              { path: 'workers', element: <WorkersListPage />, ...preloadRoute(loaders.workers) },
              {
                path: 'background-agent-jobs',
                element: <BackgroundAgentJobsPage />,
                ...preloadRoute(loaders.backgroundAgentJobs)
              },
              {
                path: 'conversations',
                element: <ConversationsListPage />,
                ...preloadRoute(loaders.conversations)
              },
              { path: 'conversations/:conversationID', element: <ConversationDetailPage /> },
              { path: '*', element: <NotFoundPage /> }
            ]
          }
        ]
      }
    ],
    { basename }
  )
}

export function ConsoleApp({ router }: { router: ReturnType<typeof createConsoleRouter> }) {
  return <RouterProvider router={router} />
}
