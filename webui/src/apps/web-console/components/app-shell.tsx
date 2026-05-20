import { Outlet, useMatchRoute } from "@tanstack/react-router"
import { useEffect } from "react"
import { SidebarInset, SidebarProvider, SidebarTrigger } from "@/uikit/components/sidebar"
import { TooltipProvider } from "@/uikit/components/tooltip"
import { AppSidebar } from "./app-sidebar"
import { Breadcrumb } from "./breadcrumb"
import { findNavItem, humanizeSlug } from "./nav"

export function AppShell() {
  return (
    <TooltipProvider delay={0}>
      <SidebarProvider defaultOpen={readSidebarCookie()}>
        <AppSidebar />
        <SidebarInset>
          <Header />
          <div className="flex flex-1 flex-col gap-6 p-4 md:p-6">
            <Outlet />
          </div>
        </SidebarInset>
      </SidebarProvider>
    </TooltipProvider>
  )
}

function Header() {
  const title = useActiveTitle()

  useEffect(() => {
    document.title = `${title} · BullX Console`
  }, [title])

  return (
    <header className="flex h-14 shrink-0 items-center gap-2 border-b border-sidebar-border px-4">
      <SidebarTrigger className="-ml-1" />
      <div className="mr-1 h-4 w-px shrink-0 bg-border" />
      <Breadcrumb items={["BullX Console", title]} />
    </header>
  )
}

function useActiveTitle(): string {
  const matchRoute = useMatchRoute()

  if (matchRoute({ to: "/", fuzzy: false })) {
    return "Overview"
  }

  if (matchRoute({ to: "/channels", fuzzy: true })) {
    return "Channels"
  }

  const params = matchRoute({ to: "/$section" })
  if (params) {
    return findNavItem(params.section)?.title ?? humanizeSlug(params.section)
  }

  return "Console"
}

function readSidebarCookie(): boolean {
  const match = document.cookie.match(/(?:^|;\s*)sidebar_state=(true|false)/)
  return match ? match[1] === "true" : true
}
