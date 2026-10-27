import { recordValue, stringArg } from '@agentbull/active-support'
import { Badge, Button, Skeleton, toast } from '@ankole/uikit'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { enqueueBrainDreamMutation, getBrainHealthOptions } from '../../api/v2/generated/@tanstack/react-query.gen'
import type { GetBrainHealthResponse } from '../../api/v2/generated/types.gen'
import { aiGatewayConversationsOptions } from '../../api/ai-gateway-conversations'
import { ErrorBlock } from '../../../common/error-block'
import { requestErrorMessage } from '../../../common/request-errors'
import { AgentLink } from '../../console-list-page'
import { PageHeader, PageStack } from '../../console-page'
import { formatDuration, formatJSON } from '../../console-primitives'
import { conversationDisplayName } from '../../conversation-presentation'
import { IDLE_REFRESH_MS } from '../../refresh-intervals'
import { BrainSubNav } from './brain-nav'

type BrainHealth = GetBrainHealthResponse['health']
type BrainModelStatus = BrainHealth['models']['embedding']

export function BrainHealthPage() {
  const { t } = useTranslation()
  const health = useQuery({
    ...getBrainHealthOptions(),
    refetchInterval: IDLE_REFRESH_MS
  })
  const snapshot = health.data?.health
  const missingChannelIDs = snapshot?.channels_without_member_group ?? []
  const conversations = useQuery({
    ...aiGatewayConversationsOptions({ limit: 100 }),
    enabled: missingChannelIDs.length > 0
  })
  const dream = useMutation({
    ...enqueueBrainDreamMutation(),
    onSuccess: ({ result }) => toast.success(t(`console.brain.dream_${result.status}`)),
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <PageStack>
      <PageHeader
        title={t('console.brain.health_title')}
        description={t('console.brain.health_description')}
        actions={
          <Button
            disabled={!snapshot?.enabled || dream.isPending}
            aria-busy={dream.isPending}
            onClick={() => dream.mutate({})}>
            {t('console.brain.dream_now')}
          </Button>
        }
      />
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
            <HealthItem label={t('console.settings.brain_maintainer_agent_uid')}>
              {snapshot.maintainer_agent_uid ? (
                <AgentLink className="text-sm" hash="model-profiles" uid={snapshot.maintainer_agent_uid} />
              ) : (
                <div className="flex flex-wrap items-center gap-3">
                  <Badge variant="warning">{t('console.brain.maintainer_agent_not_configured')}</Badge>
                  <Link className="link text-sm" to="/settings/group/brain">
                    {t('console.brain.configure')}
                  </Link>
                </div>
              )}
            </HealthItem>
          </HealthSection>

          <HealthSection title={t('console.brain.health_models')}>
            <ModelStatusItem label={t('console.settings.brain_embedding_model')} status={snapshot.models.embedding} />
            <ModelStatusItem label={t('console.settings.brain_rerank_model')} status={snapshot.models.rerank} />
            <ModelStatusItem label={t('console.brain.web_fetch_profile')} status={snapshot.models.web_fetch} />
            <ModelStatusItem label={t('console.brain.extraction_profile')} status={snapshot.models.extraction} />
            <ModelStatusItem label={t('console.brain.dreaming_profile')} status={snapshot.models.dreaming} />
            <HealthItem label={t('console.brain.embedding_signature')}>
              <EmbeddingSignature value={snapshot.embedding_signature} />
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
                <HealthReason reason={snapshot.embeddings.recent_error} />
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
                  {snapshot.channels_without_member_group.map(channelID => {
                    const matched = (conversations.data?.conversations ?? []).find(
                      item => item.id === channelID || item.conversation_key.includes(channelID)
                    )
                    return (
                      <li key={channelID} className="text-xs text-muted-foreground">
                        {matched ? (
                          <Link
                            className="link"
                            title={channelID}
                            to={`/conversations/${encodeURIComponent(matched.id)}`}>
                            {conversationDisplayName(matched)}
                          </Link>
                        ) : (
                          <span className="font-mono">{channelID}</span>
                        )}
                      </li>
                    )
                  })}
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
  const totalActive = perAgent.reduce((sum, [, count]) => sum + Number(count), 0)
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
            <span className="inline-flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground">
              {perAgent.map(([agentUID, count], index) => (
                <span key={agentUID} className="inline-flex items-baseline gap-1">
                  {index > 0 ? <span aria-hidden>·</span> : null}
                  <AgentLink className="text-xs" uid={agentUID} />: <span>{String(count)}</span>
                </span>
              ))}
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
              {status.provider_error ? <HealthReason reason={status.provider_error} /> : null}
            </>
          ) : null}
        </span>
      ) : status.profile_error ? (
        <span className="inline-flex flex-wrap items-center gap-2">
          <Badge variant="destructive">{t('console.brain.model_not_configured')}</Badge>
          <HealthReason reason={status.profile_error} />
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
      <p className="text-sm text-destructive-foreground">{t('console.brain.invalid_config_keys')}</p>
      <ul className="grid gap-1">
        {invalid.map(([key, status]) => (
          <li key={key} className="text-xs text-destructive-foreground">
            <code>{key}</code>: {t(configStatusKey(status))}
          </li>
        ))}
      </ul>
    </div>
  )
}

function FailureCount({ count }: { count: number }) {
  return count > 0 ? <Badge variant="destructive">{count}</Badge> : <span>0</span>
}

function EmbeddingSignature({ value }: { value: unknown }) {
  const { t } = useTranslation()
  const error = stringArg(recordValue(value), 'error')

  if (value == null) return <Badge variant="warning">{t('console.brain.model_not_configured')}</Badge>
  if (error) return <HealthReason reason={error} />

  return <code className="text-xs break-all text-muted-foreground">{formatJSON(value)}</code>
}

function HealthReason({ reason }: { reason: string }) {
  const { t } = useTranslation()

  return <span className="text-xs text-destructive-foreground">{t(healthReasonKey(reason))}</span>
}

function healthReasonKey(reason: string) {
  switch (reason) {
    case 'not_found':
      return 'console.brain.health_provider_not_found' as const
    case 'provider_disabled':
      return 'console.brain.health_provider_disabled' as const
    case 'invalid_embedding_model_ref':
      return 'console.brain.health_embedding_model_invalid' as const
    case 'brain_maintainer_agent_not_configured':
      return 'console.brain.health_maintainer_agent_not_configured' as const
    case 'brain_maintainer_agent_disabled':
      return 'console.brain.health_maintainer_agent_disabled' as const
    case 'agent_not_found':
      return 'console.brain.health_maintainer_agent_not_found' as const
    case 'invalid_model_profile':
      return 'console.brain.health_model_profile_invalid' as const
    default:
      return 'console.brain.health_internal_error' as const
  }
}

function configStatusKey(status: unknown) {
  const record = recordValue(status)
  if (stringArg(record, 'invalid')) return 'console.brain.health_config_invalid' as const
  if (stringArg(record, 'unavailable')) return 'console.brain.health_config_unavailable' as const
  return 'console.brain.health_internal_error' as const
}
