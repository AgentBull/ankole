import type { QueryClient } from '@tanstack/react-query'
import { createBrowserRouter, Navigate, RouterProvider, type RouteObject } from 'react-router'
import { configureConsoleAPIClient } from './api/tokens'
import { createConsoleRouteLoaders } from './console-route-loaders'
import { ConsoleLayout } from './console-shell-chrome'
import { AgentEditorPage, AgentsListPage } from './pages/agents'
import { IdentityProviderEditorPage, IdentityProvidersListPage } from './pages/identity'
import { IdentityMappingCreatePage, IdentityMappingsPage } from './pages/identity-mappings'
import { ProviderEditorPage, ProvidersListPage } from './pages/providers'
import { SettingEditorDrawer, SettingGroupDrawer, SettingsPage } from './pages/settings'
import { SignalBindingEditorPage, SignalsListPage } from './pages/signals'
import { ScheduleCheckbacksPage, ScheduleCronEditorPage, SchedulesListPage } from './pages/schedules'
import { WebhooksPage } from './pages/webhooks'
import { AutomationJobsPage } from './pages/automation-jobs'
import { WorkerEnvEditorPage, WorkerEnvsListPage } from './pages/worker-envs'
import { WorkerFilesPage, WorkersListPage } from './pages/workers'
import { BackgroundAgentJobsPage } from './pages/background-agent-jobs'
import { ConversationDetailPage, ConversationsListPage } from './pages/conversations'
import { AgentLibraryPage, AgentPluginDetailPage } from './pages/agent-library'
import { BrainObjectDrawer, BrainObjectsPage } from './pages/brain/objects'
import { BrainClaimsPage } from './pages/brain/claims'
import { BrainContradictionsPage } from './pages/brain/contradictions'
import { BrainSuggestionsPage } from './pages/brain/suggestions'
import { BrainMergeSuggestionsPage } from './pages/brain/merge-suggestions'
import { BrainSourcesPage } from './pages/brain/sources'
import { BrainSearchPreviewPage } from './pages/brain/search-preview'
import { BrainPrincipalAuditPage } from './pages/brain/principal-audit'
import { BrainHealthPage } from './pages/brain/health'
import { PrincipalGroupEditorPage, PrincipalGroupsListPage } from './pages/principal-groups'
import { PrincipalCreatePage } from './pages/principal-create'
import { PrincipalEditPage } from './pages/principal-edit'
import { PrincipalDetailPage, PrincipalsListPage } from './pages/principals'
import { PermissionGrantEditorPage } from './pages/permission-grant-editor'
import { HomePage, NotFoundPage, RouteErrorPage } from './pages/home'

// Configure the bearer-token API client at module load, before any route
// component can render or fire a query. This must run eagerly and NOT inside a
// `useMemo`/effect: it is a side effect, and the React Compiler may drop or
// defer a memo whose result is unused — which would let the first `/api/v1`
// requests go out with no Authorization header ("bearer token required").
configureConsoleAPIClient()

const shouldPreloadRoute: NonNullable<RouteObject['shouldRevalidate']> = ({ currentUrl, nextUrl }) =>
  currentUrl.pathname !== nextUrl.pathname

function preloadRoute(loader: RouteObject['loader']) {
  return { loader, shouldRevalidate: shouldPreloadRoute }
}

// The Phoenix shell serves the console SPA under `/console/*`, so client-side
// routing is anchored there. Each resource is a list route plus its editor
// routes. Settings are the exception: the key route is nested so its editor can
// stay deep-linkable while opening as a drawer over the list.
export function createConsoleRouter(queryClient: QueryClient) {
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
              { path: 'agents/new', element: <AgentEditorPage /> },
              { path: 'agents/:uid', element: <AgentEditorPage /> },
              { path: 'agent-library', element: <AgentLibraryPage />, ...preloadRoute(loaders.agentLibrary) },
              { path: 'agent-library/agent-plugins/:pluginID', element: <AgentPluginDetailPage /> },
              { path: 'brain', element: <Navigate to="/brain/objects" replace /> },
              {
                path: 'brain/objects',
                element: <BrainObjectsPage />,
                children: [{ path: '*', element: <BrainObjectDrawer /> }]
              },
              { path: 'brain/claims', element: <BrainClaimsPage /> },
              { path: 'brain/contradictions', element: <BrainContradictionsPage /> },
              { path: 'brain/suggestions', element: <BrainSuggestionsPage /> },
              { path: 'brain/merge-suggestions', element: <BrainMergeSuggestionsPage /> },
              { path: 'brain/sources', element: <BrainSourcesPage /> },
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
              { path: 'worker-envs', element: <WorkerEnvsListPage />, ...preloadRoute(loaders.workerEnvs) },
              { path: 'worker-envs/new', element: <WorkerEnvEditorPage /> },
              { path: 'worker-envs/:name', element: <WorkerEnvEditorPage /> },
              { path: 'workers', element: <WorkersListPage />, ...preloadRoute(loaders.workers) },
              { path: 'workers/:workerID/files', element: <WorkerFilesPage /> },
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
    { basename: '/console' }
  )
}

export function ConsoleApp({ router }: { router: ReturnType<typeof createConsoleRouter> }) {
  return <RouterProvider router={router} />
}
