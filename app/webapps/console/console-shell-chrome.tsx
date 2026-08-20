import {
  Button,
  Sheet,
  SheetClose,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
  cn
} from '@ankole/uikit'
import {
  RiBroadcastLine,
  RiChat3Line,
  RiCloseLine,
  RiCodeSSlashLine,
  RiDashboardLine,
  RiGitBranchLine,
  RiKey2Line,
  RiLogoutBoxRLine,
  RiMenuLine,
  RiPuzzle2Line,
  RiRobot2Line,
  RiServerLine,
  RiSettings3Line,
  RiShieldKeyholeLine,
  RiSparkling2Line,
  RiTerminalBoxLine,
  RiTimeLine,
  RiWebhookLine
} from '@remixicon/react'
import { useMutation } from '@tanstack/react-query'
import { useRef, useState, type ComponentType } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, NavLink, Outlet, useLocation } from 'react-router'
import { ThemeToggle } from '../common/theme-toggle'
import { logoutConsoleSession } from './api/tokens'
import { ConsoleReadiness } from './console-readiness'

/**
 * Routed console shell: the header, sidebar navigation, and page outlet every
 * console route renders inside. Each resource page owns its queries, mutations,
 * and body; the list frame lives in `console-list-page` and the editor frame in
 * `console-form`.
 */

type NavItem = {
  to: string
  /** Path prefix that also lights this item, when siblings of `to` share its nav area. */
  match?: string
  label: string
  icon: ComponentType<{ className?: string }>
}

type NavSection = {
  /** Absent for the leading section, which carries the home link alone. */
  label?: string
  items: NavItem[]
}

// One flat list of destinations forced the operator to read every label to find
// one. Each section names the question its group answers: what my agents do,
// what they can do, what they connect to, and how the deployment instance runs. A
// search becomes a scan of four headings.
const NAV_SECTIONS: NavSection[] = [
  { items: [{ to: '/', label: 'console.nav.home', icon: RiDashboardLine }] },
  {
    label: 'console.nav.group_work',
    items: [
      { to: '/agents', label: 'console.nav.agents', icon: RiRobot2Line },
      { to: '/conversations', label: 'console.nav.conversations', icon: RiChat3Line },
      { to: '/background-agent-jobs', label: 'console.nav.background_agent_jobs', icon: RiGitBranchLine },
      { to: '/automation-jobs', label: 'console.nav.automation_jobs', icon: RiCodeSSlashLine },
      { to: '/schedules', label: 'console.nav.schedules', icon: RiTimeLine },
      { to: '/webhooks', label: 'console.nav.webhooks', icon: RiWebhookLine }
    ]
  },
  {
    label: 'console.nav.group_capabilities',
    items: [
      { to: '/agent-library', label: 'console.nav.agent_library', icon: RiPuzzle2Line },
      { to: '/worker-envs', label: 'console.nav.worker_envs', icon: RiTerminalBoxLine }
    ]
  },
  {
    label: 'console.nav.group_connections',
    items: [
      { to: '/providers', label: 'console.nav.providers', icon: RiSparkling2Line },
      { to: '/signals', label: 'console.nav.signals', icon: RiBroadcastLine },
      { to: '/identity', label: 'console.nav.identity', icon: RiShieldKeyholeLine }
    ]
  },
  {
    label: 'console.nav.group_platform',
    items: [
      { to: '/workers', label: 'console.nav.workers', icon: RiServerLine },
      { to: '/access/groups', match: '/access', label: 'console.nav.access', icon: RiKey2Line },
      { to: '/settings', label: 'console.nav.settings', icon: RiSettings3Line }
    ]
  }
]

