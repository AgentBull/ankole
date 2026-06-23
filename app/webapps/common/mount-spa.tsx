import { StrictMode } from 'react'
import type { ReactNode } from 'react'
import { createRoot } from 'react-dom/client'
import { AppProviders, createQueryClient } from './providers'
import type { SpaDescriptor } from './placeholder-app'
import '@ankole/uikit/styles.css'
import './styles.css'

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
  const container = document.getElementById('ankole-app')
  // A missing container means the route did not come from the Phoenix shell.
  // Returning quietly keeps tests and story-like embeds from crashing.
  if (!container) return

  const queryClient = createQueryClient()

  createRoot(container).render(
    <StrictMode>
      <AppProviders queryClient={queryClient}>{children}</AppProviders>
    </StrictMode>
  )
}
