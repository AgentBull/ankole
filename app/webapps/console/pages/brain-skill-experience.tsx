import {
  Badge,
  buttonVariants,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  cn,
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyTitle,
  Skeleton
} from '@ankole/uikit'
import { RiArrowRightLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useSearchParams } from 'react-router'
import {
  ankoleWebAgentLibrarySkillOverlayControllerIndexOptions,
  ankoleWebPrincipalControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { AgentLibrarySkillOverlayItem } from '../api/generated/types.gen'
import { PageHeader, PageStack, RefreshButton } from '../console-page'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate } from '../console-primitives'
import { agentOwnerUID, setBrainFilter } from '../state/brain-editor-model'
import { BrainOwnerField, BrainTaskNavigation } from './brain-shared'

// Skill experience is Agent Library state that dreaming writes, so this surface
// stays read-only and hands editing back to the Agent Library page that owns it.
export function BrainSkillExperiencePage() {
  const { t } = useTranslation()
  const [searchParams, setSearchParams] = useSearchParams()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const agents = (principals.data?.principals ?? []).filter(principal => principal.type === 'agent')
  const ownerUID = agentOwnerUID(searchParams.get('owner'), agents)
  const overlays = useQuery({
    ...ankoleWebAgentLibrarySkillOverlayControllerIndexOptions({ path: { agent_uid: ownerUID } }),
    enabled: Boolean(ownerUID)
  })
  const items = overlays.data?.skill_overlays ?? []

  useEffect(() => {
    if (searchParams.get('owner') === ownerUID || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  return (
    <PageStack>
      <PageHeader
        title={t('console.brain.experience_title')}
        description={t('console.brain.experience_description')}
        actions={<RefreshButton />}
      />
      <BrainTaskNavigation ownerUID={ownerUID} />

      <div className="border border-border bg-card p-4">
        <BrainOwnerField
          ownerUID={ownerUID}
          principals={agents}
          onChange={value => setSearchParams(setBrainFilter(searchParams, 'owner', value), { replace: true })}
        />
      </div>

      <ErrorBlock error={overlays.error ?? principals.error} />
      {overlays.isLoading || principals.isLoading ? (
        <Skeleton className="h-48 w-full" />
      ) : items.length === 0 ? (
        <Empty className="items-start border border-border bg-card p-8 text-left md:p-10">
          <EmptyHeader className="max-w-xl items-start">
            <EmptyTitle>{t('console.brain.experience_empty_title')}</EmptyTitle>
            <EmptyDescription className="text-balance">
              {t('console.brain.experience_empty_description')}
            </EmptyDescription>
          </EmptyHeader>
        </Empty>
      ) : (
        <div className="grid gap-4">
          {items.map(item => (
            <SkillExperienceCard key={item.skill_name} item={item} ownerUID={ownerUID} />
          ))}
        </div>
      )}
    </PageStack>
  )
}

function SkillExperienceCard({ item, ownerUID }: { item: AgentLibrarySkillOverlayItem; ownerUID: string }) {
  const { t } = useTranslation()
  const scope = `scope=${encodeURIComponent(ownerUID)}`
  const editHref = item.agent_plugin_id
    ? `/agent-library/agent-plugins/${item.agent_plugin_id}?${scope}`
    : `/agent-library?${scope}`

  return (
    <Card>
      <CardHeader>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="grid min-w-0 gap-1">
            <CardTitle className="flex flex-wrap items-center gap-2 normal-case">
              {item.skill_name}
              {item.effective_enabled ? null : (
                <Badge variant="outline">{t('console.brain.experience_skill_disabled')}</Badge>
              )}
            </CardTitle>
            <CardDescription>{item.description ?? '—'}</CardDescription>
          </div>
          <Link className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))} to={editHref}>
            <RiArrowRightLine />
            {t('console.brain.experience_manage')}
          </Link>
        </div>
      </CardHeader>
      <CardContent className="grid gap-2">
        <pre className="max-h-80 overflow-auto whitespace-pre-wrap border border-border bg-muted p-3 text-sm leading-6">
          {item.text}
        </pre>
        <span className="text-xs text-muted-foreground">
          {t('console.brain.experience_updated')} {formatConsoleDate(item.updated_at)}
        </span>
      </CardContent>
    </Card>
  )
}
