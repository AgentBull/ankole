import { SidebarInset, SidebarProvider, SidebarTrigger, TooltipProvider, cn, useSidebar } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import { createBrowserRouter, Outlet, RouterProvider } from 'react-router'
import { WorkplaceSidebar } from './sidebar'
import { ChatRoute } from './chat-page'

// AnkoleWeb.Router serves this SPA at /workplace.
const router = createBrowserRouter(
  [
    {
      element: <WorkplaceShell />,
      children: [
        { index: true, element: <ChatRoute /> },
        { path: 'conversations/:conversationID', element: <ChatRoute /> }
      ]
    }
  ],
  { basename: '/workplace' }
)

export function WorkplaceApp() {
  return <RouterProvider router={router} />
}

function WorkplaceShell() {
  return (
    <TooltipProvider>
      <SidebarProvider className="h-svh overflow-hidden">
        <WorkplaceSidebar />
        <SidebarInset className="min-h-0 overflow-hidden">
          <WorkplaceTopBar />
          <div className="min-h-0 flex-1 overflow-hidden">
            <Outlet />
          </div>
        </SidebarInset>
      </SidebarProvider>
    </TooltipProvider>
  )
}

function WorkplaceTopBar() {
  const { t } = useTranslation()
  const { state } = useSidebar()

  return (
    <header className="flex h-12 shrink-0 items-center px-3 md:px-5">
      {/* Below md the sidebar is a sheet, so the toggle stays visible there. */}
      <SidebarTrigger className={cn(state === 'expanded' && 'md:hidden')} label={t('workplace.sidebar.expand')} />
    </header>
  )
}
