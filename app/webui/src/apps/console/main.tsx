import {
  RiAddLine,
  RiBookOpenLine,
  RiBroadcastLine,
  RiDashboardLine,
  RiDeleteBinLine,
  RiGroupLine,
  RiHardDrive2Line,
  RiLogoutBoxLine,
  RiPencilLine,
  RiPlugLine,
  RiRobot2Line,
  RiSaveLine,
  RiSearchLine,
  RiSettings3Line,
  RiShieldUserLine,
  RiSideBarLine,
  RiSparkling2Line,
  RiTimerLine
} from '@remixicon/react'
import {
  resolveBullXPluginLocalizedText,
  type BullXPluginJsonValue,
  type BullXPluginSetupField
} from '@agentbull/bullx-sdk/plugins'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { ComponentType, ReactNode } from 'react'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, apiErrorMessage, unwrap } from '@/lib/api'
import type { AiAgentModelsConfig } from '@/ai-agent/config'
import type {
  ConsoleAgent,
  ConsoleAgentLibraryEntry,
  ConsoleChatChannel,
  ConsoleExternalGatewayAdapter,
  ConsoleHumanUser,
  ConsolePrincipalGroup
} from '@/console/service'
import type { ScheduledTaskSchedule } from '@/common/db-schema'
import {
  clonePluginJsonObject as cloneJsonObject,
  defaultPluginConfigForSetup,
  getPluginConfigPath as getPath,
  isPluginConfigJsonObject as isJsonObject,
  mergePluginConfigObjects as mergeJsonRecords,
  setPluginConfigPath as setPath,
  type PluginConfigJsonObject
} from '@/plugins/config-json'
import { Alert, AlertDescription, AlertTitle } from '@/uikit/components/alert'
import { Badge } from '@/uikit/components/badge'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from '@/uikit/components/empty'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '@/uikit/components/field'
import { Input } from '@/uikit/components/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { Skeleton } from '@/uikit/components/skeleton'
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
import { Switch } from '@/uikit/components/switch'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/uikit/components/table'
import { Textarea } from '@/uikit/components/textarea'
import { TooltipProvider } from '@/uikit/components/tooltip'
import { mountSpa } from '../mount-spa'

type JsonValue = BullXPluginJsonValue
type JsonObject = PluginConfigJsonObject

// Backend response shapes flow from the server via Eden Treaty (no hand-copied
// contracts): agent/channel/adapter shapes come from the console service import
// above; live API responses are typed by `unwrap(api.console.*)`. Setup fields use
// the SDK plugin field type.
type SetupField = BullXPluginSetupField
type ScheduledTaskDeliveryInput = {
  binding_name: string
  room_id: string
  thread_id?: string
}

type ConsoleSection =
  | 'overview'
  | 'agents'
  | 'channels'
  | 'llm-providers'
  | 'schedules'
  | 'workers'
  | 'skills'
  | 'library'
  | 'people'
  | 'groups'
  | 'plugins'
  | 'settings'

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
    label: 'Platform',
    items: [
      {
        title: 'Overview',
        slug: 'overview',
        description: 'Workspace health, resource counts, and operation map.',
        icon: RiDashboardLine
      },
      {
        title: 'Agents',
        slug: 'agents',
        description: 'AI principals, model profiles, channels, skills, schedules, and library.',
        icon: RiRobot2Line
      },
      {
        title: 'People',
        slug: 'people',
        description: 'Human principals and profile data.',
        icon: RiShieldUserLine
      },
      {
        title: 'Groups',
        slug: 'groups',
        description: 'Static and computed authorization groups.',
        icon: RiGroupLine
      }
    ]
  },
  {
    label: 'Agent Runtime',
    items: [
      {
        title: 'Channels',
        slug: 'channels',
        description: 'External gateway bindings owned by each agent.',
        icon: RiBroadcastLine
      },
      {
        title: 'Schedules',
        slug: 'schedules',
        description: 'Recurring work definitions and run history.',
        icon: RiTimerLine
      },
      {
        title: 'Computer Workers',
        slug: 'workers',
        description: 'Registered workers and agent pins.',
        icon: RiHardDrive2Line
      },
      {
        title: 'LLM Providers',
        slug: 'llm-providers',
        description: 'Provider credentials and runtime options.',
        icon: RiSparkling2Line
      }
    ]
  },
  {
    label: 'Library',
    items: [
      {
        title: 'Skills',
        slug: 'skills',
        description: 'Canonical skills and per-agent assignment toggles.',
        icon: RiPlugLine
      },
      {
        title: 'Library Entries',
        slug: 'library',
        description: 'Agent-owned SOUL.md and generated container entries.',
        icon: RiBookOpenLine
      },
      {
        title: 'Plugins',
        slug: 'plugins',
        description: 'Installed plugin catalog and adapter capabilities.',
        icon: RiPlugLine
      },
      {
        title: 'Settings',
        slug: 'settings',
        description: 'Installation-level operational settings.',
        icon: RiSettings3Line
      }
    ]
  }
]

const NAV_ITEMS = NAV_GROUPS.flatMap(group => group.items)

function ConsoleApp() {
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
                <span className="text-muted-foreground">BullX Console</span>
                <span className="text-muted-foreground">/</span>
                <span className="truncate font-medium">{active.title}</span>
              </div>
            </div>
            <Button variant="outline" size="sm" disabled={logout.isPending} onClick={() => logout.mutate()}>
              {logout.isPending ? <Spinner /> : <RiLogoutBoxLine />}
              Logout
            </Button>
          </header>

          <main className="flex flex-1 flex-col gap-6 p-4 md:p-6">
            {session.data?.setupRestartRecommended ? (
              <Alert>
                <AlertTitle>Restart recommended</AlertTitle>
                <AlertDescription>
                  Setup changed runtime configuration. Restart the app when convenient.
                </AlertDescription>
              </Alert>
            ) : null}
            <ConsoleSectionView section={section} />
          </main>
        </SidebarInset>
      </SidebarProvider>
    </TooltipProvider>
  )
}

function AgentOperationsPage() {
  const { t } = useTranslation()
  const [selectedAgentUid, setSelectedAgentUid] = useState<string | null>(null)
  const [restartRequired, setRestartRequired] = useState(false)
  const agents = useAgentsQuery()
  const adapters = useAdaptersQuery()
  const selectedAgent =
    agents.data?.agents.find(agent => agent.uid === selectedAgentUid) ?? agents.data?.agents[0] ?? null

  useEffect(() => {
    if (!selectedAgentUid && agents.data?.agents[0]) setSelectedAgentUid(agents.data.agents[0].uid)
  }, [agents.data?.agents, selectedAgentUid])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader
        title={t('console.agents.title')}
        description="Create and operate AI agents, then bind their channels and runtime capabilities."
      />
      {restartRequired ? (
        <Alert>
          <AlertTitle>{t('console.restart_required_title')}</AlertTitle>
          <AlertDescription>{t('console.restart_required_body')}</AlertDescription>
        </Alert>
      ) : null}
      <section className="grid min-h-[560px] gap-6 lg:grid-cols-[360px_minmax(0,1fr)]">
        <AgentListPanel
          agents={agents.data?.agents ?? []}
          loading={agents.isPending}
          error={agents.error}
          selectedAgentUid={selectedAgent?.uid ?? null}
          onSelect={setSelectedAgentUid}
          onChanged={() => setRestartRequired(true)}
        />
        <AgentDetailPanel
          agent={selectedAgent}
          adapters={adapters.data?.adapters ?? []}
          loading={agents.isPending || adapters.isPending}
          error={agents.error ?? adapters.error}
          onChanged={() => setRestartRequired(true)}
        />
      </section>
    </div>
  )
}

