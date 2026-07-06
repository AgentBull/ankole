import { StrictMode } from 'react'
import type { ReactNode } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { AppProviders, createQueryClient } from './providers'
import type { SpaDescriptor } from './placeholder-app'
import '@ankole/uikit/styles.css'
import './styles.css'

type AppContainer = HTMLElement & {
  __ankoleQueryClient?: ReturnType<typeof createQueryClient>
  __ankoleRoot?: Root
}

/** Mounts a placeholder SPA descriptor through the shared provider stack. */
export async function mountSpa(descriptor: SpaDescriptor) {
  const [{ RouterProvider }, { createPlaceholderRouter }] = await Promise.all([
    import('react-router'),
    import('./placeholder-app')
  ])
  const router = createPlaceholderRouter(descriptor)
  mountApp(<RouterProvider router={router} />)
}

/** Mounts a React tree into the Phoenix-provided `#ankole-app` container. */
export function mountApp(children: ReactNode) {
  const container = document.getElementById('ankole-app') as AppContainer | null
  // A missing container means the route did not come from the Phoenix shell.
  // Returning quietly keeps tests and story-like embeds from crashing.
  if (!container) return

  const queryClient = container.__ankoleQueryClient ?? createQueryClient()
  const root = container.__ankoleRoot ?? createRoot(container)

  container.__ankoleQueryClient = queryClient
  container.__ankoleRoot = root

  root.render(
    <StrictMode>
      <AppProviders queryClient={queryClient}>{children}</AppProviders>
    </StrictMode>
  )
}
