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
  RiBrainLine,
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
import { Link, Outlet, useLocation, useMatches } from '@tanstack/react-router'
import { SlotGate } from '../common/slots'
import { ThemeToggle } from '../common/theme-toggle'
import { endSiteSession } from '../common/browser-session'
import { ConsoleReadiness } from './console-readiness'
import { useConsoleSlots } from './slots'
import { TenantSwitcher } from './tenant-switcher'

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
      { to: '/brain/objects', match: '/brain', label: 'console.nav.brain', icon: RiBrainLine },
      { to: '/worker-envs', label: 'console.nav.worker_envs', icon: RiTerminalBoxLine }
    ]
  },
  {
    label: 'console.nav.group_connections',
    items: [
      { to: '/providers', label: 'console.nav.providers', icon: RiSparkling2Line },
      { to: '/worker-providers', label: 'console.worker_providers.title', icon: RiServerLine },
      { to: '/signals', label: 'console.nav.signals', icon: RiBroadcastLine },
      { to: '/identity', label: 'console.nav.identity', icon: RiShieldKeyholeLine },
      { to: '/oidc-clients', label: 'console.nav.oidc_clients', icon: RiKey2Line }
    ]
  },
  {
    label: 'console.nav.group_platform',
    items: [
      { to: '/workers', label: 'console.nav.workers', icon: RiServerLine },
      { to: '/tenants', label: 'console.tenants.title', icon: RiShieldKeyholeLine },
      { to: '/access/groups', match: '/access', label: 'console.nav.access', icon: RiKey2Line },
      { to: '/settings', label: 'console.nav.settings', icon: RiSettings3Line }
    ]
  }
]

