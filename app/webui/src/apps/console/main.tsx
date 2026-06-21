import {
  RiBookOpenLine,
  RiBroadcastLine,
  RiDashboardLine,
  RiGroupLine,
  RiHardDrive2Line,
  RiLogoutBoxLine,
  RiPlugLine,
  RiPulseLine,
  RiRobot2Line,
  RiSearchLine,
  RiSettings3Line,
  RiShieldUserLine,
  RiSideBarLine,
  RiSparkling2Line,
  RiTimerLine
} from '@remixicon/react'
import { match } from '@pleisto/active-support'
import { useMutation, useQuery } from '@tanstack/react-query'
import type { TFunction } from 'i18next'
import type { ComponentType } from 'react'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import { Alert, AlertDescription, AlertTitle } from '@/uikit/components/alert'
import { Button } from '@/uikit/components/button'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInput,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarRail,
  SidebarTrigger
} from '@/uikit/components/sidebar'
import { Spinner } from '@/uikit/components/spinner'
import { TooltipProvider } from '@/uikit/components/tooltip'
import { AgentOperationsPage } from './sections/agents'
import { ChatRecallPage } from './sections/chat-recall'
import { GroupsPage } from './sections/groups'
import { LibraryEntriesPage } from './sections/library'
import { LivePage } from './sections/live'
import { LlmProvidersPage } from './sections/llm-providers'
import { OverviewPage } from './sections/overview'
import { PeoplePage } from './sections/people'
import { PluginsPage } from './sections/plugins'
import { SchedulesPage } from './sections/schedules'
import { SettingsPage } from './sections/settings'
import { SkillsPage } from './sections/skills'
import { WebToolsPage } from './sections/web-tools'
import { WorkersPage } from './sections/workers'
import { mountSpa } from '../mount-spa'

type ConsoleSection =
  | 'overview'
  | 'agents'
  | 'live'
  | 'channels'
  | 'chat-recall'
  | 'llm-providers'
  | 'web-tools'
  | 'schedules'
  | 'workers'
  | 'skills'
  | 'library'
  | 'people'
  | 'groups'
  | 'plugins'
  | 'settings'

/*
 * Nav titles, descriptions, and group labels hold i18n keys; they are resolved
 * with t() at render and search time.
 */
type NavItem = {
  title: string
  slug: ConsoleSection
  description: string
  icon: ComponentType<{ className?: string }>
}

type NavGroup = {
  label: string
  items: NavItem[]
}

const NAV_GROUPS: NavGroup[] = [
  {
    label: 'console.nav.group_platform',
    items: [
      {
        title: 'console.nav.overview',
        slug: 'overview',
        description: 'console.nav.overview_description',
        icon: RiDashboardLine
      },
      {
        title: 'console.nav.agents',
        slug: 'agents',
        description: 'console.nav.agents_description',
        icon: RiRobot2Line
      },
      {
        title: 'console.nav.people',
        slug: 'people',
        description: 'console.nav.people_description',
        icon: RiShieldUserLine
      },
      {
        title: 'console.nav.groups',
        slug: 'groups',
        description: 'console.nav.groups_description',
        icon: RiGroupLine
      }
    ]
  },
  {
    label: 'console.nav.group_agent_runtime',
    items: [
      {
        title: 'console.nav.channels',
        slug: 'channels',
        description: 'console.nav.channels_description',
        icon: RiBroadcastLine
      },
      {
        title: 'console.nav.live',
        slug: 'live',
        description: 'console.nav.live_description',
        icon: RiPulseLine
      },
      {
        title: 'console.nav.schedules',
        slug: 'schedules',
        description: 'console.nav.schedules_description',
        icon: RiTimerLine
      },
      {
        title: 'console.nav.workers',
        slug: 'workers',
        description: 'console.nav.workers_description',
        icon: RiHardDrive2Line
      },
      {
        title: 'console.nav.llm_providers',
        slug: 'llm-providers',
        description: 'console.nav.llm_providers_description',
        icon: RiSparkling2Line
      },
      {
        title: 'console.nav.web_tools',
        slug: 'web-tools',
        description: 'console.nav.web_tools_description',
        icon: RiSearchLine
      },
      {
        title: 'console.nav.chat_recall',
        slug: 'chat-recall',
        description: 'console.nav.chat_recall_description',
        icon: RiSearchLine
      }
    ]
  },
  {
    label: 'console.nav.group_library',
    items: [
      {
        title: 'console.nav.skills',
        slug: 'skills',
        description: 'console.nav.skills_description',
        icon: RiPlugLine
      },
      {
        title: 'console.nav.library',
        slug: 'library',
        description: 'console.nav.library_description',
        icon: RiBookOpenLine
      },
      {
        title: 'console.nav.plugins',
        slug: 'plugins',
        description: 'console.nav.plugins_description',
        icon: RiPlugLine
      },
      {
        title: 'console.nav.settings',
        slug: 'settings',
        description: 'console.nav.settings_description',
        icon: RiSettings3Line
      }
    ]
  }
]

