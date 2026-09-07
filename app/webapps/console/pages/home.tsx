import { IDLE_REFRESH_MS, LIST_REFRESH_MS } from '../refresh-intervals'
import { Button, buttonVariants, Skeleton, cn } from '@ankole/uikit'
import {
  RiAlertLine,
  RiArrowRightLine,
  RiBroadcastLine,
  RiChat3Line,
  RiGitBranchLine,
  RiListCheck3,
  RiRobot2Line,
  RiServerLine,
  RiSparkling2Line
} from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import type { ComponentType, ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { isRouteErrorResponse, Link, useLocation, useRouteError } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebAgentComputerWorkerControllerIndexOptions,
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAiGatewayConversationControllerIndexOptions,
  ankoleWebAiGatewayProviderControllerIndexOptions as ankoleWebAIGatewayProviderControllerIndexOptions,
  ankoleWebBackgroundAgentJobControllerIndexOptions,
  ankoleWebBackgroundAgentJobControllerHealthOptions,
  ankoleWebConsoleReadinessControllerShowOptions,
  ankoleWebIdentityProviderControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { BackgroundAgentJobItem } from '../api/generated/types.gen'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate } from '../console-primitives'
import { conversationDisplayName } from '../conversation-presentation'
import { StatusIndicator } from '../console-form'
import { PageHeader, PageStack, RefreshButton } from '../console-page'
import { readinessSteps, type ReadinessStep } from '../console-readiness'

const NEXT_STEP_ICONS: Record<ReadinessStep['key'], ComponentType<{ className?: string }>> = {
  provider: RiSparkling2Line,
  agent: RiRobot2Line,
  profiles: RiListCheck3,
  worker: RiServerLine,
  signal: RiBroadcastLine
}

