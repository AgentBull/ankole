import '@ankole/uikit/styles.css'
import '../common/styles.css'
import { createRoot } from 'react-dom/client'
import { createBrowserRouter, Link, Outlet, RouterProvider, useParams } from 'react-router'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { SetupApp } from '../setup/app'
import { LocalPasswordForm } from '../auth/local-password-form'
import { LoginModel } from '../auth/state/login-model'
import { AppProviders, createQueryClient } from '../common/providers'
import { loadLocale } from '../common/i18n'
import { configureConsoleAPIClient } from '../console/api/client'
import { createConsoleMutationCache } from '../console/query-client'
import { ProviderEditorPage, ProvidersListPage } from '../console/pages/providers'
import { HomePage } from '../console/pages/home'
import { BrainObjectEditorPage } from '../console/pages/brain/object-editor'
import { BrainObjectDrawer, BrainObjectsPage } from '../console/pages/brain/objects'
import { SettingsPage, SettingEditorDrawer, SettingGroupDrawer } from '../console/pages/settings'
import { WorkerProviderEditorPage } from '../console/pages/worker-providers'
import { TenantEditorPage } from '../console/pages/tenants'
import { WebhooksPage } from '../console/pages/webhooks'
import { AgentFilesPage } from '../console/pages/agent-files'
import { ScheduleCronEditorPage, SchedulesListPage } from '../console/pages/schedules'
import { AgentLibraryEditor } from '../console/pages/agent-library-editor'
import { AgentLibraryEditorModel } from '../console/state/agent-library-editor-model'
import { WorkerEnvAgentSection } from '../console/pages/worker-env-agent-section'

await loadLocale('en-US')
const setupSurface = window.location.pathname.startsWith('/setup-repair')
const loginSurface = window.location.pathname.startsWith('/login-repair')
const provider = window.location.pathname.startsWith('/providers')
const home = window.location.pathname.startsWith('/console-home')
const brain = window.location.pathname.startsWith('/brain')
const consoleSurface =
  provider ||
  home ||
  brain ||
  /^\/(settings|tenants|webhooks|files|schedules|library|worker-env|worker-providers)(\/|$)/.test(
    window.location.pathname
  )
const client = createQueryClient(consoleSurface ? createConsoleMutationCache() : undefined)
Object.assign(window, {
  testMutationStatuses: () =>
    client
      .getMutationCache()
      .getAll()
      .map(row => row.state.status)
})
const PodApp = consoleSurface || setupSurface || loginSurface ? undefined : (await import('../pod/app')).PodApp
const app = setupSurface ? (
  <SetupApp />
) : loginSurface ? (
  <LoginTestPage />
) : consoleSurface ? (
  (() => {
    configureConsoleAPIClient()
    return (
      <RouterProvider
        router={createBrowserRouter([
          {
            element: <RegressionNavigation />,
            children: [
              {
                path: '/settings',
                element: <SettingsPage />,
                children: [
                  { path: 'group/:group', element: <SettingGroupDrawer /> },
                  { path: ':key', element: <SettingEditorDrawer /> }
                ]
              },
              { path: '/tenants/new', element: <TenantEditorPage /> },
              { path: '/tenants/:tenantID', element: <TenantEditorPage /> },
              { path: '/worker-providers/:providerID', element: <WorkerProviderEditorPage /> },
              { path: '/webhooks', element: <WebhooksPage /> },
              { path: '/files/:uid', element: <AgentFilesPage /> },
              { path: '/schedules', element: <SchedulesListPage /> },
              { path: '/schedules/new', element: <ScheduleCronEditorPage /> },
              { path: '/library/:uid', element: <LibraryTestPage /> },
              { path: '/worker-env', element: <WorkerEnvAgentSection agentUID="agent-one" /> }
            ]
          },
          { path: '/console-home', element: <HomePage /> },
          { path: '/providers', element: <ProvidersListPage /> },
          { path: '/providers/new', element: <ProviderEditorPage /> },
          { path: '/providers/:providerID', element: <ProviderEditorPage /> },
          {
            element: <BrainTestNavigation />,
            children: [
              { path: '/brain/objects/new', element: <BrainObjectEditorPage /> },
              { path: '/brain/objects/:slug/edit', element: <BrainObjectEditorPage /> },
              {
                path: '/brain/objects',
                element: <BrainObjectsPage />,
                children: [{ path: '*', element: <BrainObjectDrawer /> }]
              }
            ]
          }
        ])}
      />
    )
  })()
) : PodApp ? (
  <PodApp />
) : null
createRoot(document.getElementById('root')!).render(<AppProviders queryClient={client}>{app}</AppProviders>)

function RegressionNavigation() {
  return (
    <>
      <nav aria-label="Regression navigation">
        <Link to="/settings">Settings</Link>
        <Link to="/library/agent-one">Library</Link>
        <Link to="/schedules/new?agent=agent-one&amp;cron=cron-one">Schedule</Link>
      </nav>
      <Outlet />
    </>
  )
}

function LibraryTestPage() {
  useSignals()
  const model = useModel(AgentLibraryEditorModel)
  return <AgentLibraryEditor agentUID={useParams().uid!} model={model} />
}

// Test-only links change router parameters without replacing the application or its QueryClient.
function BrainTestNavigation() {
  return (
    <>
      <nav aria-label="Browser test navigation">
        <Link to="/brain/objects/A/edit">Edit A</Link>
        <Link to="/brain/objects/B/edit">Edit B</Link>
        <Link to="/brain/objects/new">New object</Link>
        <Link to="/brain/objects">Object list</Link>
      </nav>
      <Outlet />
    </>
  )
}

function LoginTestPage() {
  const model = useModel(LoginModel)
  return <LocalPasswordForm model={model} />
}