const NAV_ITEMS = NAV_GROUPS.flatMap(group => group.items)

/**
 * Renders the authenticated console shell after the server route has accepted the session.
 */
function ConsoleApp() {
  const { t } = useTranslation()
  const [section, setSection] = useConsoleSection()
  const session = useQuery({
    queryKey: ['session'],
    queryFn: () => unwrap(api.session.get())
  })
  const logout = useMutation({
    mutationFn: () => unwrap(api.session.delete()),
    onSuccess: () => window.location.assign('/sessions/new')
  })
  const active = NAV_ITEMS.find(item => item.slug === section) ?? NAV_ITEMS[0]!

  return (
    <TooltipProvider delay={0}>
      <SidebarProvider defaultOpen={readSidebarCookie()}>
        <ConsoleSidebar section={section} onSectionChange={setSection} />
        <SidebarInset>
          <header className="flex h-14 shrink-0 items-center justify-between gap-3 border-b border-border px-4">
            <div className="flex min-w-0 items-center gap-2">
              <SidebarTrigger className="-ml-1" />
              <div className="h-4 w-px bg-border" />
              <div className="flex min-w-0 items-center gap-2 text-sm">
                <span className="text-muted-foreground">{t('console.title')}</span>
                <span className="text-muted-foreground">/</span>
                <span className="truncate font-medium">{t(active.title)}</span>
              </div>
            </div>
            <Button variant="outline" size="sm" disabled={logout.isPending} onClick={() => logout.mutate()}>
              {logout.isPending ? <Spinner /> : <RiLogoutBoxLine />}
              {t('console.logout')}
            </Button>
          </header>

          <main className="flex flex-1 flex-col gap-6 p-4 md:p-6">
            {session.data?.setupRestartRecommended ? (
              <Alert>
                <AlertTitle>{t('console.restart_recommended_title')}</AlertTitle>
                <AlertDescription>{t('console.restart_recommended_body')}</AlertDescription>
              </Alert>
            ) : null}
            <ConsoleSectionView section={section} />
          </main>
        </SidebarInset>
      </SidebarProvider>
    </TooltipProvider>
  )
}

/**
 * Renders searchable console navigation without changing the URL until a section is selected.
 */
