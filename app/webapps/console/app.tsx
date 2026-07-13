import { createBrowserRouter, Navigate, RouterProvider } from 'react-router'
import { configureConsoleAPIClient } from './api/tokens'
import { ConsoleLayout } from './console-shell'
import { AgentEditorPage, AgentsListPage } from './pages/agents'
import { IdentityProviderEditorPage, IdentityProvidersListPage } from './pages/identity'
import { CodexAccountEditorPage, ProviderEditorPage, ProvidersListPage } from './pages/providers'
import { SettingEditorPage, SettingsListPage } from './pages/settings'
import { SignalBindingEditorPage, SignalsListPage } from './pages/signals'
import { WorkerEnvEditorPage, WorkerEnvsListPage } from './pages/worker-envs'
import { WorkerFilesPage, WorkersListPage } from './pages/workers'
import { DelegationsPage } from './pages/delegations'
import {
  BrainAuditPage,
  BrainEntriesPage,
  BrainEntryAuditPage,
  BrainEntryCreatePage,
  BrainEntryEditorPage,
  BrainSourcePage
} from './pages/brain'

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
        { index: true, element: <Navigate to="agents" replace /> },
        { path: 'agents', element: <AgentsListPage /> },
        { path: 'agents/new', element: <AgentEditorPage /> },
        { path: 'agents/:uid', element: <AgentEditorPage /> },
        { path: 'providers', element: <ProvidersListPage /> },
        { path: 'providers/codex/new', element: <CodexAccountEditorPage /> },
        { path: 'providers/codex/:accountID', element: <CodexAccountEditorPage /> },
        { path: 'providers/new', element: <ProviderEditorPage /> },
        { path: 'providers/:providerID', element: <ProviderEditorPage /> },
        { path: 'identity', element: <IdentityProvidersListPage /> },
        { path: 'identity/new', element: <IdentityProviderEditorPage /> },
        { path: 'identity/:providerID', element: <IdentityProviderEditorPage /> },
        { path: 'signals', element: <SignalsListPage /> },
        { path: 'signals/new', element: <SignalBindingEditorPage /> },
        { path: 'settings', element: <SettingsListPage /> },
        { path: 'settings/:key', element: <SettingEditorPage /> },
        { path: 'worker-envs', element: <WorkerEnvsListPage /> },
        { path: 'worker-envs/new', element: <WorkerEnvEditorPage /> },
        { path: 'worker-envs/:name', element: <WorkerEnvEditorPage /> },
        { path: 'workers', element: <WorkersListPage /> },
        { path: 'workers/:workerID/files', element: <WorkerFilesPage /> },
        { path: 'delegations', element: <DelegationsPage /> },
        { path: 'brain', element: <BrainEntriesPage /> },
        { path: 'brain/new', element: <BrainEntryCreatePage /> },
        { path: 'brain/audit', element: <BrainAuditPage /> },
        { path: 'brain/audit/:id', element: <BrainEntryAuditPage /> },
        { path: 'brain/:id', element: <BrainEntryEditorPage /> },
        { path: 'brain/sources/:documentID', element: <BrainSourcePage /> },
        { path: '*', element: <Navigate to="agents" replace /> }
      ]
    }
  ],
  { basename: '/console' }
)

export function ConsoleApp() {
  return <RouterProvider router={router} />
}
