import { Badge, Skeleton } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import type { ReactNode } from 'react'
import { ankoleWebBrainControllerHealthOptions } from '../../api/generated/@tanstack/react-query.gen'
import type { BrainHealth, BrainModelStatus } from '../../api/generated/types.gen'
import { ErrorBlock } from '../../../common/error-block'
import { PageHeader, PageStack } from '../../console-page'
import { formatDuration, formatJSON } from '../../console-primitives'
import { IDLE_REFRESH_MS } from '../../refresh-intervals'
import { BrainSubNav } from './brain-nav'

export function BrainHealthPage() {
  const { t } = useTranslation()
  const health = useQuery({
    ...ankoleWebBrainControllerHealthOptions(),
    refetchInterval: IDLE_REFRESH_MS
  })
  const snapshot = health.data?.health

  return (
    <PageStack>
      <PageHeader title={t('console.brain.health_title')} description={t('console.brain.health_description')} />
      <BrainSubNav />
      <ErrorBlock error={health.error} />

      {health.isLoading ? (
        <div className="grid gap-4">
          <Skeleton className="h-24 w-full" />
          <Skeleton className="h-48 w-full" />
        </div>
      ) : snapshot ? (
        <div className="grid gap-5">
          <HealthSection title={t('console.brain.health_status')}>
            <HealthItem label={t('console.settings.brain_enabled')}>
              {snapshot.enabled ? (
                <Badge variant="success">{t('console.status.enabled')}</Badge>
              ) : (
                <Badge variant="outline">{t('console.status.disabled')}</Badge>
              )}
            </HealthItem>
            <InvalidConfigKeys config={snapshot.config} />
          </HealthSection>

          <HealthSection title={t('console.brain.health_models')}>
            <ModelStatusItem label={t('console.settings.brain_embedding_model')} status={snapshot.models.embedding} />
            <ModelStatusItem label={t('console.settings.brain_rerank_model')} status={snapshot.models.rerank} />
            <ModelStatusItem label={t('console.settings.brain_web_fetch_model')} status={snapshot.models.web_fetch} />
            <ModelStatusItem label={t('console.settings.brain_extraction_model')} status={snapshot.models.extraction} />
            <ModelStatusItem label={t('console.settings.brain_dreaming_model')} status={snapshot.models.dreaming} />
            <HealthItem label={t('console.brain.embedding_signature')}>
              {snapshot.embedding_signature == null ? (
                <Badge variant="warning">{t('console.brain.model_not_configured')}</Badge>
              ) : (
                <code className="text-xs break-all text-muted-foreground">
                  {formatJSON(snapshot.embedding_signature)}
                </code>
              )}
            </HealthItem>
          </HealthSection>

          <HealthSection title={t('console.brain.health_signals')}>
            <HealthItem label={t('console.brain.pending_channels')}>
              <span className={snapshot.signals.pending_channels > 0 ? 'font-semibold' : undefined}>
                {snapshot.signals.pending_channels}
              </span>
            </HealthItem>
            <HealthItem label={t('console.brain.oldest_pending_age')}>
              {snapshot.signals.oldest_pending_age_seconds != null
                ? formatDuration(snapshot.signals.oldest_pending_age_seconds)
                : '—'}
            </HealthItem>
            <HealthItem label={t('console.brain.context_pack_counters')}>
              {t('console.brain.context_pack_values', {
                served: snapshot.context_pack.served,
                degraded: snapshot.context_pack.degraded
              })}
            </HealthItem>
          </HealthSection>

          <HealthSection title={t('console.brain.health_embeddings')}>
            <HealthItem label={t('console.brain.failed_chunks')}>
              <FailureCount count={snapshot.embeddings.failed_chunks} />
            </HealthItem>
            <HealthItem label={t('console.brain.failed_claims')}>
              <FailureCount count={snapshot.embeddings.failed_claims} />
            </HealthItem>
            <HealthItem label={t('console.brain.pending_chunks')}>{snapshot.embeddings.pending_chunks}</HealthItem>
            {snapshot.embeddings.recent_error ? (
              <HealthItem label={t('console.brain.recent_embedding_error')}>
                <code className="text-xs break-all text-destructive">{snapshot.embeddings.recent_error}</code>
              </HealthItem>
            ) : null}
          </HealthSection>

          <HealthSection title={t('console.brain.health_channels')}>
            {snapshot.channels_without_member_group.length === 0 ? (
              <p className="text-sm text-muted-foreground">{t('console.brain.all_channels_have_groups')}</p>
            ) : (
              <div className="grid gap-2">
                <p className="text-sm text-warning-foreground">
                  {t('console.brain.channels_without_group', {
                    count: snapshot.channels_without_member_group.length
                  })}
                </p>
                <ul className="grid gap-1">
                  {snapshot.channels_without_member_group.map(channelID => (
                    <li key={channelID} className="font-mono text-xs text-muted-foreground">
                      {channelID}
                    </li>
                  ))}
                </ul>
              </div>
            )}
          </HealthSection>

          <SkillLessonsSection lessons={snapshot.skill_lessons} />
        </div>
      ) : null}
    </PageStack>
  )
}

