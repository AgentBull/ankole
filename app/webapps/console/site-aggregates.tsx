import {
  Badge,
  Button,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@ankole/uikit'
import {
  ArrowRightRegular,
  BotRegular,
  BranchRegular,
  CalendarClockRegular,
  KeyRegular,
  LiveRegular,
  ServerRegular,
  SparkleRegular
} from '@ankole/uikit/icons'
import { type InfiniteData, type UseInfiniteQueryOptions, useInfiniteQuery, useQuery } from '@tanstack/react-query'
import { Link as RouterLink, type AnyRouter } from '@tanstack/react-router'
import { useDeferredValue, useId, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { ErrorBlock } from '../common/error-block'
import {
  getSiteAiUsageOptions,
  getSiteOverviewOptions,
  listAiGatewayProvidersOptions,
  listSiteAgentsInfiniteOptions,
  listSiteBackgroundAgentJobsInfiniteOptions,
  listSitePrincipalsInfiniteOptions,
  listSiteSchedulesInfiniteOptions,
  listSiteSignalBindingsInfiniteOptions,
  listSiteWorkersInfiniteOptions
} from './api/v2-site/generated/@tanstack/react-query.gen'
import { BackgroundJobStatus } from './background-job-status'
import { StatusIndicator } from './console-form'
import { FilterSwitch, ResourceListPage, ResourceSearch, SubNav } from './console-list-page'
import { PageHeader, PageStack, RefreshButton } from './console-page'
import { formatConsoleDate } from './console-primitives'
import { MetricTile } from './pages/home'
import { AccessSubNav } from './pages/principals'
import { workerReason, workerStateTone } from './pages/workers'
import { LIST_REFRESH_MS, SETTLED_WORKERS_REFRESH_MS } from './refresh-intervals'
import { aiGatewayProviders } from './state/provider-settings'
import { effectiveResourceSearchQuery } from './state/resource-search'
import { useSearchParams } from './tenant-context'

const SITE_AGGREGATE_PATHS = new Set([
  '/',
  '/agents',
  '/workers',
  '/access/principals',
  '/signals',
  '/schedules',
  '/background-agent-jobs',
  '/ai-usage'
])

export function hasSiteAggregateView(pathname: string): boolean {
  return SITE_AGGREGATE_PATHS.has(pathname)
}

export function SiteAggregateView({ pathname }: { pathname: string }) {
  switch (pathname) {
    case '/':
      return <SiteOverviewAggregate />
    case '/agents':
      return <SiteAgentsAggregate />
    case '/workers':
      return <SiteWorkersAggregate />
    case '/access/principals':
      return <SitePrincipalsAggregate />
    case '/signals':
      return <SiteSignalBindingsAggregate />
    case '/schedules':
      return <SiteSchedulesAggregate />
    case '/background-agent-jobs':
      return <SiteBackgroundAgentJobsAggregate />
    case '/ai-usage':
      return <SiteAiUsageAggregate />
    default:
      return null
  }
}

function TenantLink({
  ariaLabel,
  children,
  className,
  dataRowLink,
  search,
  tenantID,
  title,
  to
}: {
  ariaLabel?: string
  children: ReactNode
  className?: string
  dataRowLink?: boolean
  search?: Record<string, string>
  tenantID: string
  title?: string
  to: string
}) {
  return (
    <RouterLink<AnyRouter, string, string, string, string>
      aria-label={ariaLabel}
      className={className}
      data-row-link={dataRowLink ? true : undefined}
      search={{ ...search, data_tenant: tenantID }}
      title={title}
      to={to}>
      {children}
    </RouterLink>
  )
}

function TenantRowAction({
  label,
  search,
  tenantID,
  to
}: {
  label: string
  search?: Record<string, string>
  tenantID: string
  to: string
}) {
  return (
    <TableCell className="w-12 text-right">
      <TenantLink
        ariaLabel={label}
        className="inline-grid size-7 place-items-center rounded-control text-fg-secondary hover:bg-layer-hover hover:text-fg-primary"
        search={search}
        tenantID={tenantID}
        title={label}
        to={to}>
        <ArrowRightRegular aria-hidden />
      </TenantLink>
    </TableCell>
  )
}

interface AggregateTenantRow {
  tenant_id: string
  tenant_slug: string
  tenant_display_name: string
}

interface AggregatePage<TRow> {
  items: TRow[]
  next_cursor?: string | null
}

function SiteAggregateListPage<
  TRow extends AggregateTenantRow,
  TError,
  TQueryKey extends readonly unknown[],
  TPageParam
>({
  columns,
  description,
  emptyDescription,
  emptyIcon,
  emptyTitle,
  extraFiltered = false,
  filters,
  onResetExtraFilters,
  queryOptions,
  refetchInterval,
  renderRow,
  rowKey,
  searchLabel,
  searchPlaceholder,
  subNav,
  title,
  toolbarCanRevealRows
}: {
  columns: string[]
  description: string
  emptyDescription: string
  emptyIcon: ReactNode
  emptyTitle: string
  extraFiltered?: boolean
  filters?: ReactNode
  onResetExtraFilters?: () => void
  queryOptions: (
    searchQuery: string
  ) => Omit<
    UseInfiniteQueryOptions<AggregatePage<TRow>, TError, InfiniteData<AggregatePage<TRow>>, TQueryKey, TPageParam>,
    'getNextPageParam' | 'initialData' | 'initialPageParam'
  >
  refetchInterval?: number
  renderRow: (row: NoInfer<TRow>) => ReactNode
  rowKey: (row: NoInfer<TRow>) => string
  searchLabel: string
  searchPlaceholder: string
  subNav?: ReactNode
  title: string
  toolbarCanRevealRows?: boolean
}) {
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery).trim()
  const listing = useInfiniteQuery({
    ...queryOptions(searchQuery),
    initialPageParam: {} as TPageParam,
    getNextPageParam: lastPage => (lastPage.next_cursor ?? undefined) as TPageParam | undefined,
    refetchInterval
  })
  const rows = listing.data?.pages.flatMap(page => page.items) ?? []

  return (
    <ResourceListPage
      title={title}
      description={description}
      columns={[t('console.tenants.tenant'), ...columns]}
      isLoading={listing.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={emptyTitle}
      emptyDescription={emptyDescription}
      emptyIcon={emptyIcon}
      error={listing.error}
      isFiltered={Boolean(searchQuery) || extraFiltered}
      onClearFilters={() => {
        setQuery('')
        onResetExtraFilters?.()
      }}
      pagination={listing}
      subNav={subNav}
      toolbarCanRevealRows={toolbarCanRevealRows}
      toolbar={
        <ResourceSearch
          label={searchLabel}
          placeholder={searchPlaceholder}
          value={query}
          onChange={setQuery}
          filters={filters}
        />
      }>
      {rows.map(row => (
        <TableRow key={rowKey(row)}>
          <TableCell title={row.tenant_slug}>{row.tenant_display_name}</TableCell>
          {renderRow(row)}
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

function SiteOverviewAggregate() {
  const { t } = useTranslation()
  const overview = useQuery({ ...getSiteOverviewOptions(), refetchInterval: LIST_REFRESH_MS })
  const providers = useQuery({
    ...listAiGatewayProvidersOptions(),
    select: aiGatewayProviders,
    refetchInterval: LIST_REFRESH_MS
  })
  const recentJobs = useInfiniteQuery({
    ...listSiteBackgroundAgentJobsInfiniteOptions({ query: { limit: 10 } }),
    initialPageParam: {},
    getNextPageParam: lastPage => lastPage.next_cursor ?? undefined,
    refetchInterval: LIST_REFRESH_MS
  })

  const providerRows = providers.data ?? []
  const enabledProviders = providerRows.filter(provider => !provider.disabled_at).length
  const totalAgents = (overview.data?.active_agents ?? 0) + (overview.data?.disabled_agents ?? 0)
  const totalWorkers =
    (overview.data?.ready_workers ?? 0) +
    (overview.data?.starting_workers ?? 0) +
    (overview.data?.unhealthy_workers ?? 0)
  const jobRows = recentJobs.data?.pages.flatMap(page => page.items) ?? []
  const error = overview.error ?? providers.error ?? recentJobs.error

  return (
    <PageStack>
      <PageHeader
        title={t('console.home.title')}
        description={t('console.home.description')}
        actions={<RefreshButton />}
      />
      <ErrorBlock error={error} />

      <section aria-label={t('console.home.overview')} className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <MetricTile
          icon={BotRegular}
          label={t('console.nav.agents')}
          to="/agents"
          loading={overview.isLoading}
          unavailable={Boolean(overview.error)}
          value={overview.data?.active_agents ?? 0}
          detail={t('console.home.of_total', { total: totalAgents })}
        />
        <MetricTile
          icon={ServerRegular}
          label={t('console.home.ready_workers')}
          to="/workers"
          loading={overview.isLoading}
          unavailable={Boolean(overview.error)}
          value={overview.data?.ready_workers ?? 0}
          detail={t('console.home.of_total', { total: totalWorkers })}
        />
        <MetricTile
          icon={BranchRegular}
          label={t('console.home.running_jobs')}
          to="/background-agent-jobs"
          loading={overview.isLoading}
          unavailable={Boolean(overview.error)}
          value={overview.data?.running_background_jobs ?? 0}
          detail={`${overview.data?.active_tenants ?? 0} ${t('console.tenants.active').toLowerCase()}`}
        />
        <MetricTile
          icon={SparkleRegular}
          label={t('console.home.enabled_providers')}
          to="/providers"
          loading={providers.isLoading}
          unavailable={Boolean(providers.error)}
          value={enabledProviders}
          detail={t('console.home.of_total', { total: providerRows.length })}
        />
      </section>

      <section className="grid min-w-0 content-start border border-border-subtle bg-page">
        <header className="flex items-center justify-between gap-3 border-b border-border-subtle px-4 py-3">
          <h3 className="flex items-center gap-2 text-sm font-semibold text-fg-primary">
            <BranchRegular className="size-4 shrink-0 text-fg-secondary" aria-hidden />
            {t('console.home.recent_jobs')}
          </h3>
          <RouterLink<AnyRouter, string, string, string, string>
            to="/background-agent-jobs"
            aria-label={`${t('console.home.view_all')} — ${t('console.home.recent_jobs')}`}
            className="flex items-center gap-1 text-sm text-fg-secondary hover:text-fg-primary">
            {t('console.home.view_all')}
            <ArrowRightRegular className="size-4" aria-hidden />
          </RouterLink>
        </header>
        {recentJobs.isLoading ? (
          <div className="grid gap-3 p-4">
            <Skeleton className="h-6 w-full" />
            <Skeleton className="h-6 w-4/5" />
          </div>
        ) : jobRows.length === 0 ? (
          <p className="px-4 py-6 text-sm text-fg-secondary">{t('console.background_agent_jobs.empty_title')}</p>
        ) : (
          <ul className="grid">
            {jobRows.slice(0, 8).map(job => (
              <li key={`${job.tenant_id}:${job.id}`}>
                <TenantLink
                  tenantID={job.tenant_id}
                  to="/background-agent-jobs"
                  search={{ job: String(job.id) }}
                  className="grid gap-1 border-b border-border-subtle px-4 py-3 last:border-b-0 hover:bg-layer-hover">
                  <div className="flex min-w-0 items-start justify-between gap-3">
                    <span className="min-w-0 truncate text-sm text-fg-primary">{job.title || `#${job.id}`}</span>
                    <BackgroundJobStatus status={job.status} />
                  </div>
                  <span className="truncate text-xs text-fg-secondary">
                    {job.tenant_display_name} · <span className="font-mono">{job.agent_uid}</span> ·{' '}
                    {formatConsoleDate(job.queued_at ?? job.started_at)}
                  </span>
                </TenantLink>
              </li>
            ))}
          </ul>
        )}
      </section>
    </PageStack>
  )
}

function SiteAgentsAggregate() {
  const { t } = useTranslation()

  return (
    <SiteAggregateListPage
      title={t('console.agents.title')}
      description={t('console.agents.description')}
      columns={[
        t('console.agents.uid'),
        t('console.agents.display_name'),
        t('console.agents.role'),
        t('console.agents.status')
      ]}
      emptyTitle={t('console.agents.empty_title')}
      emptyDescription={t('console.agents.empty_description')}
      emptyIcon={<BotRegular aria-hidden />}
      searchLabel={t('console.agents.search')}
      searchPlaceholder={t('console.agents.search_placeholder')}
      queryOptions={searchQuery => listSiteAgentsInfiniteOptions({ query: { q: searchQuery || undefined } })}
      rowKey={agent => `${agent.tenant_id}:${agent.uid}`}
      renderRow={agent => {
        const disabled = agent.status === 'disabled'
        const detailPath = `/agents/${encodeURIComponent(agent.uid)}`
        return (
          <>
            <TableCell className="font-mono text-xs">
              <TenantLink dataRowLink className="text-fg-primary" tenantID={agent.tenant_id} to={detailPath}>
                {agent.uid}
              </TenantLink>
            </TableCell>
            <TableCell>{agent.display_name || '—'}</TableCell>
            <TableCell>{agent.role}</TableCell>
            <TableCell>
              <StatusIndicator tone={disabled ? 'neutral' : 'positive'}>
                {t(`console.status.${agent.status}`)}
              </StatusIndicator>
            </TableCell>
            <TenantRowAction
              label={t('common.view_details_for', { name: agent.uid })}
              tenantID={agent.tenant_id}
              to={detailPath}
            />
          </>
        )
      }}
    />
  )
}

function SiteWorkersAggregate() {
  const { t } = useTranslation()

  return (
    <SiteAggregateListPage
      title={t('console.workers.title')}
      description={t('console.workers.description')}
      columns={[
        t('console.workers.agent'),
        t('console.worker_providers.provider'),
        t('console.workers.state'),
        t('console.workers.last_heartbeat'),
        t('console.workers.reason')
      ]}
      emptyTitle={t('console.workers.empty_title')}
      emptyDescription={t('console.workers.empty_description')}
      emptyIcon={<ServerRegular aria-hidden />}
      searchLabel={t('console.workers.search')}
      searchPlaceholder={t('console.workers.search_placeholder')}
      queryOptions={searchQuery => listSiteWorkersInfiniteOptions({ query: { q: searchQuery || undefined } })}
      refetchInterval={SETTLED_WORKERS_REFRESH_MS}
      rowKey={worker => `${worker.tenant_id}:${worker.agent_uid}`}
      renderRow={worker => {
        const reason = workerReason(worker)
        return (
          <>
            <TableCell className="font-mono text-xs">
              <TenantLink
                className="link"
                tenantID={worker.tenant_id}
                to={`/agents/${encodeURIComponent(worker.agent_uid)}`}>
                {worker.agent_uid}
              </TenantLink>
            </TableCell>
            <TableCell className="font-mono text-xs">
              {worker.provider_id ? (
                <RouterLink<AnyRouter, string, string, string, string>
                  className="link"
                  to={`/worker-providers/${encodeURIComponent(worker.provider_id)}`}>
                  {worker.provider_id}
                </RouterLink>
              ) : (
                '–'
              )}
            </TableCell>
            <TableCell>
              <StatusIndicator tone={workerStateTone(worker)}>{t(`console.status.${worker.state}`)}</StatusIndicator>
            </TableCell>
            <TableCell className="text-xs text-fg-secondary">
              {formatConsoleDate(worker.last_worker_heartbeat_at)}
            </TableCell>
            <TableCell className="max-w-md truncate font-mono text-xs text-fg-secondary" title={reason}>
              {reason || '–'}
            </TableCell>
            <TenantRowAction
              label={t('common.view_details_for', { name: worker.agent_uid })}
              tenantID={worker.tenant_id}
              to="/workers"
            />
          </>
        )
      }}
    />
  )
}

function SitePrincipalsAggregate() {
  const { t } = useTranslation()
  const [showServiceAccounts, setShowServiceAccounts] = useState(false)

  return (
    <SiteAggregateListPage
      title={t('console.principals.title')}
      description={t('console.principals.description')}
      columns={[
        t('console.principals.principal'),
        t('console.principals.identity'),
        t('console.principals.type'),
        t('console.principals.membership'),
        t('console.principals.status')
      ]}
      emptyTitle={t('console.principals.empty_title')}
      emptyDescription={t('console.principals.empty_description')}
      emptyIcon={<KeyRegular aria-hidden />}
      searchLabel={t('console.principals.search')}
      searchPlaceholder={t('console.principals.search_placeholder')}
      subNav={<AccessSubNav />}
      toolbarCanRevealRows
      filters={
        <FilterSwitch
          checked={showServiceAccounts}
          label={t('console.principals.show_service_accounts')}
          onChange={setShowServiceAccounts}
        />
      }
      queryOptions={searchQuery =>
        listSitePrincipalsInfiniteOptions({
          query: { include_disabled: true, include_system: showServiceAccounts, q: searchQuery || undefined }
        })
      }
      rowKey={principal => `${principal.tenant_id}:${principal.uid}`}
      renderRow={principal => {
        const label = principal.display_name || principal.email || principal.uid
        const detailPath = `/access/principals/${encodeURIComponent(principal.uid)}`
        return (
          <>
            <TableCell>
              <TenantLink dataRowLink className="text-fg-primary" tenantID={principal.tenant_id} to={detailPath}>
                {label}
              </TenantLink>
            </TableCell>
            <TableCell className="text-sm">{principal.email ?? principal.uid}</TableCell>
            <TableCell>
              <Badge variant="secondary">{t(`console.principals.type_${principal.type}`)}</Badge>
            </TableCell>
            <TableCell>
              {principal.membership ? t(`console.principals.membership_${principal.membership}`) : '—'}
            </TableCell>
            <TableCell>
              <StatusIndicator tone={principal.status === 'active' ? 'positive' : 'neutral'}>
                {t(`console.status.${principal.status}`)}
              </StatusIndicator>
            </TableCell>
            <TenantRowAction
              label={t('common.view_details_for', { name: label })}
              tenantID={principal.tenant_id}
              to={detailPath}
            />
          </>
        )
      }}
    />
  )
}

function SiteSignalBindingsAggregate() {
  const { t } = useTranslation()
  const [showDisabled, setShowDisabled] = useState(false)

  return (
    <SiteAggregateListPage
      title={t('console.signals.title')}
      description={t('console.signals.description')}
      columns={[
        t('console.signals.name'),
        t('console.agents.agent'),
        t('console.signals.adapter'),
        t('console.signals.state')
      ]}
      emptyTitle={t(showDisabled ? 'console.signals.empty_title' : 'console.signals.empty_active_title')}
      emptyDescription={t(
        showDisabled ? 'console.signals.empty_description' : 'console.signals.empty_active_description'
      )}
      emptyIcon={<LiveRegular aria-hidden />}
      searchLabel={t('console.signals.search')}
      searchPlaceholder={t('console.signals.search_placeholder')}
      toolbarCanRevealRows
      extraFiltered={showDisabled}
      onResetExtraFilters={() => setShowDisabled(false)}
      filters={
        <FilterSwitch checked={showDisabled} label={t('console.signals.show_disabled')} onChange={setShowDisabled} />
      }
      queryOptions={searchQuery =>
        listSiteSignalBindingsInfiniteOptions({
          query: { include_disabled: showDisabled, q: searchQuery || undefined }
        })
      }
      refetchInterval={LIST_REFRESH_MS}
      rowKey={binding => `${binding.tenant_id}:${binding.id}`}
      renderRow={binding => {
        const detailPath = `/signals/${encodeURIComponent(binding.id)}`
        return (
          <>
            <TableCell>
              <TenantLink dataRowLink className="text-fg-primary" tenantID={binding.tenant_id} to={detailPath}>
                {binding.name}
              </TenantLink>
            </TableCell>
            <TableCell className="font-mono text-xs">{binding.agent_uid ?? '—'}</TableCell>
            <TableCell className="font-mono text-xs">{binding.adapter}</TableCell>
            <TableCell>
              <StatusIndicator tone={binding.enabled ? 'positive' : 'neutral'}>
                {t(binding.enabled ? 'console.status.enabled' : 'console.status.disabled')}
              </StatusIndicator>
            </TableCell>
            <TenantRowAction
              label={t('common.view_details_for', { name: binding.name })}
              tenantID={binding.tenant_id}
              to={detailPath}
            />
          </>
        )
      }}
    />
  )
}

function SiteSchedulesAggregate() {
  const { t } = useTranslation()

  return (
    <SiteAggregateListPage
      title={t('console.schedules.title')}
      description={t('console.schedules.description')}
      columns={[
        t('console.schedules.name'),
        t('console.agents.agent'),
        t('console.schedules.next_fire'),
        t('console.schedules.last_fire'),
        t('console.schedules.state')
      ]}
      emptyTitle={t('console.schedules.empty_title')}
      emptyDescription={t('console.schedules.empty_description')}
      emptyIcon={<CalendarClockRegular aria-hidden />}
      searchLabel={t('console.schedules.search', { defaultValue: t('common.search') })}
      searchPlaceholder={t('console.schedules.search_placeholder', { defaultValue: t('common.search') })}
      subNav={
        <SubNav
          ariaLabel={t('console.schedules.title')}
          items={[
            {
              to: '/schedules',
              label: t('console.schedules.crons_tab', { defaultValue: t('console.schedules.title') }),
              end: true
            },
            {
              to: '/schedules/checkbacks',
              label: t('console.schedules.checkbacks_tab', { defaultValue: 'Checkbacks' })
            }
          ]}
        />
      }
      queryOptions={searchQuery => listSiteSchedulesInfiniteOptions({ query: { q: searchQuery || undefined } })}
      refetchInterval={LIST_REFRESH_MS}
      rowKey={schedule => `${schedule.tenant_id}:${schedule.id}`}
      renderRow={schedule => {
        const detailPath = `/schedules/${encodeURIComponent(schedule.agent_uid)}/${encodeURIComponent(schedule.id)}`
        return (
          <>
            <TableCell>
              <TenantLink dataRowLink className="text-fg-primary" tenantID={schedule.tenant_id} to={detailPath}>
                {schedule.name}
              </TenantLink>
            </TableCell>
            <TableCell className="font-mono text-xs">{schedule.agent_uid}</TableCell>
            <TableCell className="text-xs text-fg-secondary">{formatConsoleDate(schedule.next_fire_at)}</TableCell>
            <TableCell className="text-xs text-fg-secondary">{formatConsoleDate(schedule.last_fire_at)}</TableCell>
            <TableCell>
              <StatusIndicator tone={schedule.status === 'active' ? 'positive' : 'neutral'}>
                {t(`console.status.${schedule.status}`, { defaultValue: schedule.status })}
              </StatusIndicator>
            </TableCell>
            <TenantRowAction
              label={t('common.view_details_for', { name: schedule.name })}
              tenantID={schedule.tenant_id}
              to={detailPath}
            />
          </>
        )
      }}
    />
  )
}

function SiteBackgroundAgentJobsAggregate() {
  const { t } = useTranslation()

  return (
    <SiteAggregateListPage
      title={t('console.background_agent_jobs.title')}
      description={t('console.background_agent_jobs.description')}
      columns={[
        t('console.background_agent_jobs.title'),
        t('console.agents.agent'),
        t('console.agents.status'),
        t('console.workers.last_heartbeat')
      ]}
      emptyTitle={t('console.background_agent_jobs.empty_title')}
      emptyDescription={t('console.background_agent_jobs.empty_description')}
      emptyIcon={<BranchRegular aria-hidden />}
      searchLabel={t('console.background_agent_jobs.search')}
      searchPlaceholder={t('console.background_agent_jobs.search')}
      queryOptions={searchQuery =>
        listSiteBackgroundAgentJobsInfiniteOptions({ query: { q: searchQuery || undefined } })
      }
      refetchInterval={LIST_REFRESH_MS}
      rowKey={job => `${job.tenant_id}:${job.id}`}
      renderRow={job => (
        <>
          <TableCell>
            <TenantLink
              dataRowLink
              className="text-fg-primary"
              search={{ job: String(job.id) }}
              tenantID={job.tenant_id}
              to="/background-agent-jobs">
              <span className="font-mono text-xs text-fg-secondary">#{job.id}</span> {job.title}
            </TenantLink>
          </TableCell>
          <TableCell className="font-mono text-xs">{job.agent_uid}</TableCell>
          <TableCell>
            <BackgroundJobStatus status={job.status} />
          </TableCell>
          <TableCell className="text-xs text-fg-secondary">
            {formatConsoleDate(job.completed_at ?? job.started_at ?? job.queued_at)}
          </TableCell>
          <TenantRowAction
            label={t('common.view_details_for', { name: `#${job.id}` })}
            search={{ job: String(job.id) }}
            tenantID={job.tenant_id}
            to="/background-agent-jobs"
          />
        </>
      )}
    />
  )
}

const USAGE_WINDOWS = ['7', '30'] as const

function SiteAiUsageAggregate() {
  const { t, i18n } = useTranslation()
  const [params, setParams] = useSearchParams()
  const days = USAGE_WINDOWS.find(value => value === params.get('days')) ?? '7'
  const usage = useQuery(getSiteAiUsageOptions({ query: { days: Number(days) } }))
  const number = new Intl.NumberFormat(i18n.language)
  const titleID = useId()
  const rows = usage.data?.by_tenant ?? []
  const setDays = (value: string) => {
    const next = new URLSearchParams(params)
    next.set('days', value)
    setParams(next)
  }

  return (
    <PageStack>
      <PageHeader
        title={t('console.ai_usage.title')}
        description={t('console.ai_usage.description')}
        actions={
          <Select value={days} onValueChange={value => setDays(String(value))}>
            <SelectTrigger aria-label={t('console.ai_usage.window')} className="min-w-40">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {USAGE_WINDOWS.map(value => (
                <SelectItem key={value} value={value}>
                  {t('console.ai_usage.last_days', { count: Number(value) })}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        }
      />
      <ErrorBlock error={usage.error} />
      {usage.isPending ? (
        <Skeleton className="h-48 w-full" />
      ) : rows.length === 0 ? (
        <div className="grid justify-items-start gap-3 border border-border-subtle bg-page p-6">
          <p className="text-sm text-pretty text-fg-secondary">{t('console.ai_usage.empty')}</p>
          {days === '7' ? (
            <Button variant="outline" size="sm" onClick={() => setDays('30')}>
              {t('console.ai_usage.show_longer')}
            </Button>
          ) : null}
        </div>
      ) : (
        <section className="grid min-w-0 gap-3">
          <h3 id={titleID} className="title-section">
            {t('console.tenants.title')}
          </h3>
          <div className="overflow-x-auto border border-border-subtle bg-page">
            <Table aria-labelledby={titleID} className="min-w-[640px]">
              <TableHeader>
                <TableRow>
                  <TableHead>{t('console.tenants.tenant')}</TableHead>
                  <TableHead className="text-right">{t('console.ai_usage.reported')}</TableHead>
                  <TableHead className="text-right">{t('console.ai_usage.input')}</TableHead>
                  <TableHead className="text-right">{t('console.ai_usage.output')}</TableHead>
                  <TableHead className="text-right">{t('console.ai_usage.cached')}</TableHead>
                  <TableHead className="text-right">{t('console.ai_usage.reasoning')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map(row => (
                  <TableRow key={row.tenant_id}>
                    <TableCell title={row.tenant_slug}>
                      <TenantLink className="link" search={{ days }} tenantID={row.tenant_id} to="/ai-usage">
                        {row.tenant_display_name}
                      </TenantLink>
                    </TableCell>
                    <TableCell className="text-right tabular-nums">{number.format(row.rounds)}</TableCell>
                    <TableCell className="text-right tabular-nums">{number.format(row.input_tokens)}</TableCell>
                    <TableCell className="text-right tabular-nums">{number.format(row.output_tokens)}</TableCell>
                    <TableCell className="text-right tabular-nums">{number.format(row.cached_input_tokens)}</TableCell>
                    <TableCell className="text-right tabular-nums">{number.format(row.reasoning_tokens)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </section>
      )}
    </PageStack>
  )
}