export function HomePage() {
  const { t } = useTranslation()

  // Refresh each Attention source every 15 seconds so the page updates after
  // a condition changes.
  const agents = useQuery({ ...ankoleWebAgentControllerIndexOptions(), refetchInterval: LIST_REFRESH_MS })
  const workers = useQuery({
    ...ankoleWebAgentComputerWorkerControllerIndexOptions(),
    refetchInterval: LIST_REFRESH_MS
  })
  const providers = useQuery({
    ...ankoleWebAIGatewayProviderControllerIndexOptions(),
    refetchInterval: LIST_REFRESH_MS
  })
  const identityProviders = useQuery({
    ...ankoleWebIdentityProviderControllerIndexOptions(),
    refetchInterval: LIST_REFRESH_MS
  })
  const jobs = useQuery({
    ...ankoleWebBackgroundAgentJobControllerIndexOptions({ query: { limit: 20 } }),
    refetchInterval: LIST_REFRESH_MS
  })
  const jobHealth = useQuery({
    ...ankoleWebBackgroundAgentJobControllerHealthOptions(),
    refetchInterval: LIST_REFRESH_MS
  })
  // Use the header readiness query key so both views share cached data.
  const readiness = useQuery({
    ...ankoleWebConsoleReadinessControllerShowOptions(),
    refetchInterval: IDLE_REFRESH_MS
  })
  // `min_messages: 2` matches the conversation list's own default. Without it the
  // newest rows are empty placeholder conversations, which look identical to each
  // other and tell the operator nothing about recent traffic.
  // A slow-moving summary: the min-message filter counts per conversation
  // server-side, so this panel polls at the relaxed cadence.
  const conversations = useQuery({
    ...ankoleWebAiGatewayConversationControllerIndexOptions({ query: { limit: 5, min_messages: 2 } }),
    refetchInterval: IDLE_REFRESH_MS
  })

  const queries = [agents, workers, providers, identityProviders, jobs, jobHealth, conversations, readiness]
  const error = queries.find(query => query.error)?.error

  const agentRows = agents.data?.agents ?? []
  const workerRows = workers.data?.workers ?? []
  const providerRows = providers.data?.ai_gateway_providers ?? []
  const jobRows = jobs.data?.jobs ?? []

  const activeAgents = agentRows.filter(agent => agent.status === 'active').length
  const readyWorkers = workerRows.filter(worker => worker.status === 'ready').length
  const enabledProviders = providerRows.filter(provider => !provider.disabled_at).length
  const failedJobs = jobRows.filter(job => job.status === 'failed')

  // Use the same readiness report and step definitions as the header. Hide
  // completed steps. Hide this section when the deployment instance is ready.
  const nextSteps =
    readiness.data && !readiness.data.ready ? readinessSteps(t, readiness.data).filter(step => !step.complete) : []

  // Only conditions that stop or degrade real work appear here. A blocker is a
  // link to the page that fixes it, because an alert the operator cannot act on
  // is noise they learn to skip. Each absence claim requires its own query's
  // data: a failed request must not render as a confident zero.
  const alerts: Alert[] = []
  if (providers.data && enabledProviders === 0) {
    alerts.push({
      tone: 'danger',
      title: t('console.home.alert_no_provider_title'),
      description: t('console.home.alert_no_provider_description'),
      to: '/providers',
      action: t('console.home.alert_no_provider_action')
    })
  }
  if (workerRows.length > 0 && readyWorkers === 0) {
    alerts.push({
      tone: 'warning',
      title: t('console.home.alert_no_ready_worker_title'),
      description: t('console.home.alert_no_ready_worker_description'),
      to: '/workers',
      action: t('console.home.alert_no_ready_worker_action')
    })
  }
  if (identityProviders.data?.identity_providers.every(provider => !provider.enabled)) {
    alerts.push({
      tone: 'warning',
      title: t('console.home.alert_no_identity_title'),
      description: t('console.home.alert_no_identity_description'),
      to: '/identity',
      action: t('console.home.alert_no_identity_action')
    })
  }
  if (failedJobs.length > 0) {
    alerts.push({
      tone: 'danger',
      title: t('console.home.alert_failed_jobs_title', { count: failedJobs.length }),
      description: t('console.home.alert_failed_jobs_description'),
      to: '/background-agent-jobs',
      action: t('console.home.alert_failed_jobs_action')
    })
  }

  return (
    <PageStack>
      <PageHeader
        title={t('console.home.title')}
        description={t('console.home.description')}
        actions={<RefreshButton />}
      />

      <ErrorBlock error={error} />

      {alerts.length > 0 ? (
        <section className="grid gap-3" aria-label={t('console.home.attention')}>
          <h3 className="text-sm font-semibold text-foreground">{t('console.home.attention')}</h3>
          {alerts.map(alert => (
            <AlertRow key={alert.title} alert={alert} />
          ))}
        </section>
      ) : null}

      <section aria-label={t('console.home.overview')} className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <MetricTile
          icon={RiRobot2Line}
          label={t('console.nav.agents')}
          to="/agents"
          loading={agents.isLoading}
          unavailable={Boolean(agents.error)}
          value={activeAgents}
          detail={t('console.home.of_total', { total: agentRows.length })}
        />
        <MetricTile
          icon={RiServerLine}
          label={t('console.home.ready_workers')}
          to="/workers"
          loading={workers.isLoading}
          unavailable={Boolean(workers.error)}
          value={readyWorkers}
          detail={t('console.home.of_total', { total: workerRows.length })}
        />
        <MetricTile
          icon={RiGitBranchLine}
          label={t('console.home.running_jobs')}
          to="/background-agent-jobs"
          loading={jobHealth.isLoading}
          unavailable={Boolean(jobHealth.error)}
          value={jobHealth.data?.running_count ?? 0}
          detail={t('console.home.queued_jobs', { count: jobHealth.data?.queued_count ?? 0 })}
        />
        <MetricTile
          icon={RiSparkling2Line}
          label={t('console.home.enabled_providers')}
          to="/providers"
          loading={providers.isLoading}
          unavailable={Boolean(providers.error)}
          value={enabledProviders}
          detail={t('console.home.of_total', { total: providerRows.length })}
        />
      </section>

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Panel
          icon={RiGitBranchLine}
          title={t('console.home.recent_jobs')}
          to="/background-agent-jobs"
          linkLabel={t('console.home.view_all')}>
          {jobs.isLoading ? (
            <RowSkeletons />
          ) : jobRows.length === 0 ? (
            <PanelEmpty>{t('console.background_agent_jobs.empty_title')}</PanelEmpty>
          ) : (
            <ul className="grid">
              {jobRows.slice(0, 5).map(job => (
                <li key={job.id}>
                  <Link
                    to={`/background-agent-jobs?job=${job.id}`}
                    className="grid gap-1 border-b border-border px-4 py-3 last:border-b-0 hover:bg-accent">
                    <div className="flex min-w-0 items-start justify-between gap-3">
                      <span className="min-w-0 truncate text-sm text-foreground">{job.title ?? `#${job.id}`}</span>
                      <JobStatus status={job.status} />
                    </div>
                    <span className="truncate font-mono text-xs text-muted-foreground">
                      {job.agent_uid} · {formatConsoleDate(job.inserted_at)}
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </Panel>

        <Panel
          icon={RiChat3Line}
          title={t('console.home.recent_conversations')}
          to="/conversations"
          linkLabel={t('console.home.view_all')}>
          {conversations.isLoading ? (
            <RowSkeletons />
          ) : (conversations.data?.conversations ?? []).length === 0 ? (
            <PanelEmpty>{t('console.conversations.empty_title')}</PanelEmpty>
          ) : (
            <ul className="grid">
              {(conversations.data?.conversations ?? []).map(conversation => {
                const displayName = conversationDisplayName(conversation)

                return (
                  <li key={conversation.id}>
                    <Link
                      to={`/conversations/${encodeURIComponent(conversation.id)}`}
                      className="grid gap-1 border-b border-border px-4 py-3 last:border-b-0 hover:bg-accent">
                      <div className="flex min-w-0 items-start justify-between gap-3">
                        <span className="min-w-0 truncate text-sm text-foreground" title={displayName}>
                          {displayName}
                        </span>
                        <span className="shrink-0 text-xs text-muted-foreground">
                          {t('console.home.message_count', { count: conversation.message_count })}
                        </span>
                      </div>
                      <span className="truncate font-mono text-xs text-muted-foreground">
                        {conversation.subject_uid} · {formatConsoleDate(conversation.updated_at)}
                      </span>
                    </Link>
                  </li>
                )
              })}
            </ul>
          )}
        </Panel>
      </div>

      {nextSteps.length > 0 ? (
        <section className="grid gap-3" aria-label={t('console.home.next_steps')}>
          <h3 className="text-sm font-semibold text-foreground">{t('console.home.next_steps')}</h3>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
            {nextSteps.map(step => (
              <NextStep
                key={step.key}
                to={step.to}
                icon={NEXT_STEP_ICONS[step.key]}
                title={step.title}
                description={step.detail}
              />
            ))}
          </div>
        </section>
      ) : null}
    </PageStack>
  )
}

/**
 * Unknown console path.
 *
 * The catch-all route used to redirect to the agent list, which told the
 * operator that their link worked and landed them somewhere they did not ask
 * for. A stale bookmark or a mistyped path is worth saying out loud.
 */
export function NotFoundPage() {
  const { t } = useTranslation()
  const { pathname } = useLocation()

  return (
    <PageStack className="mx-auto max-w-2xl py-10">
      <PageHeader title={t('console.not_found.title')} description={t('console.not_found.description')} />
      <p className="font-mono text-sm break-all text-muted-foreground">{pathname}</p>
      <Link to="/" className={cn(buttonVariants({ size: 'sm' }), 'w-fit')}>
        {t('console.not_found.action')}
      </Link>
    </PageStack>
  )
}

/**
 * Last resort for a page that threw while rendering.
 *
 * Without this the router falls back to its own built-in screen: an untranslated
 * stack trace on a blank page, with no navigation and no way back into the
 * console. This keeps the operator inside the product and offers both a retry
 * and a way home, and still shows the message so a bug report can quote it.
 */
export function RouteErrorPage() {
  const { t } = useTranslation()
  const error = useRouteError()
  // Loader failures reject with the parsed JSON error body, so the fallback
  // goes through the shared envelope reader instead of String(object).
  const detail = isRouteErrorResponse(error)
    ? `${error.status} ${error.statusText}`
    : error instanceof Error
      ? error.message
      : error
        ? requestErrorMessage(error)
        : ''

  return (
    <PageStack className="mx-auto max-w-2xl py-10">
      <PageHeader title={t('console.route_error.title')} description={t('console.route_error.description')} />
      {detail ? <p className="font-mono text-sm break-all text-muted-foreground">{detail}</p> : null}
      <div className="flex flex-wrap gap-3">
        <Button size="sm" type="button" onClick={() => window.location.reload()}>
          {t('common.retry')}
        </Button>
        <Link to="/" className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))}>
          {t('console.not_found.action')}
        </Link>
      </div>
    </PageStack>
  )
}

type Alert = {
  tone: 'danger' | 'warning'
  title: string
  description: string
  to: string
  action: string
}

function AlertRow({ alert }: { alert: Alert }) {
  return (
    <div
      className={cn(
        'flex flex-wrap items-start justify-between gap-4 border border-l-4 border-border bg-card p-4',
        alert.tone === 'danger' ? 'border-l-destructive' : 'border-l-warning'
      )}>
      <div className="flex min-w-0 gap-3">
        <RiAlertLine
          className={cn('mt-0.5 size-4 shrink-0', alert.tone === 'danger' ? 'text-destructive' : 'text-warning')}
          aria-hidden
        />
        <div className="grid min-w-0 gap-1">
          <p className="text-sm font-semibold text-foreground">{alert.title}</p>
          <p className="text-sm leading-6 text-muted-foreground">{alert.description}</p>
        </div>
      </div>
      <Link to={alert.to} className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))}>
        {alert.action}
      </Link>
    </div>
  )
}