function ConsoleSidebar({
  section,
  onSectionChange
}: {
  section: ConsoleSection
  onSectionChange(section: ConsoleSection): void
}) {
  const [query, setQuery] = useState('')
  const groups = useMemo(() => filterNavGroups(query), [query])

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
                <span className="truncate text-xs text-sidebar-foreground/70">Console</span>
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
            placeholder="Search..."
            aria-label="Search navigation"
            className="pl-8"
          />
        </div>
      </SidebarHeader>
      <SidebarContent>
        {groups.map(group => (
          <SidebarGroup key={group.label}>
            <SidebarGroupLabel>{group.label}</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {group.items.map(item => (
                  <SidebarMenuItem key={item.slug}>
                    <SidebarMenuButton isActive={section === item.slug} onClick={() => onSectionChange(item.slug)}>
                      <item.icon />
                      <span>{item.title}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        ))}
        {groups.length === 0 ? (
          <p className="px-5 py-2 text-sm text-sidebar-foreground/60">No matches for "{query}".</p>
        ) : null}
      </SidebarContent>
      <SidebarFooter>
        <div className="px-3 py-2 text-xs text-sidebar-foreground/60">Single-installation operating console</div>
      </SidebarFooter>
      <SidebarRail />
    </Sidebar>
  )
}

function ConsoleSectionView({ section }: { section: ConsoleSection }) {
  if (section === 'overview') return <OverviewPage />
  if (section === 'agents' || section === 'channels') return <AgentOperationsPage />
  if (section === 'llm-providers') return <LlmProvidersPage />
  if (section === 'schedules') return <SchedulesPage />
  if (section === 'workers') return <WorkersPage />
  if (section === 'skills') return <SkillsPage />
  if (section === 'library') return <LibraryEntriesPage />
  if (section === 'people') return <PeoplePage />
  if (section === 'groups') return <GroupsPage />
  if (section === 'plugins') return <PluginsPage />
  return <SettingsPage />
}

function OverviewPage() {
  const overview = useQuery({
    queryKey: ['console-overview'],
    queryFn: () => unwrap(api.console.overview.get())
  })
  const data = overview.data?.overview

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader
        title="Overview"
        description="A console organized around operator stories: configure the workspace, operate agents, inspect runtime state, and keep audit records immutable."
      />
      {overview.error ? <ErrorAlert error={overview.error} title="Overview failed to load" /> : null}
      <section className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
        <MetricCard label="Agents" value={data?.counts.agents} />
        <MetricCard label="Chat channels" value={data?.counts.chatChannels} />
        <MetricCard label="Human users" value={data?.counts.humanUsers} />
        <MetricCard label="Principal groups" value={data?.counts.principalGroups} />
        <MetricCard label="Library skills" value={data?.counts.librarySkills} />
        <MetricCard label="Agent library entries" value={data?.counts.agentLibraryEntries} />
      </section>
      <section className="grid gap-4 lg:grid-cols-2">
        {(data?.resources ?? []).map(resource => (
          <Card key={resource.id} size="sm">
            <CardHeader>
              <CardTitle className="text-base">{resource.title}</CardTitle>
              <p className="text-sm text-muted-foreground">{resource.description}</p>
            </CardHeader>
            <CardContent className="flex flex-wrap gap-2">
              <Badge variant="outline">{resource.owner}</Badge>
              {resource.operations.map(operation => (
                <Badge key={operation} variant="secondary">
                  {operation}
                </Badge>
              ))}
            </CardContent>
          </Card>
        ))}
        {overview.isPending ? <SkeletonRows rows={4} /> : null}
      </section>
    </div>
  )
}

function LlmProvidersPage() {
  const queryClient = useQueryClient()
  const providers = useQuery({
    queryKey: ['console-llm-providers'],
    queryFn: () => unwrap(api.console['llm-providers'].get())
  })
  const [editingProviderId, setEditingProviderId] = useState<string | null>(null)
  const [providerId, setProviderId] = useState('')
  const [piProvider, setPiProvider] = useState('')
  const [baseUrl, setBaseUrl] = useState('')
  const [apiKey, setApiKey] = useState('')
  const [providerOptionsJson, setProviderOptionsJson] = useState('{}')
  const editingProvider = providers.data?.providers.find(provider => provider.providerId === editingProviderId)
  const create = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['llm-providers'].post({
          providerId,
          piProvider,
          baseUrl: baseUrl.trim() ? baseUrl : null,
          apiKey: apiKey.trim() ? apiKey : null,
          providerOptions: parseJsonObject(providerOptionsJson, 'provider options')
        })
      ),
    onSuccess: () => {
      setEditingProviderId(null)
      setProviderId('')
      setPiProvider('')
      setBaseUrl('')
      setApiKey('')
      setProviderOptionsJson('{}')
      queryClient.invalidateQueries({ queryKey: ['console-llm-providers'] })
    }
  })
  const update = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['llm-providers']({ providerId }).put({
          piProvider,
          baseUrl: baseUrl.trim() ? baseUrl : null,
          apiKey: apiKey.trim() ? apiKey : undefined,
          providerOptions: parseJsonObject(providerOptionsJson, 'provider options')
        })
      ),
    onSuccess: () => {
      setApiKey('')
      queryClient.invalidateQueries({ queryKey: ['console-llm-providers'] })
    }
  })
  const check = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['llm-providers'].check.post({
          providerId: providerId || undefined,
          piProvider: piProvider || undefined,
          baseUrl: baseUrl.trim() ? baseUrl : null,
          apiKey: apiKey.trim() ? apiKey : undefined,
          providerOptions: parseJsonObject(providerOptionsJson, 'provider options')
        })
      )
  })
  const remove = useMutation({
    mutationFn: (id: string) => unwrap(api.console['llm-providers']({ providerId: id }).delete()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-llm-providers'] })
  })

  useEffect(() => {
    if (!editingProvider) return
    setProviderId(editingProvider.providerId)
    setPiProvider(editingProvider.piProvider)
    setBaseUrl(editingProvider.baseUrl ?? '')
    setApiKey('')
    setProviderOptionsJson(JSON.stringify(editingProvider.providerOptions ?? {}, null, 2))
  }, [editingProvider])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader
        title="LLM Providers"
        description="Provider records are installation-level credentials; agents only reference provider/model profiles."
      />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">{editingProviderId ? 'Edit provider' : 'Create provider'}</CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-4"
            onSubmit={event => {
              event.preventDefault()
              editingProviderId ? update.mutate() : create.mutate()
            }}>
            <div className="grid gap-4 md:grid-cols-4">
              <Input
                placeholder="provider id"
                value={providerId}
                disabled={Boolean(editingProviderId)}
                onChange={event => setProviderId(event.target.value)}
              />
              <Select value={piProvider} onValueChange={value => setPiProvider(value ?? '')}>
                <SelectTrigger className="w-full">
                  <SelectValue placeholder="pi provider" />
                </SelectTrigger>
                <SelectContent>
                  {(providers.data?.piProviders ?? []).map(provider => (
                    <SelectItem key={provider.id} value={provider.id}>
                      {provider.id} ({provider.modelCount})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Input placeholder="base URL" value={baseUrl} onChange={event => setBaseUrl(event.target.value)} />
              <Input
                type="password"
                placeholder={editingProvider?.apiKey.present ? 'leave blank to keep saved key' : 'API key'}
                value={apiKey}
                onChange={event => setApiKey(event.target.value)}
              />
            </div>
            <Textarea
              value={providerOptionsJson}
              onChange={event => setProviderOptionsJson(event.target.value)}
              className="min-h-24 font-mono"
            />
            <div className="flex flex-wrap items-center gap-2">
              <Button
                type="submit"
                disabled={!providerId.trim() || !piProvider || create.isPending || update.isPending}>
                {create.isPending || update.isPending ? (
                  <Spinner />
                ) : editingProviderId ? (
                  <RiSaveLine />
                ) : (
                  <RiAddLine />
                )}
                {editingProviderId ? 'Save provider' : 'Create provider'}
              </Button>
              <Button
                type="button"
                variant="outline"
                disabled={!piProvider || check.isPending}
                onClick={() => check.mutate()}>
                {check.isPending ? <Spinner /> : <RiSparkling2Line />}
                Check
              </Button>
              <Button
                type="button"
                variant="ghost"
                onClick={() => {
                  setEditingProviderId(null)
                  setProviderId('')
                  setPiProvider('')
                  setBaseUrl('')
                  setApiKey('')
                  setProviderOptionsJson('{}')
                }}>
                Clear
              </Button>
            </div>
          </form>
          {check.data ? (
            <Alert>
              <AlertTitle>Provider check passed</AlertTitle>
              <AlertDescription>{check.data.provider.providerId}</AlertDescription>
            </Alert>
          ) : null}
          <ErrorAlert error={create.error ?? update.error ?? check.error} title="Provider operation failed" />
        </CardContent>
      </Card>
      <TableCard
        loading={providers.isPending}
        error={providers.error}
        empty={providers.data?.providers.length === 0}
        columns={['Provider', 'pi-ai', 'Base URL', 'API key', 'Actions']}>
        {(providers.data?.providers ?? []).map(provider => (
          <TableRow key={provider.providerId}>
            <TableCell className="font-mono text-xs">{provider.providerId}</TableCell>
            <TableCell>{provider.piProvider}</TableCell>
            <TableCell className="max-w-[280px] truncate">{provider.baseUrl ?? '-'}</TableCell>
            <TableCell>{provider.apiKey.present ? provider.apiKey.masked : '-'}</TableCell>
            <TableCell>
              <div className="flex justify-end gap-1">
                <Button variant="ghost" size="icon-xs" onClick={() => setEditingProviderId(provider.providerId)}>
                  <RiPencilLine />
                </Button>
                <Button
                  variant="ghost"
                  size="icon-xs"
                  disabled={remove.isPending}
                  onClick={() => {
                    if (window.confirm(`Delete provider ${provider.providerId}?`)) remove.mutate(provider.providerId)
                  }}>
                  <RiDeleteBinLine />
                </Button>
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}

function SchedulesPage() {
  const agents = useAgentsQuery()
  const queryClient = useQueryClient()
  const [selectedAgentUid, setSelectedAgentUid] = useState<string | null>(null)
  const selectedUid = selectedAgentUid ?? agents.data?.agents[0]?.uid ?? ''
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [message, setMessage] = useState('')
  const [taskEnabled, setTaskEnabled] = useState(true)
  const [scheduleJson, setScheduleJson] = useState('{"kind":"every","every_ms":3600000}')
  const [deliveryJson, setDeliveryJson] = useState('')
  const tasks = useQuery({
    queryKey: ['console-scheduled-tasks', selectedUid],
    enabled: Boolean(selectedUid),
    queryFn: () => unwrap(api.console.agents({ uid: selectedUid })['scheduled-tasks'].get())
  })
  const selectedTask = tasks.data?.tasks.find(task => task.id === selectedTaskId)
  const runs = useQuery({
    queryKey: ['console-scheduled-task-runs', selectedTaskId],
    enabled: Boolean(selectedTaskId),
    queryFn: () => unwrap(api.console['scheduled-tasks']({ taskId: selectedTaskId ?? '' }).runs.get())
  })
  const create = useMutation({
    mutationFn: () =>
      unwrap(
        api.console.agents({ uid: selectedUid })['scheduled-tasks'].post({
          name,
          enabled: true,
          schedule: parseScheduleJson(scheduleJson),
          payload: { message },
          delivery: deliveryJson.trim() ? parseDeliveryJson(deliveryJson) : null
        })
      ),
    onSuccess: result => {
      setName('')
      setMessage('')
      setTaskEnabled(true)
      setScheduleJson('{"kind":"every","every_ms":3600000}')
      setDeliveryJson('')
      setSelectedTaskId(result.task.id)
      queryClient.invalidateQueries({ queryKey: ['console-scheduled-tasks', selectedUid] })
    }
  })
  const update = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['scheduled-tasks']({ taskId: selectedTaskId ?? '' }).put({
          name,
          enabled: taskEnabled,
          schedule: parseScheduleJson(scheduleJson),
          payload: { message },
          delivery: deliveryJson.trim() ? parseDeliveryJson(deliveryJson) : null
        })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-scheduled-tasks', selectedUid] })
  })
  const toggle = useMutation({
    mutationFn: (input: { taskId: string; enabled: boolean }) =>
      unwrap(api.console['scheduled-tasks']({ taskId: input.taskId }).put({ enabled: input.enabled })),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-scheduled-tasks', selectedUid] })
  })
  const runNow = useMutation({
    mutationFn: (taskId: string) => unwrap(api.console['scheduled-tasks']({ taskId }).run.post()),
    onSuccess: (_, taskId) => {
      setSelectedTaskId(taskId)
      queryClient.invalidateQueries({ queryKey: ['console-scheduled-tasks', selectedUid] })
      queryClient.invalidateQueries({ queryKey: ['console-scheduled-task-runs', taskId] })
    }
  })
  const remove = useMutation({
    mutationFn: (taskId: string) => unwrap(api.console['scheduled-tasks']({ taskId }).delete()),
    onSuccess: (_, taskId) => {
      if (selectedTaskId === taskId) setSelectedTaskId(null)
      queryClient.invalidateQueries({ queryKey: ['console-scheduled-tasks', selectedUid] })
    }
  })

  useEffect(() => {
    if (!selectedAgentUid && agents.data?.agents[0]) setSelectedAgentUid(agents.data.agents[0].uid)
  }, [agents.data?.agents, selectedAgentUid])

  useEffect(() => {
    if (!selectedTask) return
    setName(selectedTask.name)
    setMessage(typeof selectedTask.payload.message === 'string' ? selectedTask.payload.message : '')
    setTaskEnabled(selectedTask.enabled)
    setScheduleJson(JSON.stringify(selectedTask.schedule, null, 2))
    setDeliveryJson(selectedTask.delivery ? JSON.stringify(selectedTask.delivery, null, 2) : '')
  }, [selectedTask])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader
        title="Schedules"
        description="Scheduled tasks are editable work definitions; scheduled task runs are immutable execution records."
      />
      <AgentSelector agents={agents.data?.agents ?? []} value={selectedUid} onChange={setSelectedAgentUid} />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">
            {selectedTaskId ? 'Edit scheduled task' : 'Create scheduled task'}
          </CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-4"
            onSubmit={event => {
              event.preventDefault()
              selectedTaskId ? update.mutate() : create.mutate()
            }}>
            <div className="grid gap-4 lg:grid-cols-[1fr_1fr_auto]">
              <Input placeholder="name" value={name} onChange={event => setName(event.target.value)} />
              <Input placeholder="message" value={message} onChange={event => setMessage(event.target.value)} />
              <div className="flex items-center justify-between gap-3 border border-border px-4 py-3">
                <span className="text-sm">Enabled</span>
                <Switch checked={taskEnabled} onCheckedChange={checked => setTaskEnabled(checked)} />
              </div>
            </div>
            <div className="grid gap-4 lg:grid-cols-2">
              <Textarea
                value={scheduleJson}
                onChange={event => setScheduleJson(event.target.value)}
                className="min-h-24 font-mono"
              />
              <Textarea
                placeholder='optional delivery JSON, e.g. {"binding_name":"lark","room_id":"..."}'
                value={deliveryJson}
                onChange={event => setDeliveryJson(event.target.value)}
                className="min-h-24 font-mono"
              />
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <Button
                type="submit"
                disabled={!selectedUid || !name.trim() || !message.trim() || create.isPending || update.isPending}>
                {create.isPending || update.isPending ? <Spinner /> : selectedTaskId ? <RiSaveLine /> : <RiAddLine />}
                {selectedTaskId ? 'Save task' : 'Create task'}
              </Button>
              <Button
                type="button"
                variant="ghost"
                onClick={() => {
                  setSelectedTaskId(null)
                  setName('')
                  setMessage('')
                  setTaskEnabled(true)
                  setScheduleJson('{"kind":"every","every_ms":3600000}')
                  setDeliveryJson('')
                }}>
                Clear
              </Button>
            </div>
          </form>
          <ErrorAlert error={create.error ?? update.error} title="Scheduled task save failed" />
        </CardContent>
      </Card>
      <TableCard
        loading={agents.isPending || tasks.isPending}
        error={agents.error ?? tasks.error}
        empty={(tasks.data?.tasks.length ?? 0) === 0}
        columns={['Name', 'Enabled', 'Schedule', 'Next run', 'Last status', 'Actions']}>
        {(tasks.data?.tasks ?? []).map(task => (
          <TableRow
            key={task.id}
            data-state={selectedTaskId === task.id ? 'selected' : undefined}
            className="cursor-pointer"
            onClick={() => setSelectedTaskId(task.id)}>
            <TableCell className="font-medium">{task.name}</TableCell>
            <TableCell>
              <Badge variant={task.enabled ? 'default' : 'secondary'}>{task.enabled ? 'enabled' : 'disabled'}</Badge>
            </TableCell>
            <TableCell className="font-mono text-xs">{formatJson(task.schedule)}</TableCell>
            <TableCell>{formatDate(task.nextRunAt)}</TableCell>
            <TableCell>{task.lastStatus ?? '-'}</TableCell>
            <TableCell>
              <div className="flex justify-end gap-2">
                <Button
                  size="sm"
                  variant="outline"
                  disabled={toggle.isPending}
                  onClick={event => {
                    event.stopPropagation()
                    toggle.mutate({ taskId: task.id, enabled: !task.enabled })
                  }}>
                  {task.enabled ? 'Disable' : 'Enable'}
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={runNow.isPending}
                  onClick={event => {
                    event.stopPropagation()
                    runNow.mutate(task.id)
                  }}>
                  Run now
                </Button>
                <Button
                  variant="ghost"
                  size="icon-xs"
                  disabled={remove.isPending}
                  onClick={event => {
                    event.stopPropagation()
                    if (window.confirm(`Delete scheduled task ${task.name}?`)) remove.mutate(task.id)
                  }}>
                  <RiDeleteBinLine />
                </Button>
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableCard>
      {selectedTaskId ? (
        <TableCard
          loading={runs.isPending}
          error={runs.error}
          empty={(runs.data?.runs.length ?? 0) === 0}
          columns={['Run', 'Status', 'Trigger', 'Started', 'Finished', 'Error']}>
          {(runs.data?.runs ?? []).map(run => (
            <TableRow key={run.id}>
              <TableCell className="font-mono text-xs">{run.id}</TableCell>
              <TableCell>
                <Badge
                  variant={
                    run.status === 'succeeded' ? 'default' : run.status === 'failed' ? 'destructive' : 'secondary'
                  }>
                  {run.status}
                </Badge>
              </TableCell>
              <TableCell>{run.trigger}</TableCell>
              <TableCell>{formatDate(run.startedAt)}</TableCell>
              <TableCell>{formatDate(run.finishedAt)}</TableCell>
              <TableCell className="max-w-[320px] truncate">{run.error ?? '-'}</TableCell>
            </TableRow>
          ))}
        </TableCard>
      ) : null}
    </div>
  )
}

function WorkersPage() {
  const agents = useAgentsQuery()
  const queryClient = useQueryClient()
  const [agentUid, setAgentUid] = useState('')
  const [workerId, setWorkerId] = useState('')
  const [reason, setReason] = useState('')
  const workers = useQuery({
    queryKey: ['console-computer-workers'],
    queryFn: () => unwrap(api.console.computer.workers.get())
  })
  const pin = useMutation({
    mutationFn: () =>
      unwrap(
        api.console.computer.pins.post({
          agentUid,
          workerId,
          reason: reason.trim() ? reason : null
        })
      ),
    onSuccess: () => {
      setReason('')
      queryClient.invalidateQueries({ queryKey: ['console-computer-workers'] })
    }
  })
  const unpin = useMutation({
    mutationFn: () => unwrap(api.console.computer.pins({ agentUid }).delete()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-computer-workers'] })
  })

  useEffect(() => {
    if (!agentUid && agents.data?.agents[0]) setAgentUid(agents.data.agents[0].uid)
  }, [agentUid, agents.data?.agents])

  useEffect(() => {
    if (!workerId && workers.data?.workers[0]) setWorkerId(workers.data.workers[0].workerId)
  }, [workerId, workers.data?.workers])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader
        title="Computer Workers"
        description="Workers self-register and heartbeat from the runtime. Pin important agents to dedicated workers when long-running browser sessions or Python package isolation matter."
      />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">Agent worker pin</CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-3 md:grid-cols-[1fr_1fr_1fr_auto_auto]"
            onSubmit={event => {
              event.preventDefault()
              pin.mutate()
            }}>
            <AgentSelector agents={agents.data?.agents ?? []} value={agentUid} onChange={setAgentUid} />
            <Select value={workerId} onValueChange={next => setWorkerId(next ?? workerId)}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder="Worker" />
              </SelectTrigger>
              <SelectContent>
                {(workers.data?.workers ?? []).map(worker => (
                  <SelectItem key={worker.workerId} value={worker.workerId}>
                    {worker.workerId}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Input placeholder="reason" value={reason} onChange={event => setReason(event.target.value)} />
            <Button type="submit" disabled={!agentUid || !workerId || pin.isPending}>
              {pin.isPending ? <Spinner /> : <RiSaveLine />}
              Pin
            </Button>
            <Button
              type="button"
              variant="outline"
              disabled={!agentUid || unpin.isPending}
              onClick={() => unpin.mutate()}>
              Remove pin
            </Button>
          </form>
          <ErrorAlert error={pin.error ?? unpin.error} title="Worker pin update failed" />
        </CardContent>
      </Card>
      <TableCard
        loading={workers.isPending}
        error={workers.error}
        empty={(workers.data?.workers.length ?? 0) === 0}
        columns={['Worker', 'Status', 'Base URL', 'Features', 'Heartbeat']}>
        {(workers.data?.workers ?? []).map(worker => (
          <TableRow key={worker.workerId}>
            <TableCell className="font-mono text-xs">{worker.workerId}</TableCell>
            <TableCell>
              <Badge variant={worker.status === 'ready' ? 'default' : 'secondary'}>{worker.status}</Badge>
            </TableCell>
            <TableCell className="max-w-[280px] truncate">{worker.baseUrl}</TableCell>
            <TableCell>{worker.features.join(', ') || '-'}</TableCell>
            <TableCell>{formatDate(worker.lastHeartbeatAt)}</TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}

function SkillsPage() {
  const agents = useAgentsQuery()
  const [selectedAgentUid, setSelectedAgentUid] = useState<string | null>(null)
  const selectedUid = selectedAgentUid ?? agents.data?.agents[0]?.uid ?? ''
  const librarySkills = useQuery({
    queryKey: ['console-library-skills'],
    queryFn: () => unwrap(api.console['library-skills'].get())
  })
  const agentSkills = useQuery({
    queryKey: ['console-agent-skills', selectedUid],
    enabled: Boolean(selectedUid),
    queryFn: () => unwrap(api.console.agents({ uid: selectedUid }).skills.get())
  })
  const queryClient = useQueryClient()
  const toggle = useMutation({
    mutationFn: (input: { skillName: string; enabled: boolean }) =>
      unwrap(
        api.console.agents({ uid: selectedUid }).skills({ skillName: input.skillName }).put({ enabled: input.enabled })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-agent-skills', selectedUid] })
  })
  const effectiveNames = new Set((agentSkills.data?.skills ?? []).map(skill => skill.name))

  useEffect(() => {
    if (!selectedAgentUid && agents.data?.agents[0]) setSelectedAgentUid(agents.data.agents[0].uid)
  }, [agents.data?.agents, selectedAgentUid])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader
        title="Skills"
        description="Canonical library skills are synced from app/internals. Assignment rows only override an agent's effective enablement."
      />
      <AgentSelector agents={agents.data?.agents ?? []} value={selectedUid} onChange={setSelectedAgentUid} />
      <TableCard
        loading={librarySkills.isPending || agentSkills.isPending}
        error={librarySkills.error ?? agentSkills.error}
        empty={(librarySkills.data?.skills.length ?? 0) === 0}
        columns={['Skill', 'Source', 'Default', 'Effective', 'Actions']}>
        {(librarySkills.data?.skills ?? []).map(skill => (
          <TableRow key={skill.id}>
            <TableCell>
              <div className="grid gap-1">
                <span className="font-medium">{skill.name}</span>
                <span className="text-xs text-muted-foreground">{skill.description}</span>
              </div>
            </TableCell>
            <TableCell>{skill.sourceKind}</TableCell>
            <TableCell>{skill.defaultEnabled ? 'on' : 'off'}</TableCell>
            <TableCell>
              <Badge variant={effectiveNames.has(skill.name) ? 'default' : 'secondary'}>
                {effectiveNames.has(skill.name) ? 'enabled' : 'disabled'}
              </Badge>
            </TableCell>
            <TableCell>
              <div className="flex justify-end gap-2">
                <Button
                  size="sm"
                  variant="outline"
                  disabled={!selectedUid || toggle.isPending}
                  onClick={() => toggle.mutate({ skillName: skill.name, enabled: !effectiveNames.has(skill.name) })}>
                  {effectiveNames.has(skill.name) ? 'Disable' : 'Enable'}
                </Button>
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}

function LibraryEntriesPage() {
  const agents = useAgentsQuery()
  const [selectedAgentUid, setSelectedAgentUid] = useState<string | null>(null)
  const selectedUid = selectedAgentUid ?? agents.data?.agents[0]?.uid ?? ''
  const entries = useQuery({
    queryKey: ['console-agent-library-entries', selectedUid],
    enabled: Boolean(selectedUid),
    queryFn: () => unwrap(api.console.agents({ uid: selectedUid })['library-entries'].get())
  })
  const soul = useQuery({
    queryKey: ['console-agent-soul', selectedUid],
    enabled: Boolean(selectedUid),
    queryFn: () => unwrap(api.console.agents({ uid: selectedUid }).soul.get())
  })
  const [content, setContent] = useState('')
  const queryClient = useQueryClient()
  const save = useMutation({
    mutationFn: () => unwrap(api.console.agents({ uid: selectedUid }).soul.put({ content })),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-agent-soul', selectedUid] })
  })

  useEffect(() => {
    if (!selectedAgentUid && agents.data?.agents[0]) setSelectedAgentUid(agents.data.agents[0].uid)
  }, [agents.data?.agents, selectedAgentUid])

  useEffect(() => {
    if (soul.data) setContent(soul.data.content ?? '')
  }, [soul.data])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader
        title="Library Entries"
        description="SOUL.md is an operator-owned agent file; other entries are inspected as generated or runtime-owned state."
      />
      <AgentSelector agents={agents.data?.agents ?? []} value={selectedUid} onChange={setSelectedAgentUid} />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">SOUL.md</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-3">
          <Textarea value={content} onChange={event => setContent(event.target.value)} className="min-h-56 font-mono" />
          <div className="flex items-center gap-2">
            <Button disabled={!selectedUid || save.isPending} onClick={() => save.mutate()}>
              {save.isPending ? <Spinner /> : <RiSaveLine />}
              Save
            </Button>
            <ErrorAlert error={save.error ?? soul.error} title="SOUL.md save failed" />
          </div>
        </CardContent>
      </Card>
      <TableCard
        loading={entries.isPending}
        error={entries.error}
        empty={(entries.data?.entries.length ?? 0) === 0}
        columns={['Path', 'Source', 'Enabled', 'Version', 'Updated']}>
        {(entries.data?.entries ?? []).map((entry: ConsoleAgentLibraryEntry) => (
          <TableRow key={entry.id}>
            <TableCell className="font-mono text-xs">{entry.virtualPath}</TableCell>
            <TableCell>{entry.sourceKind}</TableCell>
            <TableCell>{entry.enabled ? 'yes' : 'no'}</TableCell>
            <TableCell>{entry.version}</TableCell>
            <TableCell>{formatDate(entry.updatedAt)}</TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}

function PeoplePage() {
  const queryClient = useQueryClient()
  const humans = useQuery({
    queryKey: ['console-human-users'],
    queryFn: () => unwrap(api.console['human-users'].get())
  })
  const [uid, setUid] = useState('')
  const [displayName, setDisplayName] = useState('')
  const [email, setEmail] = useState('')
  const [phone, setPhone] = useState('')
  const [selectedHumanUid, setSelectedHumanUid] = useState<string | null>(null)
  const selectedHuman = humans.data?.humans.find(human => human.principal.uid === selectedHumanUid)
  const create = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['human-users'].post({
          uid,
          displayName: displayName.trim() ? displayName : null,
          email: email.trim() ? email : null,
          phone: phone.trim() ? phone : null
        })
      ),
    onSuccess: () => {
      setUid('')
      setDisplayName('')
      setEmail('')
      setPhone('')
      queryClient.invalidateQueries({ queryKey: ['console-human-users'] })
    }
  })
  const update = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['human-users']({ principalUid: selectedHumanUid ?? '' }).put({
          displayName: displayName.trim() ? displayName : null,
          email: email.trim() ? email : null,
          phone: phone.trim() ? phone : null,
          status: selectedHuman?.principal.status
        })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-human-users'] })
  })
  const toggle = useMutation({
    mutationFn: (human: ConsoleHumanUser) =>
      unwrap(
        api.console['human-users']({ principalUid: human.principal.uid }).put({
          status: human.principal.status === 'active' ? 'disabled' : 'active'
        })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-human-users'] })
  })

  useEffect(() => {
    if (!selectedHuman) return
    setUid(selectedHuman.principal.uid)
    setDisplayName(selectedHuman.principal.displayName ?? '')
    setEmail(selectedHuman.humanUser.email ?? '')
    setPhone(selectedHuman.humanUser.phone ?? '')
  }, [selectedHuman])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader
        title="People"
        description="Human user CRUD operates Principal/profile rows; login subjects and directory bindings remain separate identity-provider flows."
      />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">{selectedHumanUid ? 'Edit human profile' : 'Create local human'}</CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-3 md:grid-cols-[1fr_1fr_1fr_1fr_auto_auto]"
            onSubmit={event => {
              event.preventDefault()
              selectedHumanUid ? update.mutate() : create.mutate()
            }}>
            <Input
              placeholder="uid"
              value={uid}
              disabled={Boolean(selectedHumanUid)}
              onChange={event => setUid(event.target.value)}
            />
            <Input
              placeholder="display name"
              value={displayName}
              onChange={event => setDisplayName(event.target.value)}
            />
            <Input placeholder="email" value={email} onChange={event => setEmail(event.target.value)} />
            <Input placeholder="phone (+E.164)" value={phone} onChange={event => setPhone(event.target.value)} />
            <Button type="submit" disabled={!uid.trim() || create.isPending || update.isPending}>
              {create.isPending || update.isPending ? <Spinner /> : selectedHumanUid ? <RiSaveLine /> : <RiAddLine />}
              {selectedHumanUid ? 'Save' : 'Create'}
            </Button>
            <Button
              type="button"
              variant="ghost"
              onClick={() => {
                setSelectedHumanUid(null)
                setUid('')
                setDisplayName('')
                setEmail('')
                setPhone('')
              }}>
              Clear
            </Button>
          </form>
          <ErrorAlert error={create.error ?? update.error} title="Human save failed" />
        </CardContent>
      </Card>
      <TableCard
        loading={humans.isPending}
        error={humans.error}
        empty={(humans.data?.humans.length ?? 0) === 0}
        columns={['UID', 'Name', 'Email', 'Status', 'Actions']}>
        {(humans.data?.humans ?? []).map(human => (
          <TableRow key={human.principal.uid}>
            <TableCell className="font-mono text-xs">{human.principal.uid}</TableCell>
            <TableCell>{human.principal.displayName ?? '-'}</TableCell>
            <TableCell>{human.humanUser.email ?? '-'}</TableCell>
            <TableCell>
              <Badge variant={human.principal.status === 'active' ? 'default' : 'secondary'}>
                {human.principal.status}
              </Badge>
            </TableCell>
            <TableCell>
              <div className="flex justify-end gap-2">
                <Button size="sm" variant="outline" onClick={() => setSelectedHumanUid(human.principal.uid)}>
                  Edit
                </Button>
                <Button size="sm" variant="outline" disabled={toggle.isPending} onClick={() => toggle.mutate(human)}>
                  {human.principal.status === 'active' ? 'Disable' : 'Activate'}
                </Button>
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}

function GroupsPage() {
  const queryClient = useQueryClient()
  const groups = useQuery({
    queryKey: ['console-principal-groups'],
    queryFn: () => unwrap(api.console['principal-groups'].get())
  })
  const [selectedGroupId, setSelectedGroupId] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [kind, setKind] = useState<'static' | 'computed'>('static')
  const [description, setDescription] = useState('')
  const [computedCondition, setComputedCondition] = useState('')
  const selectedGroup = groups.data?.groups.find(group => group.id === selectedGroupId)
  const create = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['principal-groups'].post({
          name,
          kind,
          description: description.trim() ? description : null,
          computedCondition: kind === 'computed' ? computedCondition : null
        })
      ),
    onSuccess: () => {
      setName('')
      setDescription('')
      setComputedCondition('')
      queryClient.invalidateQueries({ queryKey: ['console-principal-groups'] })
    }
  })
  const update = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['principal-groups']({ id: selectedGroupId ?? '' }).put({
          description: description.trim() ? description : null,
          computedCondition: selectedGroup?.kind === 'computed' ? computedCondition : null
        })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-principal-groups'] })
  })
  const remove = useMutation({
    mutationFn: (id: string) => unwrap(api.console['principal-groups']({ id }).delete()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-principal-groups'] })
  })

  useEffect(() => {
    if (!selectedGroup) return
    setName(selectedGroup.name)
    setKind(selectedGroup.kind)
    setDescription(selectedGroup.description ?? '')
    setComputedCondition(selectedGroup.computedCondition ?? '')
  }, [selectedGroup])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader
        title="Groups"
        description="Static groups own explicit memberships; computed groups evaluate a CEL condition at authorization time."
      />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">{selectedGroupId ? 'Edit group' : 'Create group'}</CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-3"
            onSubmit={event => {
              event.preventDefault()
              selectedGroupId ? update.mutate() : create.mutate()
            }}>
            <div className="grid gap-3 md:grid-cols-[1fr_160px_2fr]">
              <Input
                placeholder="name"
                value={name}
                disabled={Boolean(selectedGroupId)}
                onChange={event => setName(event.target.value)}
              />
              <Select
                value={kind}
                disabled={Boolean(selectedGroupId)}
                onValueChange={value => setKind((value as 'static' | 'computed') ?? 'static')}>
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="static">static</SelectItem>
                  <SelectItem value="computed">computed</SelectItem>
                </SelectContent>
              </Select>
              <Input
                placeholder="description"
                value={description}
                onChange={event => setDescription(event.target.value)}
              />
            </div>
            <Input
              placeholder="computed condition"
              disabled={kind === 'static'}
              value={computedCondition}
              onChange={event => setComputedCondition(event.target.value)}
            />
            <div className="flex flex-wrap items-center gap-2">
              <Button type="submit" disabled={!name.trim() || create.isPending || update.isPending}>
                {create.isPending || update.isPending ? <Spinner /> : selectedGroupId ? <RiSaveLine /> : <RiAddLine />}
                {selectedGroupId ? 'Save group' : 'Create group'}
              </Button>
              <Button
                type="button"
                variant="ghost"
                onClick={() => {
                  setSelectedGroupId(null)
                  setName('')
                  setKind('static')
                  setDescription('')
                  setComputedCondition('')
                }}>
                Clear
              </Button>
            </div>
          </form>
          <ErrorAlert error={create.error ?? update.error} title="Group save failed" />
        </CardContent>
      </Card>
      <TableCard
        loading={groups.isPending}
        error={groups.error}
        empty={(groups.data?.groups.length ?? 0) === 0}
        columns={['Name', 'Kind', 'Built in', 'Members', 'Description', 'Actions']}>
        {(groups.data?.groups ?? []).map((group: ConsolePrincipalGroup) => (
          <TableRow key={group.id}>
            <TableCell className="font-medium">{group.name}</TableCell>
            <TableCell>{group.kind}</TableCell>
            <TableCell>{group.builtIn ? 'yes' : 'no'}</TableCell>
            <TableCell>{group.membershipCount}</TableCell>
            <TableCell className="max-w-[280px] truncate">{group.description ?? '-'}</TableCell>
            <TableCell>
              <div className="flex justify-end gap-2">
                <Button size="sm" variant="outline" onClick={() => setSelectedGroupId(group.id)}>
                  Edit
                </Button>
                <Button
                  variant="ghost"
                  size="icon-xs"
                  disabled={group.builtIn || remove.isPending}
                  onClick={() => {
                    if (window.confirm(`Delete group ${group.name}?`)) remove.mutate(group.id)
                  }}>
                  <RiDeleteBinLine />
                </Button>
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}

function PluginsPage() {
  const adapters = useAdaptersQuery()
  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader
        title="Plugins"
        description="This view starts from externally visible adapter capabilities instead of exposing plugin internals as mutable rows."
      />
      <TableCard
        loading={adapters.isPending}
        error={adapters.error}
        empty={(adapters.data?.adapters.length ?? 0) === 0}
        columns={['Adapter', 'Plugin', 'Interactive config']}>
        {(adapters.data?.adapters ?? []).map(adapter => (
          <TableRow key={adapter.id}>
            <TableCell className="font-mono text-xs">{adapter.id}</TableCell>
            <TableCell>{adapter.pluginId}</TableCell>
            <TableCell>{adapter.interactiveConfig ? 'yes' : 'no'}</TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}

function SettingsPage() {
  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader
        title="Settings"
        description="Installation-level settings belong here once the console has explicit operator stories for them."
      />
      <Empty className="border border-dashed border-border p-8">
        <EmptyHeader>
          <EmptyMedia variant="icon">
            <RiSettings3Line />
          </EmptyMedia>
          <EmptyTitle>No editable settings in this pass</EmptyTitle>
          <EmptyDescription>
            Existing setup and channel configuration flows stay in their dedicated sections.
          </EmptyDescription>
        </EmptyHeader>
      </Empty>
    </div>
  )
}

function SectionHeader({ title, description }: { title: string; description: string }) {
  return (
    <header className="flex flex-col gap-1">
      <h1 className="font-heading text-2xl leading-8">{title}</h1>
      <p className="max-w-3xl text-sm text-muted-foreground">{description}</p>
    </header>
  )
}

function MetricCard({ label, value }: { label: string; value: number | undefined }) {
  return (
    <Card size="sm">
      <CardContent className="flex flex-col gap-2">
        <span className="text-xs font-medium tracking-wider text-muted-foreground uppercase">{label}</span>
        {value === undefined ? (
          <Skeleton className="h-7 w-16" />
        ) : (
          <span className="text-2xl font-semibold">{value}</span>
        )}
      </CardContent>
    </Card>
  )
}

function TableCard({
  loading,
  error,
  empty,
  columns,
  children
}: {
  loading: boolean
  error: unknown
  empty: boolean
  columns: string[]
  children: ReactNode
}) {
  if (loading) return <SkeletonRows rows={5} />
  if (error) return <ErrorAlert error={error} title="Resource failed to load" />
  if (empty) {
    return (
      <Empty className="border border-dashed border-border p-8">
        <EmptyHeader>
          <EmptyMedia variant="icon">
            <RiDashboardLine />
          </EmptyMedia>
          <EmptyTitle>No records</EmptyTitle>
        </EmptyHeader>
      </Empty>
    )
  }

  return (
    <div className="border border-border bg-card">
      <Table>
        <TableHeader>
          <TableRow>
            {columns.map((column, index) => (
              <TableHead
                key={column}
                className={index === columns.length - 1 && column === 'Actions' ? 'text-right' : undefined}>
                {column}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>{children}</TableBody>
      </Table>
    </div>
  )
}

function AgentSelector({
  agents,
  value,
  onChange
}: {
  agents: ConsoleAgent[]
  value: string
  onChange(uid: string): void
}) {
  return (
    <div className="flex max-w-sm flex-col gap-2">
      <span className="text-xs font-medium tracking-wider text-muted-foreground uppercase">Agent</span>
      <Select value={value} onValueChange={next => onChange(next ?? value)}>
        <SelectTrigger className="w-full">
          <SelectValue placeholder="Select agent" />
        </SelectTrigger>
        <SelectContent>
          {agents.map(agent => (
            <SelectItem key={agent.uid} value={agent.uid}>
              {agent.uid}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  )
}

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

function sectionFromLocation(): ConsoleSection {
  const slug = window.location.pathname.replace(/^\/console\/?/, '').split('/')[0] || 'overview'
  return isConsoleSection(slug) ? slug : 'overview'
}

function isConsoleSection(value: string): value is ConsoleSection {
  return NAV_ITEMS.some(item => item.slug === value)
}

function filterNavGroups(query: string): NavGroup[] {
  const needle = query.trim().toLowerCase()
  if (!needle) return NAV_GROUPS
  return NAV_GROUPS.map(group => ({
    ...group,
    items: group.items.filter(
      item => item.title.toLowerCase().includes(needle) || item.description.toLowerCase().includes(needle)
    )
  })).filter(group => group.items.length > 0)
}

function readSidebarCookie(): boolean {
  const match = document.cookie.match(/(?:^|;\s*)sidebar_state=(true|false)/)
  return match ? match[1] === 'true' : true
}

function formatDate(value: Date | string | null | undefined): string {
  if (!value) return '-'
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.getTime())) return '-'
  return date.toLocaleString()
}

function formatJson(value: unknown): string {
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

function parseJsonObject(value: string, label: string): JsonObject {
  const parsed = JSON.parse(value) as unknown
  if (!isJsonObject(parsed)) throw new Error(`${label} must be a JSON object`)
  return parsed
}

function parseScheduleJson(value: string): ScheduledTaskSchedule {
  return parseJsonObject(value, 'schedule') as unknown as ScheduledTaskSchedule
}

function parseDeliveryJson(value: string): ScheduledTaskDeliveryInput {
  const delivery = parseJsonObject(value, 'delivery') as unknown as ScheduledTaskDeliveryInput
  if (delivery.thread_id === null) delete (delivery as { thread_id?: unknown }).thread_id
  return delivery
}

function parseAiAgentModelsJson(value: string): AiAgentModelsConfig {
  return parseJsonObject(value, 'AI agent models') as unknown as AiAgentModelsConfig
}

function AgentListPanel({
  agents,
  loading,
  error,
  selectedAgentUid,
  onSelect,
  onChanged
}: {
  agents: ConsoleAgent[]
  loading: boolean
  error: unknown
  selectedAgentUid: string | null
  onSelect(uid: string): void
  onChanged(): void
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [uid, setUid] = useState('')
  const create = useMutation({
    mutationFn: () => unwrap(api.console.agents.post({ uid })),
    onSuccess: result => {
      setUid('')
      onSelect(result.agent.uid)
      onChanged()
      queryClient.invalidateQueries({ queryKey: ['console-agents'] })
    }
  })
  const remove = useMutation({
    mutationFn: (agentUid: string) => unwrap(api.console.agents({ uid: agentUid }).delete()),
    onSuccess: () => {
      onChanged()
      queryClient.invalidateQueries({ queryKey: ['console-agents'] })
    }
  })

  return (
    <Card className="h-fit rounded-none">
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <RiRobot2Line className="size-4" />
          {t('console.agents.title')}
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-5">
        <form
          className="grid gap-3"
          onSubmit={event => {
            event.preventDefault()
            create.mutate()
          }}>
          <Field>
            <FieldLabel>{t('console.agents.uid_label')}</FieldLabel>
            <Input value={uid} autoComplete="off" onChange={event => setUid(event.target.value)} />
          </Field>
          <ErrorAlert error={create.error} title={t('console.agents.create_failed')} />
          <Button type="submit" disabled={!uid.trim() || create.isPending}>
            {create.isPending ? <Spinner /> : <RiAddLine />}
            {t('console.agents.create')}
          </Button>
        </form>

        {loading ? (
          <SkeletonRows rows={4} />
        ) : error ? (
          <ErrorAlert error={error} title={t('console.agents.load_failed')} />
        ) : agents.length === 0 ? (
          <Empty className="border border-dashed border-border p-8">
            <EmptyHeader>
              <EmptyMedia variant="icon">
                <RiRobot2Line />
              </EmptyMedia>
              <EmptyTitle>{t('console.agents.empty_title')}</EmptyTitle>
            </EmptyHeader>
          </Empty>
        ) : (
          <div className="border border-border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('console.agents.uid_label')}</TableHead>
                  <TableHead>{t('console.channels.title')}</TableHead>
                  <TableHead className="text-right">{t('console.actions')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {agents.map(agent => (
                  <TableRow
                    key={agent.uid}
                    data-state={selectedAgentUid === agent.uid ? 'selected' : undefined}
                    onClick={() => onSelect(agent.uid)}
                    className="cursor-pointer">
                    <TableCell className="font-mono text-xs text-foreground">{agent.uid}</TableCell>
                    <TableCell>{agent.chatChannels.length}</TableCell>
                    <TableCell>
                      <div className="flex justify-end">
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon-xs"
                          aria-label={t('console.agents.delete')}
                          disabled={remove.isPending}
                          onClick={event => {
                            event.stopPropagation()
                            if (window.confirm(t('console.agents.delete_confirm', { uid: agent.uid }))) {
                              remove.mutate(agent.uid)
                            }
                          }}>
                          <RiDeleteBinLine />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function AgentDetailPanel({
  agent,
  adapters,
  loading,
  error,
  onChanged
}: {
  agent: ConsoleAgent | null
  adapters: ConsoleExternalGatewayAdapter[]
  loading: boolean
  error: unknown
  onChanged(): void
}) {
  const { t } = useTranslation()
  const [editing, setEditing] = useState<ConsoleChatChannel | 'new' | null>(null)
  const queryClient = useQueryClient()
  const [displayName, setDisplayName] = useState('')
  const [avatarUrl, setAvatarUrl] = useState('')
  const [modelsJson, setModelsJson] = useState('')
  const saveProfile = useMutation({
    mutationFn: () =>
      unwrap(
        api.console.agents({ uid: agent?.uid ?? '' }).put({
          displayName: displayName.trim() ? displayName : null,
          avatarUrl: avatarUrl.trim() ? avatarUrl : null,
          llmProfile: modelsJson.trim() ? { models: parseAiAgentModelsJson(modelsJson) } : undefined
        })
      ),
    onSuccess: () => {
      onChanged()
      queryClient.invalidateQueries({ queryKey: ['console-agents'] })
    }
  })

  useEffect(() => {
    setEditing(null)
  }, [agent?.uid])

  useEffect(() => {
    setDisplayName(agent?.displayName ?? '')
    setAvatarUrl(agent?.avatarUrl ?? '')
    setModelsJson(agent?.llmProfile ? JSON.stringify(agent.llmProfile.models, null, 2) : '')
  }, [agent?.uid, agent?.displayName, agent?.avatarUrl, agent?.llmProfile])

  if (loading) {
    return (
      <Card className="rounded-none">
        <CardContent className="pt-6">
          <SkeletonRows rows={8} />
        </CardContent>
      </Card>
    )
  }

  if (error) {
    return (
      <Card className="rounded-none">
        <CardContent className="pt-6">
          <ErrorAlert error={error} title={t('console.agents.load_failed')} />
        </CardContent>
      </Card>
    )
  }

  if (!agent) {
    return (
      <Empty className="border border-dashed border-border">
        <EmptyHeader>
          <EmptyMedia variant="icon">
            <RiRobot2Line />
          </EmptyMedia>
          <EmptyTitle>{t('console.agents.empty_title')}</EmptyTitle>
          <EmptyDescription>{t('console.agents.empty_body')}</EmptyDescription>
        </EmptyHeader>
      </Empty>
    )
  }

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <Card className="rounded-none">
        <CardHeader>
          <CardTitle className="text-base">Agent profile and LLM</CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-5"
            onSubmit={event => {
              event.preventDefault()
              saveProfile.mutate()
            }}>
            <div className="grid gap-4 md:grid-cols-2">
              <Field>
                <FieldLabel>Display name</FieldLabel>
                <Input value={displayName} onChange={event => setDisplayName(event.target.value)} />
              </Field>
              <Field>
                <FieldLabel>Avatar URL</FieldLabel>
                <Input value={avatarUrl} onChange={event => setAvatarUrl(event.target.value)} />
              </Field>
            </div>
            <Field>
              <FieldLabel>LLM model profile JSON</FieldLabel>
              <Textarea
                value={modelsJson}
                onChange={event => setModelsJson(event.target.value)}
                placeholder='{"primary":{"providerId":"openrouter","model":"openai/gpt-4.1"}}'
                className="min-h-40 font-mono"
              />
              <FieldDescription>
                Configure primary/light/heavy model refs. Empty preserves the current model profile.
              </FieldDescription>
            </Field>
            <div className="flex items-center gap-3">
              <Button type="submit" disabled={saveProfile.isPending}>
                {saveProfile.isPending ? <Spinner /> : <RiSaveLine />}
                Save profile
              </Button>
              <ErrorAlert error={saveProfile.error} title="Agent profile save failed" />
            </div>
          </form>
        </CardContent>
      </Card>

      <Card className="rounded-none">
        <CardHeader>
          <CardTitle className="flex min-w-0 items-center justify-between gap-3">
            <span className="truncate font-mono text-base">{agent.uid}</span>
            <Badge variant="outline">{agent.status}</Badge>
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <h2 className="text-sm font-semibold">{t('console.channels.title')}</h2>
            <Button type="button" size="sm" onClick={() => setEditing('new')}>
              <RiAddLine />
              {t('console.channels.add')}
            </Button>
          </div>
          <ChannelsTable agent={agent} onEdit={setEditing} onChanged={onChanged} />
        </CardContent>
      </Card>

      {editing ? (
        <ChannelForm
          key={editing === 'new' ? `new-${agent.uid}` : `${agent.uid}-${editing.name}`}
          agent={agent}
          adapters={adapters}
          channel={editing === 'new' ? undefined : editing}
          onClose={() => setEditing(null)}
          onChanged={onChanged}
        />
      ) : null}
    </div>
  )
}

function ChannelsTable({
  agent,
  onEdit,
  onChanged
}: {
  agent: ConsoleAgent
  onEdit(channel: ConsoleChatChannel): void
  onChanged(): void
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const remove = useMutation({
    mutationFn: (channelName: string) =>
      unwrap(api.console.agents({ uid: agent.uid })['chat-channels']({ channelName }).delete()),
    onSuccess: () => {
      onChanged()
      queryClient.invalidateQueries({ queryKey: ['console-agents'] })
    }
  })

  if (agent.chatChannels.length === 0) {
    return (
      <Empty className="border border-dashed border-border p-8">
        <EmptyHeader>
          <EmptyMedia variant="icon">
            <RiPlugLine />
          </EmptyMedia>
          <EmptyTitle>{t('console.channels.empty_title')}</EmptyTitle>
        </EmptyHeader>
      </Empty>
    )
  }

  return (
    <div className="border border-border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>{t('console.channels.name')}</TableHead>
            <TableHead>{t('console.channels.adapter')}</TableHead>
            <TableHead>{t('console.channels.enabled')}</TableHead>
            <TableHead>{t('console.channels.status')}</TableHead>
            <TableHead className="text-right">{t('console.actions')}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {agent.chatChannels.map(channel => (
            <TableRow key={channel.name}>
              <TableCell className="font-mono text-xs text-foreground">{channel.name}</TableCell>
              <TableCell>{channel.adapter}</TableCell>
              <TableCell>
                <Badge variant={channel.enabled ? 'default' : 'secondary'}>
                  {t(channel.enabled ? 'console.enabled' : 'console.disabled')}
                </Badge>
              </TableCell>
              <TableCell>
                <Badge variant={channel.adapterInstalled ? 'outline' : 'destructive'}>
                  {t(channel.adapterInstalled ? 'console.channels.configured' : 'console.channels.adapter_missing')}
                </Badge>
              </TableCell>
              <TableCell>
                <div className="flex justify-end gap-1">
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-xs"
                    aria-label={t('console.channels.edit')}
                    onClick={() => onEdit(channel)}>
                    <RiPencilLine />
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-xs"
                    aria-label={t('console.channels.delete')}
                    disabled={remove.isPending}
                    onClick={() => {
                      if (window.confirm(t('console.channels.delete_confirm', { name: channel.name }))) {
                        remove.mutate(channel.name)
                      }
                    }}>
                    <RiDeleteBinLine />
                  </Button>
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  )
}

function ChannelForm({
  agent,
  adapters,
  channel,
  onClose,
  onChanged
}: {
  agent: ConsoleAgent
  adapters: ConsoleExternalGatewayAdapter[]
  channel?: ConsoleChatChannel
  onClose(): void
  onChanged(): void
}) {
  const { i18n, t } = useTranslation()
  const queryClient = useQueryClient()
  const [adapterId, setAdapterId] = useState(channel?.adapter ?? adapters[0]?.id ?? '')
  const adapter = adapters.find(item => item.id === adapterId)
  const [name, setName] = useState(channel?.name ?? adapter?.setup?.defaultChannelName ?? adapter?.id ?? '')
  const [enabled, setEnabled] = useState(channel?.enabled ?? true)
  const [config, setConfig] = useState<JsonObject>(() =>
    channel ? cloneJsonObject(channel.config) : defaultConfigForAdapter(adapter)
  )

  useEffect(() => {
    if (!channel && adapter) {
      setName(adapter.setup?.defaultChannelName ?? adapter.id)
      setConfig(defaultConfigForAdapter(adapter))
    }
  }, [adapter?.id, channel])

  const save = useMutation({
    mutationFn: () => {
      const body = {
        name,
        adapter: adapterId,
        enabled,
        config
      }
      if (channel) {
        return unwrap(api.console.agents({ uid: agent.uid })['chat-channels']({ channelName: channel.name }).put(body))
      }
      return unwrap(api.console.agents({ uid: agent.uid })['chat-channels'].post(body))
    },
    onSuccess: () => {
      onChanged()
      queryClient.invalidateQueries({ queryKey: ['console-agents'] })
      onClose()
    }
  })

  const interactive = useInteractiveConfig(adapter, config, i18n.language, values => {
    setConfig(current => mergeJsonRecords(current, values))
  })

  if (!adapter) {
    return (
      <Alert variant="destructive">
        <AlertTitle>{t('console.channels.adapter_missing')}</AlertTitle>
      </Alert>
    )
  }

  return (
    <Card className="rounded-none">
      <CardHeader>
        <CardTitle>{channel ? t('console.channels.edit') : t('console.channels.add')}</CardTitle>
      </CardHeader>
      <CardContent>
        <form
          className="flex flex-col gap-6"
          onSubmit={event => {
            event.preventDefault()
            save.mutate()
          }}>
          <ErrorAlert error={save.error} title={t('console.channels.save_failed')} />

          <div className="grid gap-5 md:grid-cols-2">
            <Field>
              <FieldLabel>{t('console.channels.name')}</FieldLabel>
              <Input value={name} disabled={Boolean(channel)} onChange={event => setName(event.target.value)} />
            </Field>
            <Field>
              <FieldLabel>{t('console.channels.adapter')}</FieldLabel>
              <Select
                value={adapterId}
                disabled={Boolean(channel)}
                onValueChange={value => setAdapterId(value ?? adapterId)}>
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {adapters.map(item => (
                    <SelectItem key={item.id} value={item.id}>
                      {adapterLabel(item, i18n.language)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
          </div>

          <div className="flex items-center justify-between gap-3 border border-border bg-card px-4 py-3">
            <span className="text-sm">{t('console.channels.enabled')}</span>
            <Switch checked={enabled} onCheckedChange={checked => setEnabled(checked)} />
          </div>

          <FieldGroup className="grid gap-5 md:grid-cols-2">
            {(adapter.setup?.fields ?? []).map(field => (
              <ConfigField
                key={field.path.join('.')}
                field={field}
                locale={i18n.language}
                value={getPath(config, field.path)}
                onChange={value => setConfig(current => setPath(current, field.path, value))}
              />
            ))}
          </FieldGroup>

          {adapter.interactiveConfig ? (
            <div className="flex flex-col gap-3 border border-border p-4">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div className="grid gap-1">
                  <span className="text-sm font-medium">
                    {resolveBullXPluginLocalizedText(
                      adapter.setup?.interactiveConfig?.displayName,
                      i18n.language,
                      t('console.channels.interactive_config')
                    )}
                  </span>
                  {adapter.setup?.interactiveConfig?.description ? (
                    <span className="text-xs text-muted-foreground">
                      {resolveBullXPluginLocalizedText(adapter.setup.interactiveConfig.description, i18n.language)}
                    </span>
                  ) : null}
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  <Button type="button" variant="outline" disabled={interactive.running} onClick={interactive.start}>
                    {interactive.running ? <Spinner /> : <RiPlugLine />}
                    {t('console.channels.start_interactive_config')}
                  </Button>
                  {interactive.session ? (
                    <Button type="button" variant="ghost" onClick={interactive.cancel}>
                      {t('console.cancel')}
                    </Button>
                  ) : null}
                </div>
              </div>
              {interactive.session ? (
                <Alert variant={interactive.session.state === 'failed' ? 'destructive' : 'default'}>
                  <AlertTitle>
                    {resolveBullXPluginLocalizedText(
                      interactive.session.status,
                      i18n.language,
                      t(`console.interactive.${interactive.session.state}`)
                    )}
                  </AlertTitle>
                  {interactive.session.html ? (
                    <AlertDescription>
                      <div
                        className="prose prose-sm max-w-none break-words text-sm"
                        dangerouslySetInnerHTML={{ __html: interactive.session.html }}
                      />
                    </AlertDescription>
                  ) : null}
                  {interactive.session.error ? <AlertDescription>{interactive.session.error}</AlertDescription> : null}
                </Alert>
              ) : null}
            </div>
          ) : null}

          <div className="flex flex-wrap items-center gap-3 border-t border-border pt-5">
            <Button type="submit" disabled={save.isPending}>
              {save.isPending ? <Spinner /> : <RiSaveLine />}
              {t('console.save')}
            </Button>
            <Button type="button" variant="ghost" onClick={onClose}>
              {t('console.cancel')}
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  )
}

function ConfigField({
  field,
  locale,
  value,
  onChange
}: {
  field: SetupField
  locale: string
  value: JsonValue | undefined
  onChange(value: JsonValue): void
}) {
  const label = resolveBullXPluginLocalizedText(field.label, locale, field.path.join('.'))
  const description = resolveBullXPluginLocalizedText(field.description, locale)

  if (field.type === 'checkbox') {
    return (
      <Field orientation="horizontal" className="items-center justify-between border border-border p-4">
        <div className="grid gap-1">
          <FieldLabel>{label}</FieldLabel>
          {description ? <FieldDescription>{description}</FieldDescription> : null}
        </div>
        <Switch checked={Boolean(value)} onCheckedChange={checked => onChange(checked)} />
      </Field>
    )
  }

  if (field.type === 'select') {
    return (
      <Field>
        <FieldLabel>{label}</FieldLabel>
        <Select value={typeof value === 'string' ? value : ''} onValueChange={next => onChange(next ?? '')}>
          <SelectTrigger className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {(field.options ?? []).map(option => (
              <SelectItem key={option.value} value={option.value}>
                {resolveBullXPluginLocalizedText(option.label, locale, option.value)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        {description ? <FieldDescription>{description}</FieldDescription> : null}
      </Field>
    )
  }

  /*
   * Secret fields come back from the API as presence markers, never plaintext.
   * Leaving the input empty preserves the existing encrypted value on save.
   */
  const secretPresent = isJsonObject(value) && value.present === true
  return (
    <Field>
      <FieldLabel>{label}</FieldLabel>
      <Input
        type={field.type === 'password' ? 'password' : field.type === 'number' ? 'number' : 'text'}
        value={secretPresent || value == null || isJsonObject(value) ? '' : String(value)}
        placeholder={secretPresent ? 'saved' : undefined}
        autoComplete={field.type === 'password' ? 'new-password' : 'off'}
        onChange={event => onChange(field.type === 'number' ? Number(event.target.value) : event.target.value)}
      />
      {description ? <FieldDescription>{description}</FieldDescription> : null}
    </Field>
  )
}

function useInteractiveConfig(
  adapter: ConsoleExternalGatewayAdapter | undefined,
  config: JsonObject,
  locale: string,
  onValues: (values: JsonObject) => void
) {
  /*
   * The session id is the client-side owner of a server-side interactive flow.
   * Clearing it hides stale session UI and triggers the cleanup effect below,
   * which aborts provider work such as a pending QR-code registration.
   */
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [appliedSessionId, setAppliedSessionId] = useState<string | null>(null)
  const startMutation = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['interactive-config-sessions'].post({
          adapterId: adapter?.id ?? '',
          currentConfig: config,
          locale
        })
      ),
    onSuccess: result => {
      setAppliedSessionId(null)
      setSessionId(result.session.sessionId)
    }
  })
  const session = useQuery({
    queryKey: ['console-interactive-config-session', sessionId],
    enabled: Boolean(sessionId),
    queryFn: () => unwrap(api.console['interactive-config-sessions']({ sessionId: sessionId ?? '' }).get()),
    refetchInterval: query => (query.state.data?.session.state === 'running' ? 1000 : false)
  })

  useEffect(() => {
    if (!sessionId) return

    return () => {
      // The API treats DELETE as idempotent, so this cleanup covers explicit
      // cancel, switching adapter/forms, and unmounting the channel editor.
      void unwrap(api.console['interactive-config-sessions']({ sessionId }).delete()).catch(() => {})
    }
  }, [sessionId])

  useEffect(() => {
    const data = session.data?.session
    if (!data || data.state !== 'succeeded' || !data.values || appliedSessionId === data.sessionId) return

    /*
     * Interactive config only patches the visible form. The operator still saves
     * the channel explicitly, which keeps review/restart behavior identical to a
     * manually typed config.
     */
    onValues(data.values)
    setAppliedSessionId(data.sessionId)
  }, [appliedSessionId, onValues, session.data?.session])

  return {
    running: startMutation.isPending || session.data?.session.state === 'running',
    session: sessionId ? (session.data?.session ?? startMutation.data?.session) : undefined,
    start: () => startMutation.mutate(),
    cancel: () => {
      setSessionId(null)
      setAppliedSessionId(null)
    }
  }
}

function useAgentsQuery() {
  return useQuery({
    queryKey: ['console-agents'],
    queryFn: () => unwrap(api.console.agents.get())
  })
}

function useAdaptersQuery() {
  return useQuery({
    queryKey: ['console-external-gateway-adapters'],
    queryFn: () => unwrap(api.console['external-gateway-adapters'].get())
  })
}

function adapterLabel(adapter: ConsoleExternalGatewayAdapter, locale: string): string {
  return resolveBullXPluginLocalizedText(adapter.setup?.displayName, locale, adapter.id) ?? adapter.id
}

function defaultConfigForAdapter(adapter: ConsoleExternalGatewayAdapter | undefined): JsonObject {
  return defaultPluginConfigForSetup(adapter?.setup)
}

function ErrorAlert({ error, title }: { error?: unknown; title: string }) {
  if (!error) return null

  return (
    <Alert variant="destructive">
      <AlertTitle>{title}</AlertTitle>
      <AlertDescription>
        <pre className="whitespace-pre-wrap text-xs">{errorMessage(error)}</pre>
      </AlertDescription>
    </Alert>
  )
}

function SkeletonRows({ rows }: { rows: number }) {
  return (
    <div className="grid gap-3">
      {Array.from({ length: rows }, (_, index) => (
        <Skeleton key={index} className="h-10 w-full" />
      ))}
    </div>
  )
}

function errorMessage(error: unknown): string {
  return apiErrorMessage(error)
}

mountSpa(<ConsoleApp />)
