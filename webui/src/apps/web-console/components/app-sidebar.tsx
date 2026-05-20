import { RiSearchLine } from "@remixicon/react"
import { Link, useMatchRoute } from "@tanstack/react-router"
import { useMemo, useState } from "react"
import logoDark from "@/assets/logo-dark.svg"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInput,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarRail,
} from "@/uikit/components/sidebar"
import type { NavGroup } from "./nav"
import { NAV_GROUPS } from "./nav"
import { UserMenu } from "./user-menu"

export function AppSidebar() {
  const [query, setQuery] = useState("")
  const groups = useMemo(() => filterGroups(NAV_GROUPS, query), [query])

  return (
    <Sidebar variant="floating">
      <SidebarHeader className="gap-2">
        <Brand />
        <SearchBox value={query} onChange={setQuery} />
      </SidebarHeader>
      <SidebarContent>
        {groups.map(group => (
          <SidebarGroup key={group.label}>
            <SidebarGroupLabel>{group.label}</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {group.items.map(item => (
                  <NavMenuItem key={item.slug || "overview"} item={item} />
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        ))}
        {groups.length === 0 ? (
          <p className="px-5 py-2 text-sm text-sidebar-foreground/60">No matches for “{query}”.</p>
        ) : null}
      </SidebarContent>
      <SidebarFooter>
        <UserMenu />
      </SidebarFooter>
      <SidebarRail />
    </Sidebar>
  )
}

function NavMenuItem({ item }: { item: NavGroup["items"][number] }) {
  const matchRoute = useMatchRoute()
  const slug = item.slug

  const isActive =
    slug === ""
      ? Boolean(matchRoute({ to: "/", fuzzy: false }))
      : slug === "channels"
        ? Boolean(matchRoute({ to: "/channels", fuzzy: true }))
        : Boolean(matchRoute({ to: "/$section", params: { section: slug } }))

  const link =
    slug === "" ? (
      <Link to="/" />
    ) : slug === "channels" ? (
      <Link to="/channels" />
    ) : (
      <Link to="/$section" params={{ section: slug }} />
    )

  return (
    <SidebarMenuItem>
      <SidebarMenuButton isActive={isActive} render={link}>
        <item.icon />
        <span>{item.title}</span>
      </SidebarMenuButton>
    </SidebarMenuItem>
  )
}

function Brand() {
  return (
    <SidebarMenu>
      <SidebarMenuItem>
        <SidebarMenuButton size="lg" render={<Link to="/" />}>
          <span className="flex size-8 shrink-0 items-center justify-center bg-sidebar-accent">
            <img src={logoDark} alt="BullX" className="size-5" />
          </span>
          <span className="grid flex-1 text-left leading-tight">
            <span className="truncate font-semibold">BullX</span>
            <span className="truncate text-xs text-sidebar-foreground/70">Console</span>
          </span>
        </SidebarMenuButton>
      </SidebarMenuItem>
    </SidebarMenu>
  )
}

function SearchBox({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  return (
    <div className="relative">
      <RiSearchLine className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-sidebar-foreground/50" />
      <SidebarInput
        type="search"
        placeholder="Search…"
        value={value}
        onChange={event => onChange(event.target.value)}
        className="pl-8"
        aria-label="Search navigation"
      />
    </div>
  )
}

function filterGroups(groups: NavGroup[], query: string): NavGroup[] {
  const needle = query.trim().toLowerCase()
  if (needle === "") {
    return groups
  }

  return groups
    .map(group => ({
      ...group,
      items: group.items.filter(item => item.title.toLowerCase().includes(needle)),
    }))
    .filter(group => group.items.length > 0)
}