function MetricTile({
  detail,
  icon: Icon,
  label,
  loading,
  unavailable = false,
  to,
  value
}: {
  detail: string
  icon: ComponentType<{ className?: string }>
  label: string
  loading: boolean
  /** The query failed. Show "—" instead of a loading indicator or zero. */
  unavailable?: boolean
  to: string
  value: number
}) {
  return (
    <Link
      to={to}
      className="grid gap-3 border border-border bg-card p-4 transition-colors fine-hover:hover:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary">
      <span className="flex items-center gap-2 text-sm text-muted-foreground">
        <Icon className="size-4 shrink-0" aria-hidden />
        {label}
      </span>
      {unavailable ? (
        <span className="text-3xl font-semibold tabular-nums text-muted-foreground">—</span>
      ) : loading ? (
        <Skeleton className="h-9 w-16" />
      ) : (
        <span className="text-3xl font-semibold tabular-nums text-foreground">{value}</span>
      )}
      <span className="text-xs text-muted-foreground">{detail}</span>
    </Link>
  )
}

function Panel({
  children,
  icon: Icon,
  linkLabel,
  title,
  to
}: {
  children: ReactNode
  icon: ComponentType<{ className?: string }>
  linkLabel: string
  title: string
  to: string
}) {
  return (
    <section className="grid min-w-0 content-start border border-border bg-card">
      <header className="flex items-center justify-between gap-3 border-b border-border px-4 py-3">
        <h3 className="flex items-center gap-2 text-sm font-semibold text-foreground">
          <Icon className="size-4 shrink-0 text-muted-foreground" aria-hidden />
          {title}
        </h3>
        {/* Both panels say "View all"; the panel title is what tells them apart. */}
        <Link
          to={to}
          aria-label={`${linkLabel} — ${title}`}
          className="flex items-center gap-1 text-sm text-muted-foreground hover:text-link">
          {linkLabel}
          <RiArrowRightLine className="size-4" aria-hidden />
        </Link>
      </header>
      {children}
    </section>
  )
}