function SkillLessonsSection({ lessons }: { lessons: BrainHealth['skill_lessons'] }) {
  const { t } = useTranslation()
  const perAgent = Object.entries(lessons.active_per_agent ?? {}).sort(([a], [b]) => a.localeCompare(b))
  const totalActive = perAgent.reduce((sum, [, count]) => sum + count, 0)
  const retired = Object.entries(lessons.retired_last_7d ?? {}).sort(([a], [b]) => a.localeCompare(b))

  return (
    <HealthSection title={t('console.brain.health_skill_lessons')}>
      <p className="text-sm text-muted-foreground">{t('console.brain.skill_lessons_description')}</p>
      <HealthItem label={t('console.brain.skill_learning')}>
        {lessons.enabled ? (
          <Badge variant="success">{t('console.status.enabled')}</Badge>
        ) : (
          <Badge variant="outline">{t('console.status.disabled')}</Badge>
        )}
      </HealthItem>
      <HealthItem label={t('console.brain.active_lessons')}>
        <span className="inline-flex flex-wrap items-baseline gap-2">
          <span>{totalActive}</span>
          {perAgent.length > 0 ? (
            <span className="font-mono text-xs text-muted-foreground">
              {perAgent.map(([agentUID, count]) => `${agentUID}: ${count}`).join(' · ')}
            </span>
          ) : null}
        </span>
      </HealthItem>
      <HealthItem label={t('console.brain.lessons_added_7d')}>{lessons.added_last_7d ?? 0}</HealthItem>
      <HealthItem label={t('console.brain.lessons_retired_7d')}>
        {retired.length === 0
          ? 0
          : retired
              .map(
                ([reason, count]) =>
                  `${t(`console.agent_library_capabilities.lessons_retire_reason_${reason}`)}: ${count}`
              )
              .join(' · ')}
      </HealthItem>
      <HealthItem label={t('console.brain.oldest_active_lesson')}>
        {typeof lessons.oldest_active_days === 'number'
          ? t('console.brain.age_days', { days: lessons.oldest_active_days })
          : '—'}
      </HealthItem>
    </HealthSection>
  )
}

function HealthSection({ children, title }: { children: ReactNode; title: string }) {
  return (
    <section className="grid gap-3 border border-border bg-card p-5">
      <h3 className="text-sm font-semibold">{title}</h3>
      {children}
    </section>
  )
}

function HealthItem({ children, label }: { children: ReactNode; label: string }) {
  return (
    <div className="flex flex-wrap items-baseline gap-3 text-sm">
      <span className="min-w-56 text-muted-foreground">{label}</span>
      <span className="min-w-0">{children}</span>
    </div>
  )
}

function ModelStatusItem({ label, status }: { label: string; status: BrainModelStatus }) {
  const { t } = useTranslation()

  return (
    <HealthItem label={label}>
      {status.configured ? (
        <span className="inline-flex flex-wrap items-center gap-2">
          <Badge variant="success">{t('console.brain.model_configured')}</Badge>
          <span className="font-mono text-xs text-muted-foreground">
            {status.provider_id} · {status.model}
          </span>
          {status.provider_available === false ? (
            <>
              <Badge variant="destructive">{t('console.brain.model_provider_missing')}</Badge>
              {status.provider_error ? (
                <code className="text-xs break-all text-destructive">{status.provider_error}</code>
              ) : null}
            </>
          ) : null}
        </span>
      ) : (
        <Badge variant="warning">{t('console.brain.model_not_configured')}</Badge>
      )}
    </HealthItem>
  )
}

/** Names each brain.* key whose stored row no longer validates. */
function InvalidConfigKeys({ config }: { config: Record<string, unknown> }) {
  const { t } = useTranslation()
  const invalid = Object.entries(config).filter(([, status]) => status !== 'ok')
  if (invalid.length === 0) return null

  return (
    <div className="grid gap-1">
      <p className="text-sm text-destructive">{t('console.brain.invalid_config_keys')}</p>
      <ul className="grid gap-1">
        {invalid.map(([key, status]) => (
          <li key={key} className="font-mono text-xs text-destructive">
            {key}: {formatJSON(status)}
          </li>
        ))}
      </ul>
    </div>
  )
}

function FailureCount({ count }: { count: number }) {
  return count > 0 ? <Badge variant="destructive">{count}</Badge> : <span>0</span>
}
