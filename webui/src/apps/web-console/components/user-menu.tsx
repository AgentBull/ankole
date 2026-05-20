import { RiExpandUpDownLine, RiLogoutBoxRLine } from "@remixicon/react"
import { Avatar, AvatarFallback, AvatarImage } from "@/uikit/components/avatar"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/uikit/components/dropdown-menu"
import { SidebarMenu, SidebarMenuButton, SidebarMenuItem, useSidebar } from "@/uikit/components/sidebar"
import { Skeleton } from "@/uikit/components/skeleton"
import { csrfToken } from "../lib/api"
import { principalDisplayName, principalInitials, useSession } from "../lib/session"

export function UserMenu() {
  const { isMobile } = useSidebar()
  const { data: principal, isPending } = useSession()

  if (isPending) {
    return (
      <SidebarMenu>
        <SidebarMenuItem>
          <div className="flex h-12 items-center gap-2 px-3">
            <Skeleton className="size-8 shrink-0" />
            <div className="flex flex-1 flex-col gap-1.5">
              <Skeleton className="h-3.5 w-24" />
              <Skeleton className="h-3 w-16" />
            </div>
          </div>
        </SidebarMenuItem>
      </SidebarMenu>
    )
  }

  const name = principalDisplayName(principal)
  const initials = principalInitials(principal)

  return (
    <SidebarMenu>
      <SidebarMenuItem>
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <SidebarMenuButton
                size="lg"
                className="aria-expanded:bg-sidebar-accent aria-expanded:text-sidebar-accent-foreground">
                <Avatar className="size-8 rounded-none">
                  {principal?.avatar_url ? <AvatarImage src={principal.avatar_url} alt={name} /> : null}
                  <AvatarFallback className="rounded-none bg-sidebar-accent text-xs text-sidebar-accent-foreground">
                    {initials}
                  </AvatarFallback>
                </Avatar>
                <span className="grid flex-1 text-left leading-tight">
                  <span className="truncate text-sm font-medium">{name}</span>
                  <span className="truncate text-xs text-sidebar-foreground/70">{principal?.uid}</span>
                </span>
                <RiExpandUpDownLine className="ml-auto size-4 text-sidebar-foreground/70" />
              </SidebarMenuButton>
            }
          />
          <DropdownMenuContent side={isMobile ? "bottom" : "right"} align="end" sideOffset={8} className="min-w-56">
            <DropdownMenuLabel className="font-normal">
              <div className="grid gap-0.5 leading-tight">
                <span className="truncate text-sm font-medium">{name}</span>
                <span className="truncate text-xs text-muted-foreground">{principal?.uid}</span>
              </div>
            </DropdownMenuLabel>
            <DropdownMenuSeparator />
            <DropdownMenuItem onClick={signOut}>
              <RiLogoutBoxRLine />
              Sign out
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </SidebarMenuItem>
    </SidebarMenu>
  )
}

function signOut() {
  const form = document.createElement("form")
  form.method = "POST"
  form.action = "/sessions"
  form.style.display = "none"

  appendHidden(form, "_method", "delete")
  appendHidden(form, "_csrf_token", csrfToken())

  document.body.appendChild(form)
  form.submit()
}

function appendHidden(form: HTMLFormElement, name: string, value: string) {
  const input = document.createElement("input")
  input.type = "hidden"
  input.name = name
  input.value = value
  form.appendChild(input)
}