function PanelEmpty({ children }: { children: ReactNode }) {
  return <p className="px-4 py-6 text-sm text-muted-foreground">{children}</p>
}

function RowSkeletons() {
  return (
    <div className="grid gap-3 p-4">
      <Skeleton className="h-6 w-full" />
      <Skeleton className="h-6 w-4/5" />
      <Skeleton className="h-6 w-2/3" />
    </div>
  )
}

function NextStep({
  description,
  icon: Icon,
  title,
  to
}: {
  description: string
  icon: ComponentType<{ className?: string }>
  title: string
  to: string
}) {
  return (
    <Link
      to={to}
      className="grid content-start gap-2 border border-border bg-card p-4 transition-colors fine-hover:hover:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary">
      <span className="flex items-center gap-2 text-sm font-semibold text-foreground">
        <Icon className="size-4 shrink-0 text-muted-foreground" aria-hidden />
        {title}
      </span>
      <span className="text-sm leading-6 text-muted-foreground">{description}</span>
    </Link>
  )
}

function JobStatus({ status }: { status: BackgroundAgentJobItem['status'] }) {
  const { t } = useTranslation()
  const tone =
    status === 'failed' || status === 'stopped'
      ? 'danger'
      : status === 'succeeded'
        ? 'positive'
        : status === 'running'
          ? 'info'
          : status === 'waiting_on_user'
            ? 'warning'
            : 'neutral'

  return <StatusIndicator tone={tone}>{t(`console.background_agent_jobs.status_${status}`)}</StatusIndicator>
}
