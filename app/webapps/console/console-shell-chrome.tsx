import { useMutation, Link } from './tenant-context'
import {
  Button,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  Sheet,
  SheetClose,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
  SidebarProvider,
  SidebarTrigger,
  useSidebar,
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
  RiLogoutCircleRLine,
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

import { useQuery } from '@tanstack/react-query'
import { useEffect, useRef, type ComponentType } from 'react'
import { useTranslation } from 'react-i18next'
import { Outlet, useLocation, useMatches } from '@tanstack/react-router'
import { browserSession } from '../common/api/generated/sdk.gen'
import { authenticationRef, podID } from '../common/browser-context'
import { SlotGate } from '../common/slots'
import { BrandIcon } from '../common/brand'
import { ErrorBoundary } from '../common/error-boundary'
import { ThemeToggle } from '../common/theme-toggle'
import { dataTenantID, endAccountSession, endBrowserSession } from '../common/browser-session'
import { ConsoleReadiness } from './console-readiness'
import { useConsoleSlots } from './slots'
import { ConsoleTenantContent, TenantSwitcher } from './tenant-switcher'

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
      { to: '/drive', label: 'console.drive.title', icon: RiTerminalBoxLine },
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
      { to: '/model-profiles', label: 'console.nav.model_profiles', icon: RiSettings3Line },
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

const SIDEBAR_STORAGE_KEY = 'ankole.console.sidebar_collapsed'

function readInitialSidebarCollapsed(): boolean {
  try {
    return typeof window !== 'undefined' && window.localStorage?.getItem(SIDEBAR_STORAGE_KEY) === '1'
  } catch {
    return false
  }
}

/** Routed console frame: header, sidebar navigation, and the active page outlet. */
export function ConsoleLayout() {
  return (
    <SidebarProvider
      defaultOpen={!readInitialSidebarCollapsed()}
      mobileBreakpoint={1024}
      className="h-svh min-h-0 flex-col overflow-hidden bg-ground text-foreground">
      <ConsoleFrame />
    </SidebarProvider>
  )
}

function ConsoleFrame() {
  const { t } = useTranslation()
  const matchedSlotRoute = useMatches({ select: matches => matches.at(-1)?.staticData.consoleSlot })
  const { open, openMobile: navigationOpen, setOpenMobile: setNavigationOpen } = useSidebar()
  const sidebarCollapsed = !open
  const navigationTriggerRef = useRef<HTMLButtonElement>(null)
  useEffect(() => {
    try {
      window.localStorage?.setItem(SIDEBAR_STORAGE_KEY, open ? '0' : '1')
    } catch {
      // Storage is optional; SidebarProvider still owns the in-memory state.
    }
  }, [open])
  const session = useQuery({
    queryKey: ['console-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: ({ signal }) => browserSession({ signal }),
    staleTime: 60_000
  })
  const signOut = useMutation({
    meta: { invalidates: false },
    mutationFn: endAccountSession,
    onSettled: () => window.location.assign(consoleReturnPath(true))
  })
  const signOutAll = useMutation({
    meta: { invalidates: false },
    mutationFn: endBrowserSession,
    onSettled: () =>
      window.location.assign(`/sessions/logged-out?${new URLSearchParams({ return_to: consoleReturnPath(false) })}`)
  })
  const tenantName = session.data?.tenant?.displayName ?? ''
  const signOutLabel = tenantName ? t('pod.sidebar.sign_out_name', { name: tenantName }) : t('pod.sidebar.sign_out')
  const multipleAccounts = (session.data?.accounts.length ?? 0) > 1
  const toggleLabel = sidebarCollapsed ? t('console.aria.expand_navigation') : t('console.aria.collapse_navigation')

  return (
    <>
      {/* Reaching the page content by keyboard meant tabbing past the header and
          every navigation link, on every page. The bypass sits first in the
          tab order and shows itself only while focused. */}
      <a
        href="#console-content"
        className="sr-only focus:not-sr-only focus:absolute focus:top-2 focus:left-2 focus:z-50 focus:bg-foreground focus:px-4 focus:py-2 focus:text-sm focus:font-semibold focus:text-background">
        {t('console.aria.skip_to_content')}
      </a>
      <header className="z-20 flex h-11 shrink-0 items-center bg-ground px-3 text-foreground">
        <div className="flex min-w-0 items-center gap-2">
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
              className="data-[side=left]:w-[min(320px,88vw)] bg-ground p-0 text-foreground">
              <SheetHeader className="flex-row items-center justify-between border-b border-border p-3">
                <div className="flex min-w-0 items-center gap-2.5">
                  <BrandIcon className="size-6 shrink-0" />
                  <SheetTitle className="truncate text-[13px] font-semibold text-foreground">
                    {t('console.title')}
                  </SheetTitle>
                </div>
                <SheetClose
                  render={<Button aria-label={t('common.close')} size="icon-sm" type="button" variant="ghost" />}
                  className="hover:bg-accent hover:text-accent-foreground">
                  <RiCloseLine />
                </SheetClose>
              </SheetHeader>
              <ErrorBoundary variant="inline" className="m-2">
                <ConsoleNavigation mobile onNavigate={() => setNavigationOpen(false)} />
              </ErrorBoundary>
            </SheetContent>
          </Sheet>
          <Link to="/" className="flex min-w-0 items-center gap-2.5 rounded-control py-1 pr-1.5">
            <BrandIcon className="size-6 shrink-0" />
            <h1 className="truncate text-[13px] font-semibold tracking-normal">{t('console.title')}</h1>
          </Link>
          <SidebarTrigger
            label={toggleLabel}
            aria-expanded={open}
            className="hidden text-fg-tertiary hover:bg-accent hover:text-foreground lg:inline-flex"
          />
        </div>
      </header>

      <div className="relative flex min-h-0 flex-1 overflow-hidden">
        <aside
          className={cn(
            'z-0 hidden shrink-0 flex-col overflow-hidden bg-ground transition-[width,opacity] duration-(--duration-feedback) ease-productive motion-reduce:transition-none lg:flex',
            sidebarCollapsed ? 'w-0 opacity-0' : 'w-60 opacity-100'
          )}
          aria-hidden={sidebarCollapsed || undefined}
          inert={sidebarCollapsed || undefined}>
          <div className="flex h-full w-60 flex-col">
            <ErrorBoundary variant="inline" className="m-2">
              <ConsoleNavigation />
            </ErrorBoundary>
          </div>
        </aside>

        {/* The page is a sheet of paper elevated above the ground, with its own
            sheet header holding the account actions as in the Pod shell. The
            header and navigation remain on the ground layer. */}
        <main
          id="console-content"
          tabIndex={-1}
          className={cn(
            'relative z-10 m-1.5 mt-0 flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden paper-sheet transition-[margin] duration-(--duration-feedback) ease-productive motion-reduce:transition-none',
            sidebarCollapsed ? 'lg:ml-1.5' : 'lg:ml-0'
          )}>
          <div className="sheet-header justify-end gap-1.5 border-b border-border">
            {dataTenantID() ? (
              <ErrorBoundary fallback={null}>
                <ConsoleReadiness />
              </ErrorBoundary>
            ) : null}
            <ThemeToggle />
            {multipleAccounts ? (
              <DropdownMenu onOpenChange={open => open && void session.refetch()}>
                <DropdownMenuTrigger
                  render={
                    <Button
                      aria-label={t('console.aria.sign_out')}
                      disabled={signOut.isPending || signOutAll.isPending}
                      size="icon-sm"
                      type="button"
                      variant="ghost"
                    />
                  }
                  className="hover:bg-accent hover:text-accent-foreground">
                  <RiLogoutBoxRLine />
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" sideOffset={6}>
                  <DropdownMenuItem disabled={signOut.isPending} onClick={() => signOut.mutate()}>
                    <RiLogoutBoxRLine aria-hidden />
                    {signOutLabel}
                  </DropdownMenuItem>
                  <DropdownMenuItem disabled={signOutAll.isPending} onClick={() => signOutAll.mutate()}>
                    <RiLogoutCircleRLine aria-hidden />
                    {t('auth.sign_out_all')}
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            ) : (
              <Button
                aria-label={tenantName ? signOutLabel : t('console.aria.sign_out')}
                disabled={signOut.isPending}
                onClick={() => signOut.mutate()}
                size="icon-sm"
                type="button"
                variant="ghost"
                className="hover:bg-accent hover:text-accent-foreground">
                <RiLogoutBoxRLine />
              </Button>
            )}
          </div>

          <div className="min-h-0 flex-1 overflow-y-auto p-4 [scrollbar-gutter:stable] md:p-6 xl:p-8">
            {matchedSlotRoute ? (
              <SlotGate slot={matchedSlotRoute}>
                {enabled =>
                  enabled ? (
                    <ConsoleTenantContent slot={matchedSlotRoute}>
                      <Outlet />
                    </ConsoleTenantContent>
                  ) : (
                    <div className="grid gap-6">
                      <TenantSwitcher />
                      <Outlet />
                    </div>
                  )
                }
              </SlotGate>
            ) : (
              <ConsoleTenantContent>
                <Outlet />
              </ConsoleTenantContent>
            )}
          </div>
        </main>
      </div>
    </>
  )
}

function consoleReturnPath(switchAccount: boolean): string {
  const url = new URL(window.location.href)
  url.searchParams.delete('data_tenant')
  if (switchAccount) url.searchParams.set('switch', '1')
  else url.searchParams.delete('switch')
  return `${url.pathname}${url.search}`
}

function ConsoleNavigation({ mobile = false, onNavigate }: { mobile?: boolean; onNavigate?: () => void }) {
  const location = useLocation()
  const { t } = useTranslation()
  const slots = useConsoleSlots()
  const version = systemVersion()
  const coreLabels = new Set(NAV_SECTIONS.map(section => section.label).filter(Boolean))
  const extensionSections = slots.navSections ?? []

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <nav className="min-h-0 flex-1 overflow-y-auto px-2 py-1.5" aria-label={t('console.aria.sections')}>
        {NAV_SECTIONS.map((section, index) => {
          const appended = extensionSections.filter(ext => ext.label && ext.label === section.label)
          return (
            <div key={section.label ?? 'home'} className={cn('grid content-start gap-px', index > 0 && 'mt-3')}>
              {section.label ? <h2 className="px-2 pb-0.5 text-xs text-fg-tertiary">{t(section.label)}</h2> : null}
              {section.items.map(item => (
                <ConsoleNavLink
                  key={item.to}
                  item={item}
                  mobile={mobile}
                  pathname={location.pathname}
                  onNavigate={onNavigate}
                />
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
                                  <ConsoleNavLink
                                    item={item}
                                    mobile={mobile}
                                    pathname={location.pathname}
                                    onNavigate={onNavigate}
                                  />
                                ) : null
                              }
                            </SlotGate>
                          ) : (
                            <ConsoleNavLink
                              key={item.id}
                              item={item}
                              mobile={mobile}
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
                  <div className="mt-3 grid content-start gap-px">
                    {ext.label ? <h2 className="px-2 pb-0.5 text-xs text-fg-tertiary">{t(ext.label)}</h2> : null}
                    {ext.items.map(item =>
                      item.when ? (
                        <SlotGate key={item.id} slot={{ pluginId: ext.pluginId, when: item.when }}>
                          {itemEnabled =>
                            itemEnabled ? (
                              <ConsoleNavLink
                                item={item}
                                mobile={mobile}
                                pathname={location.pathname}
                                onNavigate={onNavigate}
                              />
                            ) : null
                          }
                        </SlotGate>
                      ) : (
                        <ConsoleNavLink
                          key={item.id}
                          item={item}
                          mobile={mobile}
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
      <footer className="px-4 py-2 text-xs text-fg-tertiary">
        <span className="block truncate" title={version}>
          Ankole {version}
        </span>
      </footer>
    </div>
  )
}

function ConsoleNavLink({
  item,
  mobile = false,
  pathname,
  onNavigate
}: {
  item: NavItem
  mobile?: boolean
  pathname: string
  onNavigate?: () => void
}) {
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
        'nav-row flex items-center gap-2 rounded-control px-2 text-left text-[13px] leading-5 focus-visible:-outline-offset-2',
        mobile ? 'min-h-10 py-2' : 'min-h-7 py-0.5'
      )}>
      <Icon className="size-4 shrink-0 text-(--nav-icon)" aria-hidden />
      <span className="truncate">{t(item.label)}</span>
    </Link>
  )
}

function systemVersion(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="ankole-version"]')?.content.trim() || 'development'
}