function ConsoleSidebar({
  section,
  onSectionChange
}: {
  section: ConsoleSection
  onSectionChange(section: ConsoleSection): void
}) {
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const groups = useMemo(() => filterNavGroups(query, t), [query, t])

  return (
    <Sidebar variant="floating">
      <SidebarHeader className="gap-2">
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton size="lg" onClick={() => onSectionChange('overview')}>
              <span className="flex size-8 shrink-0 items-center justify-center bg-sidebar-accent">
                <RiSideBarLine className="size-4" />
              </span>
              <span className="grid flex-1 text-left leading-tight">
                <span className="truncate font-semibold">BullX</span>
                <span className="truncate text-xs text-sidebar-foreground/70">{t('console.nav.console_label')}</span>
              </span>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
        <div className="relative">
          <RiSearchLine className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-sidebar-foreground/50" />
          <SidebarInput
            type="search"
            value={query}
            onChange={event => setQuery(event.target.value)}
            placeholder={t('console.nav.search_placeholder')}
            aria-label={t('console.nav.search_aria')}
            className="pl-8"
          />
        </div>
      </SidebarHeader>
      <SidebarContent>
        {groups.map(group => (
          <SidebarGroup key={group.label}>
            <SidebarGroupLabel>{t(group.label)}</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {group.items.map(item => (
                  <SidebarMenuItem key={item.slug}>
                    <SidebarMenuButton isActive={section === item.slug} onClick={() => onSectionChange(item.slug)}>
                      <item.icon />
                      <span>{t(item.title)}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        ))}
        {groups.length === 0 ? (
          <p className="px-5 py-2 text-sm text-sidebar-foreground/60">{t('console.nav.no_matches', { query })}</p>
        ) : null}
      </SidebarContent>
      <SidebarFooter>
        <div className="px-3 py-2 text-xs text-sidebar-foreground/60">{t('console.nav.footer_note')}</div>
      </SidebarFooter>
      <SidebarRail />
    </Sidebar>
  )
}

/**
 * Maps one URL/nav section to its operational console page.
 */
function ConsoleSectionView({ section }: { section: ConsoleSection }) {
  return match(section)
    .with('overview', () => <OverviewPage />)
    .with('agents', () => <AgentOperationsPage />)
    .with('live', () => <LivePage />)
    .with('channels', () => <AgentOperationsPage />)
    .with('llm-providers', () => <LlmProvidersPage />)
    .with('web-tools', () => <WebToolsPage />)
    .with('chat-recall', () => <ChatRecallPage />)
    .with('schedules', () => <SchedulesPage />)
    .with('workers', () => <WorkersPage />)
    .with('skills', () => <SkillsPage />)
    .with('library', () => <LibraryEntriesPage />)
    .with('people', () => <PeoplePage />)
    .with('groups', () => <GroupsPage />)
    .with('plugins', () => <PluginsPage />)
    .with('settings', () => <SettingsPage />)
    .exhaustive()
}

/**
 * Keeps the selected console section in sync with browser history.
 *
 * The console is one SPA entry guarded by the server. Section changes stay
 * client-side, but direct deep links still work because the server routes every
 * `/console/*` path back to this entry after auth.
 */
function useConsoleSection(): [ConsoleSection, (section: ConsoleSection) => void] {
  const [section, setSection] = useState<ConsoleSection>(() => sectionFromLocation())

  useEffect(() => {
    const listener = () => setSection(sectionFromLocation())
    window.addEventListener('popstate', listener)
    return () => window.removeEventListener('popstate', listener)
  }, [])

  return [
    section,
    next => {
      setSection(next)
      const path = next === 'overview' ? '/console' : `/console/${next}`
      window.history.pushState({}, '', path)
    }
  ]
}

/**
 * Parses the first path segment after `/console` into a known section.
 */
function sectionFromLocation(): ConsoleSection {
  const slug = window.location.pathname.replace(/^\/console\/?/, '').split('/')[0] || 'overview'
  return isConsoleSection(slug) ? slug : 'overview'
}

function isConsoleSection(value: string): value is ConsoleSection {
  return NAV_ITEMS.some(item => item.slug === value)
}

/**
 * Filters navigation by localized title or description.
 */
function filterNavGroups(query: string, t: TFunction): NavGroup[] {
  const needle = query.trim().toLowerCase()
  if (!needle) return NAV_GROUPS
  return NAV_GROUPS.map(group => ({
    ...group,
    items: group.items.filter(
      item => t(item.title).toLowerCase().includes(needle) || t(item.description).toLowerCase().includes(needle)
    )
  })).filter(group => group.items.length > 0)
}

/**
 * Restores the sidebar open state written by the sidebar component.
 */
function readSidebarCookie(): boolean {
  const match = document.cookie.match(/(?:^|;\s*)sidebar_state=(true|false)/)
  return match ? match[1] === 'true' : true
}

mountSpa(<ConsoleApp />)
