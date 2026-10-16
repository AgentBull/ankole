import '@ankole/uikit/styles.css'
import '../common/styles.css'
import { createRoot } from 'react-dom/client'
import { createBrowserRouter, Link, Outlet, RouterProvider } from 'react-router'
import { AppProviders, createQueryClient } from '../common/providers'
import { loadLocale } from '../common/i18n'
import { configureConsoleAPIClient } from '../console/api/client'
import { createConsoleMutationCache } from '../console/query-client'
import { ProviderEditorPage, ProvidersListPage } from '../console/pages/providers'
import { HomePage } from '../console/pages/home'
import { BrainObjectEditorPage } from '../console/pages/brain/object-editor'
import { BrainObjectDrawer, BrainObjectsPage } from '../console/pages/brain/objects'

await loadLocale('en-US')
const provider = window.location.pathname.startsWith('/providers')
const home = window.location.pathname.startsWith('/console-home')
const brain = window.location.pathname.startsWith('/brain')
const consoleSurface = provider || home || brain
const client = createQueryClient(consoleSurface ? createConsoleMutationCache() : undefined)
Object.assign(window, {
  testMutationStatuses: () =>
    client
      .getMutationCache()
      .getAll()
      .map(row => row.state.status)
})
const PodApp = consoleSurface ? undefined : (await import('../pod/app')).PodApp
const app = consoleSurface ? (
  (() => {
    configureConsoleAPIClient()
    return (
      <RouterProvider
        router={createBrowserRouter([
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
