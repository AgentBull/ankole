import { IdentityProviderEditorPage } from '../console/pages/identity'
import { PrincipalDetailPage } from '../console/pages/principals'
import { OIDCClientEditorPage } from '../console/pages/oidc-clients'
import '@ankole/uikit/styles.css'
import '../common/styles.css'
import { createRoot } from 'react-dom/client'
import {
  createRootRoute,
  createRoute,
  createRouter,
  Link,
  Outlet,
  RouterProvider,
  useParams
} from '@tanstack/react-router'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { SetupApp } from '../setup/app'
import { EmailOtpForm } from '../auth/email-otp-form'
import { AppProviders, createQueryClient } from '../common/providers'
import { loadLocale } from '../common/i18n'
import { parseRouterSearch, stringifyRouterSearch } from '../common/router'
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
import { AgentLibraryPage, AgentPluginDetailPage } from '../console/pages/agent-library'

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
  /^\/(settings|tenants|webhooks|files|schedules|library|agent-library|worker-env|worker-providers|identity|access|oidc-clients)(\/|$)/.test(
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
    const rootRoute = createRootRoute()
    const regressionNavRoute = createRoute({
      getParentRoute: () => rootRoute,
      id: 'regression-nav',
      component: RegressionNavigation
    })
    const settingsRoute = createRoute({
      getParentRoute: () => regressionNavRoute,
      path: '/settings',
      component: SettingsPage
    })
    const brainNavRoute = createRoute({
      getParentRoute: () => rootRoute,
      id: 'brain-nav',
      component: BrainTestNavigation
    })
    const brainObjectsRoute = createRoute({
      getParentRoute: () => brainNavRoute,
      path: '/brain/objects',
      component: BrainObjectsPage
    })
    const routeTree = rootRoute.addChildren([
      createRoute({ getParentRoute: () => rootRoute, path: '/agent-library', component: AgentLibraryPage }),
      createRoute({
        getParentRoute: () => rootRoute,
        path: '/agent-library/agent-plugins/$pluginID',
        component: AgentPluginDetailPage
      }),
      regressionNavRoute.addChildren([
        settingsRoute.addChildren([
          createRoute({ getParentRoute: () => settingsRoute, path: 'group/$group', component: SettingGroupDrawer }),
          createRoute({ getParentRoute: () => settingsRoute, path: '$key', component: SettingEditorDrawer })
        ]),
        createRoute({ getParentRoute: () => regressionNavRoute, path: '/tenants/new', component: TenantEditorPage }),
        createRoute({
          getParentRoute: () => regressionNavRoute,
          path: '/tenants/$tenantID',
          component: TenantEditorPage
        }),
        createRoute({
          getParentRoute: () => regressionNavRoute,
          path: '/worker-providers/$providerID',
          component: WorkerProviderEditorPage
        }),
        createRoute({ getParentRoute: () => regressionNavRoute, path: '/webhooks', component: WebhooksPage }),
        createRoute({ getParentRoute: () => regressionNavRoute, path: '/files/$uid', component: AgentFilesPage }),
        createRoute({ getParentRoute: () => regressionNavRoute, path: '/schedules', component: SchedulesListPage }),
        createRoute({
          getParentRoute: () => regressionNavRoute,
          path: '/schedules/new',
          component: ScheduleCronEditorPage
        }),
        createRoute({
          getParentRoute: () => regressionNavRoute,
          path: '/schedules/$agent/$cronID',
          component: ScheduleCronEditorPage
        }),
        createRoute({ getParentRoute: () => regressionNavRoute, path: '/library/$uid', component: LibraryTestPage }),
        createRoute({
          getParentRoute: () => regressionNavRoute,
          path: '/worker-env',
          component: () => <WorkerEnvAgentSection agentUID="agent-one" />
        })
      ]),
      createRoute({
        getParentRoute: () => rootRoute,
        path: '/identity/$providerID',
        component: IdentityProviderEditorPage
      }),
      createRoute({ getParentRoute: () => rootRoute, path: '/access/principals/$uid', component: PrincipalDetailPage }),
      createRoute({
        getParentRoute: () => rootRoute,
        path: '/oidc-clients/$clientID',
        component: OIDCClientEditorPage
      }),
      createRoute({ getParentRoute: () => rootRoute, path: '/console-home', component: HomePage }),
      createRoute({ getParentRoute: () => rootRoute, path: '/providers', component: ProvidersListPage }),
      createRoute({ getParentRoute: () => rootRoute, path: '/providers/new', component: ProviderEditorPage }),
      createRoute({ getParentRoute: () => rootRoute, path: '/providers/$providerID', component: ProviderEditorPage }),
      brainNavRoute.addChildren([
        createRoute({
          getParentRoute: () => brainNavRoute,
          path: '/brain/objects/new',
          component: BrainObjectEditorPage
        }),
        createRoute({
          getParentRoute: () => brainNavRoute,
          path: '/brain/objects/$slug/edit',
          component: BrainObjectEditorPage
        }),
        brainObjectsRoute.addChildren([
          createRoute({ getParentRoute: () => brainObjectsRoute, path: '/', component: () => null }),
          createRoute({ getParentRoute: () => brainObjectsRoute, path: '$', component: BrainObjectDrawer })
        ])
      ])
    ])
    return (
      <RouterProvider
        router={createRouter({
          routeTree,
          parseSearch: parseRouterSearch,
          stringifySearch: stringifyRouterSearch
        })}
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
        <Link to="/schedules/$agent/$cronID" params={{ agent: 'agent-one', cronID: 'cron-one' }}>
          Schedule
        </Link>
      </nav>
      <Outlet />
    </>
  )
}

function LibraryTestPage() {
  useSignals()
  const model = useModel(AgentLibraryEditorModel)
  return <AgentLibraryEditor agentUID={useParams({ strict: false }).uid!} model={model} />
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
  return <EmailOtpForm />
}
