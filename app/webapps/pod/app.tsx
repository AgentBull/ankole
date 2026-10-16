import { createContext, useContext, useMemo, type ReactNode } from 'react'
import { SidebarInset, SidebarProvider, SidebarTrigger, TooltipProvider, cn, useSidebar } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import { createBrowserRouter, Outlet, RouterProvider } from 'react-router'
import { PodSidebar } from './sidebar'
import { ChatRoute } from './chat-page'

const AccountNavigation = createContext<ReactNode>(null)

type PodAppProps = { basePath?: string; accountNavigation?: ReactNode }

export function PodApp({ basePath = '/pod', accountNavigation }: PodAppProps = {}) {
  const router = useMemo(
    () =>
      createBrowserRouter(
        [
          {
            element: <PodShell />,
            children: [
              { index: true, element: <ChatRoute /> },
              { path: 'conversations/:conversationID', element: <ChatRoute /> }
            ]
          }
        ],
        { basename: basePath }
      ),
    [basePath]
  )
  return (
    <AccountNavigation value={accountNavigation}>
      <RouterProvider router={router} />
    </AccountNavigation>
  )
}

function PodShell() {
  return (
    <TooltipProvider>
      <SidebarProvider className="h-svh overflow-hidden">
        <PodSidebar />
        <SidebarInset className="min-h-0 overflow-hidden">
          <PodTopBar />
          <div className="min-h-0 flex-1 overflow-hidden">
            <Outlet />
          </div>
        </SidebarInset>
      </SidebarProvider>
    </TooltipProvider>
  )
}

function PodTopBar() {
  const accountNavigation = useContext(AccountNavigation)
  const { t } = useTranslation()
  const { state } = useSidebar()

  return (
    <header className="flex h-12 shrink-0 items-center px-3 md:px-5">
      {/* Below md the sidebar is a sheet, so the toggle stays visible there. */}
      <SidebarTrigger className={cn(state === 'expanded' && 'md:hidden')} label={t('pod.sidebar.expand')} />
      <div className="ml-auto">{accountNavigation}</div>
    </header>
  )
}
