import { createBrowserRouter, Navigate, RouterProvider } from 'react-router'
import { configureConsoleAPIClient } from './api/tokens'
import { ConsoleLayout } from './console-shell'
import { AgentEditorPage, AgentsListPage } from './pages/agents'
import { IdentityProviderEditorPage, IdentityProvidersListPage } from './pages/identity'
import { CodexAccountEditorPage, ProviderEditorPage, ProvidersListPage } from './pages/providers'
import { SettingEditorPage, SettingsListPage } from './pages/settings'
import { SignalBindingEditorPage, SignalsListPage } from './pages/signals'
import { ScheduleCronEditorPage, SchedulesListPage } from './pages/schedules'
import { WorkerEnvEditorPage, WorkerEnvsListPage } from './pages/worker-envs'
import { WorkerFilesPage, WorkersListPage } from './pages/workers'
import { BackgroundAgentJobsPage } from './pages/background-agent-jobs'
import { ConversationDetailPage, ConversationsListPage } from './pages/conversations'
import {
  BrainAuditPage,
  BrainDreamingPage,
  BrainEntriesPage,
  BrainEntryAuditPage,
  BrainEntryCreatePage,
  BrainEntryEditorPage
} from './pages/brain'
import { BrainReviewPage } from './pages/brain-review'
import { BrainSourceLearnPage, BrainSourcePage, BrainSourcesPage } from './pages/brain-sources'
import { AgentLibraryPage, AgentPluginDetailPage } from './pages/agent-library'
import { PrincipalGroupEditorPage, PrincipalGroupsListPage } from './pages/principal-groups'
import { PrincipalDetailPage, PrincipalsListPage } from './pages/principals'
import { PermissionGrantEditorPage } from './pages/permission-grant-editor'

// Configure the bearer-token API client at module load, before any route
// component can render or fire a query. This must run eagerly and NOT inside a
// `useMemo`/effect: it is a side effect, and the React Compiler may drop or
// defer a memo whose result is unused — which would let the first `/api/v1`
// requests go out with no Authorization header ("bearer token required").
configureConsoleAPIClient()

// The Phoenix shell serves the console SPA under `/console/*`, so client-side
// routing is anchored there. Each resource is a list route plus its editor
// routes; creating and editing happen on their own pages, never docked beside
// the list.
const router = createBrowserRouter(
  [
    {
      path: '/',
      element: <ConsoleLayout />,
      children: [
        { index: true, element: <Navigate to="/agents" replace /> },
        { path: 'agents', element: <AgentsListPage /> },
        { path: 'agents/new', element: <AgentEditorPage /> },
        { path: 'agents/:uid', element: <AgentEditorPage /> },
        { path: 'agent-library', element: <AgentLibraryPage /> },
        { path: 'agent-library/agent-plugins/:pluginID', element: <AgentPluginDetailPage /> },
        { path: 'providers', element: <ProvidersListPage /> },
        { path: 'providers/codex/new', element: <CodexAccountEditorPage /> },
        { path: 'providers/codex/:accountID', element: <CodexAccountEditorPage /> },
        { path: 'providers/new', element: <ProviderEditorPage /> },
        { path: 'providers/:providerID', element: <ProviderEditorPage /> },
        { path: 'identity', element: <IdentityProvidersListPage /> },
        { path: 'identity/new', element: <IdentityProviderEditorPage /> },
        { path: 'identity/:providerID', element: <IdentityProviderEditorPage /> },
        { path: 'access', element: <Navigate to="/access/groups" replace /> },
        { path: 'access/groups', element: <PrincipalGroupsListPage /> },
        { path: 'access/groups/new', element: <PrincipalGroupEditorPage /> },
        { path: 'access/groups/:name', element: <PrincipalGroupEditorPage /> },
        { path: 'access/groups/:name/grants/new', element: <PermissionGrantEditorPage createFor="group" /> },
        { path: 'access/principals', element: <PrincipalsListPage /> },
        { path: 'access/principals/:uid', element: <PrincipalDetailPage /> },
        { path: 'access/principals/:uid/grants/new', element: <PermissionGrantEditorPage createFor="principal" /> },
        { path: 'access/grants/:grantID', element: <PermissionGrantEditorPage /> },
        { path: 'signals', element: <SignalsListPage /> },
        { path: 'signals/new', element: <SignalBindingEditorPage /> },
        { path: 'schedules', element: <SchedulesListPage /> },
        { path: 'schedules/new', element: <ScheduleCronEditorPage /> },
        { path: 'settings', element: <SettingsListPage /> },
        { path: 'settings/:key', element: <SettingEditorPage /> },
        { path: 'worker-envs', element: <WorkerEnvsListPage /> },
        { path: 'worker-envs/new', element: <WorkerEnvEditorPage /> },
        { path: 'worker-envs/:name', element: <WorkerEnvEditorPage /> },
        { path: 'workers', element: <WorkersListPage /> },
        { path: 'workers/:workerID/files', element: <WorkerFilesPage /> },
        { path: 'background-agent-jobs', element: <BackgroundAgentJobsPage /> },
        { path: 'conversations', element: <ConversationsListPage /> },
        { path: 'conversations/:conversationID', element: <ConversationDetailPage /> },
        { path: 'brain', element: <BrainEntriesPage /> },
        { path: 'brain/new', element: <BrainEntryCreatePage /> },
        { path: 'brain/sources', element: <BrainSourcesPage /> },
        { path: 'brain/learn', element: <BrainSourceLearnPage /> },
        { path: 'brain/sources/:documentID', element: <BrainSourcePage /> },
        { path: 'brain/review', element: <BrainReviewPage /> },
        { path: 'brain/audit', element: <BrainAuditPage /> },
        { path: 'brain/dreaming', element: <BrainDreamingPage /> },
        { path: 'brain/audit/:id', element: <BrainEntryAuditPage /> },
        { path: 'brain/:id', element: <BrainEntryEditorPage /> },
        { path: '*', element: <Navigate to="/agents" replace /> }
      ]
    }
  ],
  { basename: '/console' }
)

export function ConsoleApp() {
  return <RouterProvider router={router} />
}
