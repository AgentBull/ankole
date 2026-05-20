import {
  RiBroadcastLine,
  RiChat3Line,
  RiDashboardLine,
  RiGitForkLine,
  RiPlugLine,
  RiRobot2Line,
  RiSettings3Line,
  RiSparkling2Line,
} from "@remixicon/react"
import type { ComponentType } from "react"

export type NavItem = {
  title: string
  slug: string
  description: string
  icon: ComponentType<{ className?: string }>
}

export type NavGroup = {
  label: string
  items: NavItem[]
}

export const NAV_GROUPS: NavGroup[] = [
  {
    label: "Platform",
    items: [
      {
        title: "Overview",
        slug: "",
        description: "Snapshot of your workspace and quick links.",
        icon: RiDashboardLine,
      },
      {
        title: "Conversations",
        slug: "conversations",
        description: "Threads humans and agents share across channels.",
        icon: RiChat3Line,
      },
      {
        title: "Agents",
        slug: "agents",
        description: "AI principals, their profiles, and toolsets.",
        icon: RiRobot2Line,
      },
    ],
  },
  {
    label: "Routing",
    items: [
      {
        title: "Channels",
        slug: "channels",
        description: "Connected sources like Telegram, Discord, and Feishu.",
        icon: RiBroadcastLine,
      },
      {
        title: "Event Routing",
        slug: "event-routing",
        description: "Rules that turn inbound events into agent work.",
        icon: RiGitForkLine,
      },
      {
        title: "LLM Providers",
        slug: "llm-providers",
        description: "Model backends and credentials agents draw on.",
        icon: RiSparkling2Line,
      },
    ],
  },
  {
    label: "Workspace",
    items: [
      {
        title: "Plugins",
        slug: "plugins",
        description: "Adapters and extensions installed in this instance.",
        icon: RiPlugLine,
      },
      {
        title: "Settings",
        slug: "settings",
        description: "Workspace configuration and access control.",
        icon: RiSettings3Line,
      },
    ],
  },
]

export const NAV_ITEMS: NavItem[] = NAV_GROUPS.flatMap(group => group.items)

export function navItemPath(slug: string): string {
  return slug === "" ? "/" : `/${slug}`
}

export function findNavItem(slug: string): NavItem | undefined {
  return NAV_ITEMS.find(item => item.slug === slug)
}

export function humanizeSlug(slug: string): string {
  return (
    slug
      .split(/[-_/]/)
      .filter(Boolean)
      .map(part => part.charAt(0).toUpperCase() + part.slice(1))
      .join(" ") || "Console"
  )
}