/** Routed console frame: header, sidebar navigation, and the active page outlet. */
export function ConsoleLayout() {
  const { t } = useTranslation()
  const matchedSlotRoute = useMatches({ select: matches => matches.at(-1)?.staticData.consoleSlot })
  const [navigationOpen, setNavigationOpen] = useState(false)
  const navigationTriggerRef = useRef<HTMLButtonElement>(null)
  const logout = useMutation({
    meta: { invalidates: false },
    mutationFn: endSiteSession,
    onSettled: () => window.location.assign('/sessions/new')
  })

  return (
    <TooltipProvider>
      <div className="h-screen overflow-y-scroll bg-ground text-foreground [scrollbar-gutter:stable]">
        {/* Reaching the page content by keyboard meant tabbing past the header and
            every navigation link, on every page. The bypass sits first in the
            tab order and shows itself only while focused. */}
        <a
          href="#console-content"
          className="sr-only focus:not-sr-only focus:absolute focus:top-2 focus:left-2 focus:z-50 focus:bg-foreground focus:px-4 focus:py-2 focus:text-sm focus:font-semibold focus:text-background">
          {t('console.aria.skip_to_content')}
        </a>
        <header className="sticky top-0 z-30 flex h-12 items-center justify-between bg-ground px-3 text-foreground">
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
                className="data-[side=left]:w-[min(320px,88vw)] p-0 text-foreground">
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
            <Link to="/" className="flex min-w-0 items-center gap-3">
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
            {matchedSlotRoute ? (
              <SlotGate slot={matchedSlotRoute}>
                {enabled => (enabled && matchedSlotRoute.scope === 'site' ? null : <TenantSwitcher />)}
              </SlotGate>
            ) : (
              <TenantSwitcher />
            )}
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
          <aside className="sticky top-12 hidden h-[calc(100vh-3rem)] flex-col bg-ground lg:flex">
            <ConsoleNavigation />
          </aside>

          {/* The page is a sheet of paper on the ground, as in the design language: the header and the
              navigation stay on the ground, and only the sheet carries the page. */}
          <main
            id="console-content"
            tabIndex={-1}
            className="m-1.5 mt-0 min-w-0 rounded-panel bg-background p-4 shadow-[0_0_0_1px_var(--color-border),0_1px_3px_rgb(38_40_42/0.04)] md:p-6 lg:ml-0 xl:p-8">
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
  const slots = useConsoleSlots()
  const version = systemVersion()
  const coreLabels = new Set(NAV_SECTIONS.map(section => section.label).filter(Boolean))
  const extensionSections = slots.navSections ?? []

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <nav className="min-h-0 flex-1 overflow-y-auto p-3" aria-label={t('console.aria.sections')}>
        {NAV_SECTIONS.map((section, index) => {
          const appended = extensionSections.filter(ext => ext.label && ext.label === section.label)
          return (
            <div key={section.label ?? 'home'} className={cn('grid content-start gap-0.5', index > 0 && 'mt-5')}>
              {section.label ? (
                <h2 className="px-3 pb-1 text-xs font-semibold tracking-wide text-muted-foreground uppercase">
                  {t(section.label)}
                </h2>
              ) : null}
              {section.items.map(item => (
                <ConsoleNavLink key={item.to} item={item} pathname={location.pathname} onNavigate={onNavigate} />
              ))}
              {appended.map(ext => (
                <SlotGate key={ext.id} slot={ext}>
                  {sectionEnabled =>
                    sectionEnabled
                      ? ext.items.map(item =>
                          item.when ? (
                            <SlotGate key={item.id} slot={{ pluginId: ext.pluginId, when: item.when }}>
                              {itemEnabled =>
                                itemEnabled ? (
                                  <ConsoleNavLink item={item} pathname={location.pathname} onNavigate={onNavigate} />
                                ) : null
                              }
                            </SlotGate>
                          ) : (
                            <ConsoleNavLink
                              key={item.id}
                              item={item}
                              pathname={location.pathname}
                              onNavigate={onNavigate}
                            />
                          )
                        )
                      : null
                  }
                </SlotGate>
              ))}
            </div>
          )
        })}
        {extensionSections
          .filter(ext => !ext.label || !coreLabels.has(ext.label))
          .map(ext => (
            <SlotGate key={ext.id} slot={ext}>
              {sectionEnabled =>
                sectionEnabled ? (
                  <div className="mt-5 grid content-start gap-0.5">
                    {ext.label ? (
                      <h2 className="px-3 pb-1 text-xs font-semibold tracking-wide text-muted-foreground uppercase">
                        {t(ext.label)}
                      </h2>
                    ) : null}
                    {ext.items.map(item =>
                      item.when ? (
                        <SlotGate key={item.id} slot={{ pluginId: ext.pluginId, when: item.when }}>
                          {itemEnabled =>
                            itemEnabled ? (
                              <ConsoleNavLink item={item} pathname={location.pathname} onNavigate={onNavigate} />
                            ) : null
                          }
                        </SlotGate>
                      ) : (
                        <ConsoleNavLink
                          key={item.id}
                          item={item}
                          pathname={location.pathname}
                          onNavigate={onNavigate}
                        />
                      )
                    )}
                  </div>
                ) : null
              }
            </SlotGate>
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

function ConsoleNavLink({ item, pathname, onNavigate }: { item: NavItem; pathname: string; onNavigate?: () => void }) {
  const { t } = useTranslation()
  const Icon = item.icon
  const isActive =
    (item.to === '/' ? pathname === '/' : pathname === item.to || pathname.startsWith(`${item.to}/`)) ||
    (Boolean(item.match) && (pathname === item.match || pathname.startsWith(`${item.match}/`)))
  return (
    <Link
      to={item.to}
      activeOptions={{ exact: item.to === '/', includeSearch: false }}
      aria-current={isActive ? 'page' : undefined}
      onClick={onNavigate}
      className={cn(
        'flex min-h-10 items-center gap-3 border-l-4 px-3 py-2 text-left text-sm transition-colors focus-visible:-outline-offset-2',
        isActive
          ? 'border-foreground bg-accent text-accent-foreground'
          : 'border-transparent text-muted-foreground fine-hover:hover:bg-accent fine-hover:hover:text-accent-foreground'
      )}>
      <Icon className="size-4 shrink-0" aria-hidden />
      <span className="truncate">{t(item.label)}</span>
    </Link>
  )
}

function systemVersion(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="ankole-version"]')?.content.trim() || 'development'
}
