import { Badge, Button, Dialog, DialogContent, DialogTitle, Switch } from '@ankole/uikit'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { ErrorBoundary } from '../common/error-boundary'
import { avatarInitials } from './avatar-initials'
import { pageAPI, pageInsightsQuery, pageViewersQuery, type PageDetail } from './content-api'
import { ContentError } from './content-primitives'

type Insights = Awaited<ReturnType<typeof pageAPI.insights>>
type Person = Insights['contributors'][number]

export function DocumentInsights({
  detail,
  close,
  returnFocus
}: {
  detail: PageDetail
  close(): void
  returnFocus: RefObject<HTMLButtonElement | null>
}) {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const insights = useQuery(pageInsightsQuery(detail.page.id))
  const privacy = useMutation({
    mutationFn: (hidden: boolean) => pageAPI.state(detail.page.id, { hide_visits: hidden }),
    onSuccess: async () => {
      await Promise.all([
        client.invalidateQueries({ queryKey: pageInsightsQuery(detail.page.id).queryKey }),
        client.invalidateQueries({ queryKey: pageViewersQuery(detail.page.id).queryKey })
      ])
    }
  })
  const date = (value: string) =>
    new Intl.DateTimeFormat(i18n.language, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
  return (
    <Dialog open onOpenChange={open => !open && close()}>
      <DialogContent
        className="pod-document-insights pod-dialog-wide"
        closeLabel={t('common.close')}
        finalFocus={returnFocus}>
        <DialogTitle>{t('pod.document.insights')}</DialogTitle>
        <ErrorBoundary variant="panel" resetKeys={[detail.page.id]}>
          {insights.isPending && <p role="status">{t('pod.content.loading')}</p>}
          <ContentError error={insights.error} retry={() => void insights.refetch()} />
          {insights.data && !insights.error && (
            <>
              <DocumentActivity daily={insights.data.daily} />
              <section className="space-y-3">
                <h3 className="text-sm font-semibold">{t('pod.document.viewers')}</h3>
                <label className="flex items-center justify-between gap-4 rounded border border-border p-3 text-sm">
                  <span>
                    <span className="block font-medium">{t('pod.document.show_my_visits')}</span>
                    <span className="mt-1 block text-xs text-fg-secondary">{t('pod.document.visit_visibility')}</span>
                  </span>
                  <Switch
                    checked={!(privacy.isPending ? privacy.variables : insights.data.hide_visits)}
                    disabled={privacy.isPending}
                    onCheckedChange={checked => privacy.mutate(!checked)}
                  />
                </label>
                <ContentError error={privacy.error} />
                {insights.data.can_view_readers ? (
                  <DocumentViewers pageID={detail.page.id} />
                ) : (
                  <p className="text-xs text-fg-secondary">{t('pod.document.viewers_editors_only')}</p>
                )}
              </section>
              <section className="space-y-3">
                <h3 className="text-sm font-semibold">{t('pod.document.source')}</h3>
                <dl className="pod-document-source grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-[13px]">
                  <dt className="text-fg-tertiary">{t('pod.document.created')}</dt>
                  <dd className="m-0">
                    <time dateTime={insights.data.created_at}>{date(insights.data.created_at)}</time>
                  </dd>
                  <dt className="text-fg-tertiary">{t('pod.document.last_updated')}</dt>
                  <dd className="m-0">
                    <time dateTime={insights.data.updated_at}>{date(insights.data.updated_at)}</time>
                  </dd>
                </dl>
              </section>
              <section className="space-y-3">
                <h3 className="text-sm font-semibold">{t('pod.document.contributors')}</h3>
                <ul className="pod-document-contributors m-0 flex list-none flex-col gap-3 p-0">
                  {insights.data.contributors.map(person => (
                    <li key={person.principal_uid}>
                      <PersonRow person={person} subtitle={t(`pod.document.${person.role}`)} />
                    </li>
                  ))}
                </ul>
              </section>
            </>
          )}
        </ErrorBoundary>
      </DialogContent>
    </Dialog>
  )
}

function DocumentViewers({ pageID }: { pageID: string }) {
  const { t, i18n } = useTranslation()
  const query = useInfiniteQuery(pageViewersQuery(pageID))
  const viewers = query.data?.pages.flatMap(page => page.viewers) ?? []
  return (
    <>
      {query.isPending && <p role="status">{t('pod.content.loading')}</p>}
      <ContentError error={query.error} retry={() => void query.refetch()} />
      {query.data && !query.error && (
        <>
          <p className="text-xs text-fg-secondary">
            {t('pod.document.visible_viewers', { count: query.data.pages[0]?.total ?? 0 })}
          </p>
          <ul className="m-0 flex list-none flex-col gap-3 p-0" aria-label={t('pod.document.viewers')}>
            {viewers.map(({ person, visited_at }) => (
              <li key={person.principal_uid}>
                <PersonRow
                  person={person}
                  subtitle={t('pod.document.last_viewed', {
                    time: new Intl.DateTimeFormat(i18n.language, { dateStyle: 'medium', timeStyle: 'short' }).format(
                      new Date(visited_at)
                    )
                  })}
                />
              </li>
            ))}
          </ul>
          {!viewers.length && <p className="text-sm text-fg-secondary">{t('pod.document.no_visible_viewers')}</p>}
          {query.hasNextPage && (
            <Button variant="ghost" disabled={query.isFetchingNextPage} onClick={() => void query.fetchNextPage()}>
              {t('pod.document.load_more')}
            </Button>
          )}
        </>
      )}
    </>
  )
}

function PersonRow({ person, subtitle }: { person: Omit<Person, 'role'>; subtitle: string }) {
  const { t } = useTranslation()
  return (
    <div className="flex items-center gap-3">
      <div className="grid size-9 shrink-0 place-items-center overflow-hidden rounded-full bg-accent" aria-hidden>
        {person.avatar_url ? (
          <img className="size-full object-cover" src={person.avatar_url} alt="" />
        ) : (
          avatarInitials(person.name || person.principal_uid)
        )}
      </div>
      <div className="min-w-0 flex-1">
        <p className="flex flex-wrap items-center gap-2 [overflow-wrap:anywhere]">
          {person.name || person.principal_uid}
          {person.kind === 'agent' && <Badge variant="secondary">{t('pod.document.agent_author')}</Badge>}
        </p>
        <p className="text-xs text-fg-tertiary">{subtitle}</p>
      </div>
    </div>
  )
}

const series = [
  { key: 'views', color: 'var(--color-info)' },
  { key: 'edits', color: 'var(--color-warning)' },
  { key: 'comments', color: 'var(--color-success)' }
] as const

function DocumentActivity({ daily }: { daily: Insights['daily'] }) {
  const { t, i18n } = useTranslation()
  const today = new Date()
  const days = Array.from({ length: 30 }, (_, index) => {
    const date = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() - 29 + index))
    const day = date.toISOString().slice(0, 10)
    return daily.find(row => row.day === day) ?? { day, views: 0, edits: 0, comments: 0 }
  })
  const totals = series.map(item => days.reduce((sum, day) => sum + day[item.key], 0))
  const maximum = Math.max(1, ...days.flatMap(day => series.map(item => day[item.key])))
  const dayLabel = (day: string) =>
    new Intl.DateTimeFormat(i18n.language, { month: 'short', day: 'numeric', timeZone: 'UTC' }).format(new Date(day))
  return (
    <section className="space-y-3">
      <h3 className="text-sm font-semibold">{t('pod.document.activity_30_days')}</h3>
      <ul className="m-0 flex list-none flex-wrap gap-4 p-0 text-sm">
        {series.map((item, index) => (
          <li key={item.key} className="flex items-center gap-1.5">
            <span aria-hidden className="size-2 rounded-full" style={{ backgroundColor: item.color }} />
            {t(`pod.document.activity_${item.key}`)} <strong>{totals[index]}</strong>
          </li>
        ))}
      </ul>
      <svg viewBox="0 0 600 170" className="w-full" role="img" aria-label={t('pod.document.activity_30_days')}>
        <path d="M30 10V140H585" fill="none" stroke="var(--color-border)" />
        <text x="24" y="16" textAnchor="end" fill="currentColor" fontSize="14" className="max-sm:text-xl">
          {maximum}
        </text>
        <text x="24" y="142" textAnchor="end" fill="currentColor" fontSize="14" className="max-sm:text-xl">
          0
        </text>
        {series.map(item => (
          <g key={item.key}>
            <polyline
              points={days.map((day, index) => `${30 + index * 19},${140 - (day[item.key] / maximum) * 125}`).join(' ')}
              fill="none"
              stroke={item.color}
              strokeWidth="2"
            />
            {days.map(
              (day, index) =>
                day[item.key] > 0 && (
                  <circle
                    key={day.day}
                    cx={30 + index * 19}
                    cy={140 - (day[item.key] / maximum) * 125}
                    r="3"
                    fill={item.color}>
                    <title>
                      {dayLabel(day.day)} · {t(`pod.document.activity_${item.key}`)}: {day[item.key]}
                    </title>
                  </circle>
                )
            )}
          </g>
        ))}
        {[0, 7, 14, 21, 29].map(index => (
          <text
            key={index}
            x={30 + index * 19}
            y="162"
            textAnchor={index === 0 ? 'start' : index === 29 ? 'end' : 'middle'}
            fill="currentColor"
            fontSize="14"
            className="max-sm:text-xl">
            {dayLabel(days[index]!.day)}
          </text>
        ))}
      </svg>
      <details className="text-xs text-fg-secondary">
        <summary className="cursor-pointer">{t('pod.document.activity_details')}</summary>
        <p className="my-2">{t('pod.document.activity_definition')}</p>
        <div className="max-h-48 overflow-y-auto">
          <table className="w-full text-start">
            <thead>
              <tr>
                <th>{t('pod.document.activity_date')}</th>
                {series.map(item => (
                  <th key={item.key}>{t(`pod.document.activity_${item.key}`)}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {days.map(day => (
                <tr key={day.day}>
                  <td>{dayLabel(day.day)}</td>
                  {series.map(item => (
                    <td key={item.key} className="text-center tabular-nums">
                      {day[item.key]}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
    </section>
  )
}
