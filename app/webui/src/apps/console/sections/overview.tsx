import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import { Badge } from '@/uikit/components/badge'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { ErrorAlert, MetricCard, SectionHeader, SkeletonRows } from '../shared'

export function OverviewPage() {
  const { t } = useTranslation()
  const overview = useQuery({
    queryKey: ['console-overview'],
    queryFn: () => unwrap(api.console.overview.get())
  })
  const data = overview.data?.overview

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.overview.title')} description={t('console.overview.description')} />
      {overview.error ? <ErrorAlert error={overview.error} title={t('console.overview.load_failed')} /> : null}
      <section className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
        <MetricCard label={t('console.overview.metric_agents')} value={data?.counts.agents} />
        <MetricCard label={t('console.overview.metric_chat_channels')} value={data?.counts.chatChannels} />
        <MetricCard label={t('console.overview.metric_human_users')} value={data?.counts.humanUsers} />
        <MetricCard label={t('console.overview.metric_principal_groups')} value={data?.counts.principalGroups} />
        <MetricCard label={t('console.overview.metric_library_skills')} value={data?.counts.librarySkills} />
        <MetricCard
          label={t('console.overview.metric_agent_library_entries')}
          value={data?.counts.agentLibraryEntries}
        />
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
