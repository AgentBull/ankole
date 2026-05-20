import { RiArrowRightSLine } from "@remixicon/react"
import { Link } from "@tanstack/react-router"
import type { ReactNode } from "react"
import { Badge } from "@/uikit/components/badge"
import { Card, CardContent } from "@/uikit/components/card"
import { Skeleton } from "@/uikit/components/skeleton"
import type { NavItem } from "../components/nav"
import { NAV_ITEMS } from "../components/nav"
import { principalDisplayName, useSession } from "../lib/session"

export function OverviewPage() {
  const { data: principal, isPending } = useSession()
  const launchers = NAV_ITEMS.filter(item => item.slug !== "")

  return (
    <div className="mx-auto flex w-full max-w-6xl flex-col gap-8">
      <header className="flex flex-col gap-1">
        <h1 className="font-heading text-2xl leading-8">Overview</h1>
        <p className="text-sm text-muted-foreground">
          {isPending ? "Loading your workspace…" : `Welcome back, ${principalDisplayName(principal)}.`}
        </p>
      </header>

      <section className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <StatCard label="Identity" loading={isPending}>
          <span className="font-mono text-sm break-all">{principal?.uid ?? "—"}</span>
        </StatCard>
        <StatCard label="Account type" loading={isPending}>
          <Badge variant="secondary" className="capitalize">
            {principal?.type ?? "—"}
          </Badge>
        </StatCard>
        <StatCard label="Status" loading={isPending}>
          <Badge variant={principal?.status === "active" ? "default" : "destructive"} className="capitalize">
            {principal?.status ?? "—"}
          </Badge>
        </StatCard>
      </section>

      <section className="flex flex-col gap-4">
        <h2 className="text-xs font-semibold tracking-wider text-muted-foreground uppercase">Explore the workspace</h2>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {launchers.map(item => (
            <LauncherCard key={item.slug} item={item} />
          ))}
        </div>
      </section>
    </div>
  )
}

function StatCard({ label, loading, children }: { label: string; loading?: boolean; children: ReactNode }) {
  return (
    <Card size="sm">
      <CardContent className="flex flex-col gap-2">
        <span className="text-xs font-medium tracking-wider text-muted-foreground uppercase">{label}</span>
        {loading ? <Skeleton className="h-6 w-28" /> : <div className="flex min-h-6 items-center">{children}</div>}
      </CardContent>
    </Card>
  )
}

function LauncherCard({ item }: { item: NavItem }) {
  return (
    <Link
      to="/$section"
      params={{ section: item.slug }}
      className="group flex flex-col gap-3 border border-border bg-card p-5 transition-colors hover:border-primary/40 hover:bg-muted/40">
      <span className="flex size-9 items-center justify-center bg-muted text-foreground">
        <item.icon className="size-5" />
      </span>
      <span className="flex flex-col gap-1">
        <span className="flex items-center gap-1 font-medium">
          {item.title}
          <RiArrowRightSLine className="size-4 -translate-x-1 opacity-0 transition-all group-hover:translate-x-0 group-hover:opacity-100" />
        </span>
        <span className="text-sm text-muted-foreground">{item.description}</span>
      </span>
    </Link>
  )
}