/** Routed console frame: header, sidebar navigation, and the active page outlet. */
export function ConsoleLayout() {
  const { t } = useTranslation()
  const [navigationOpen, setNavigationOpen] = useState(false)
  const navigationTriggerRef = useRef<HTMLButtonElement>(null)
  const logout = useMutation({
    mutationFn: logoutConsoleSession,
    onSettled: () => window.location.assign('/sessions/new')
  })

  return (
    <TooltipProvider>
      <div className="h-screen overflow-y-scroll bg-background text-foreground [scrollbar-gutter:stable]">
        {/* Reaching the page content by keyboard meant tabbing past the header and
            every navigation link, on every page. The bypass sits first in the
            tab order and shows itself only while focused. */}
        <a
          href="#console-content"
          className="sr-only focus:not-sr-only focus:absolute focus:top-2 focus:left-2 focus:z-50 focus:bg-primary focus:px-4 focus:py-2 focus:text-sm focus:font-semibold focus:text-primary-foreground">
          {t('console.aria.skip_to_content')}
        </a>
        <header className="sticky top-0 z-30 flex h-12 items-center justify-between border-b border-border bg-background px-3 text-foreground">
          <div className="flex min-w-0 items-center gap-3">
            <Sheet
              open={navigationOpen}
              onOpenChange={setNavigationOpen}
              onOpenChangeComplete={open => {
                if (!open) navigationTriggerRef.current?.focus()
              }}>
              <SheetTrigger
                render={
                  <Button
                    ref={navigationTriggerRef}
                    aria-label={t('console.aria.open_navigation')}
                    size="icon-sm"
                    type="button"
                    variant="ghost"
                  />
                }
                className="hover:bg-accent hover:text-accent-foreground lg:hidden">
                <RiMenuLine />
              </SheetTrigger>
              <SheetContent
                side="left"
                showCloseButton={false}
                className="w-[min(320px,88vw)] border-border bg-background p-0 text-foreground">
                <SheetHeader className="flex-row items-center justify-between border-b border-border p-3">
                  <div className="grid min-w-0 gap-0.5">
                    <SheetTitle className="truncate text-base text-foreground">{t('console.title')}</SheetTitle>
                    <SheetDescription className="truncate text-muted-foreground">
                      {t('console.control_plane')}
                    </SheetDescription>
                  </div>
                  <SheetClose
                    render={<Button aria-label={t('common.close')} size="icon-sm" type="button" variant="ghost" />}
                    className="hover:bg-accent hover:text-accent-foreground">
                    <RiCloseLine />
                  </SheetClose>
                </SheetHeader>
                <ConsoleNavigation onNavigate={() => setNavigationOpen(false)} />
              </SheetContent>
            </Sheet>
            {/* The brand mark repeats the sign-in screen's letter mark. It used to
                be the same gear the "AppConfigure" nav item carries, which read as
                a link into settings rather than as the product. */}
            <Link to="/" className="flex min-w-0 items-center gap-3 hover:text-link">
              <span
                className="grid size-8 shrink-0 place-items-center bg-primary text-sm font-semibold text-primary-foreground"
                aria-hidden>
                A
              </span>
              <span className="min-w-0">
                <h1 className="truncate text-sm font-semibold tracking-normal">{t('console.title')}</h1>
                <span className="hidden truncate text-xs text-muted-foreground sm:block">
                  {t('console.control_plane')}
                </span>
              </span>
            </Link>
          </div>
          <div className="flex items-center gap-2">
            <ConsoleReadiness />
            <ThemeToggle />
            <Tooltip>
              <TooltipTrigger
                render={
                  <Button
                    aria-label={t('console.aria.sign_out')}
                    disabled={logout.isPending}
                    size="icon-sm"
                    type="button"
                    variant="ghost"
                  />
                }
                className="hover:bg-accent hover:text-accent-foreground"
                onClick={() => logout.mutate()}>
                <RiLogoutBoxRLine />
              </TooltipTrigger>
              <TooltipContent>{t('console.aria.sign_out')}</TooltipContent>
            </Tooltip>
          </div>
        </header>

        <div className="grid grid-cols-1 min-h-[calc(100vh-3rem)] lg:grid-cols-[256px_minmax(0,1fr)]">
          <aside className="sticky top-12 hidden h-[calc(100vh-3rem)] flex-col border-r border-border bg-background lg:flex">
            <ConsoleNavigation />
          </aside>

          <main id="console-content" tabIndex={-1} className="min-w-0 p-4 md:p-6 xl:p-8">
            <Outlet />
          </main>
        </div>
      </div>
    </TooltipProvider>
  )
}

function ConsoleNavigation({ onNavigate }: { onNavigate?: () => void }) {
  const location = useLocation()
  const { t } = useTranslation()
  const version = systemVersion()

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <nav className="min-h-0 flex-1 overflow-y-auto p-3" aria-label={t('console.aria.sections')}>
        {NAV_SECTIONS.map((section, index) => (
          <div key={section.label ?? 'home'} className={cn('grid content-start gap-0.5', index > 0 && 'mt-5')}>
            {section.label ? (
              <h2 className="px-3 pb-1 text-xs font-semibold tracking-wide text-muted-foreground uppercase">
                {t(section.label)}
              </h2>
            ) : null}
            {section.items.map(item => {
              const Icon = item.icon
              const matchesArea = Boolean(item.match) && location.pathname.startsWith(`${item.match}/`)
              return (
                <NavLink
                  key={item.to}
                  to={item.to}
                  end={item.to === '/'}
                  onClick={onNavigate}
                  className={({ isActive, isPending }) =>
                    cn(
                      'flex min-h-10 items-center gap-3 border-l-4 px-3 py-2 text-left text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary',
                      isPending
                        ? 'border-primary/60 bg-accent text-accent-foreground'
                        : isActive || matchesArea
                          ? 'border-primary bg-accent text-accent-foreground'
                          : 'border-transparent text-muted-foreground hover:bg-accent hover:text-accent-foreground'
                    )
                  }>
                  <Icon className="size-4 shrink-0" aria-hidden />
                  <span className="truncate">{t(item.label)}</span>
                </NavLink>
              )
            })}
          </div>
        ))}
      </nav>
      <footer className="border-t border-border px-6 py-3 text-xs text-muted-foreground">
        <span className="block truncate" title={version}>
          Ankole {version}
        </span>
      </footer>
    </div>
  )
}

function systemVersion(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="ankole-version"]')?.content.trim() || 'development'
}
